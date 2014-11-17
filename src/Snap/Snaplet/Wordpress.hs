{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeSynonymInstances  #-}

module Snap.Snaplet.Wordpress (
   Wordpress(..)
 , WordpressConfig(..)
 , CacheBehavior(..)
 , initWordpress
 , initWordpress'
 , getPost
 , WPKey(..)
 , Filter(..)
 , wpCacheGet
 , wpCacheSet
 , wpExpirePost
 , wpExpireAggregates

 , transformName
 , TaxSpec(..)
 , TaxSpecList(..)
 , Field(..)
 , mergeFields
 ) where

import           Control.Applicative
import           Control.Concurrent           (threadDelay)
import           Control.Concurrent.MVar
import           Control.Lens
import           Data.Aeson
import qualified Data.Attoparsec.Text         as A
import           Data.ByteString              (ByteString)
import           Data.Char                    (toUpper)
import qualified Data.Configurator            as C
import           Data.Default
import qualified Data.HashMap.Strict          as M
import           Data.IntSet                  (IntSet)
import qualified Data.IntSet                  as IntSet
import           Data.List                    (intercalate)
import           Data.Map                     (Map)
import qualified Data.Map                     as Map
import           Data.Map.Syntax
import           Data.Maybe                   (catMaybes, fromJust, fromMaybe,
                                               isJust, listToMaybe)
import           Data.Monoid
import           Data.Ratio
import           Data.Set                     (Set)
import qualified Data.Set                     as Set
import           Data.Text                    (Text)
import qualified Data.Text                    as T
import qualified Data.Text.Encoding           as T
import qualified Data.Text.Lazy               as TL
import qualified Data.Text.Lazy.Encoding      as TL
import           Data.Time.Clock
import qualified Data.Vector                  as V
import           Database.Redis               (Redis)
import qualified Database.Redis               as R
import           Heist
import           Heist.Compiled
import           Heist.Compiled.LowLevel
import qualified Network.Wreq                 as W
import           Snap
import           Snap.Snaplet.Heist           (Heist, addConfig)
import           Snap.Snaplet.RedisDB         (RedisDB)
import qualified Snap.Snaplet.RedisDB         as R
import qualified Text.XmlHtml                 as X

import           Snap.Snaplet.Wordpress.Cache
import           Snap.Snaplet.Wordpress.Posts
import           Snap.Snaplet.Wordpress.Types
import           Snap.Snaplet.Wordpress.Utils


data WordpressConfig m = WordpressConfig { endpoint      :: Text
                                         , requester     :: Maybe (Text -> [(Text, Text)] -> IO Text)
                                         , cacheBehavior :: CacheBehavior
                                         , extraFields   :: [Field m]
                                         , logger        :: Maybe (Text -> IO ())
                                         }

instance Default (WordpressConfig m) where
  def = WordpressConfig "http://127.0.0.1/wp-json" Nothing (CacheSeconds 600) [] Nothing

data Wordpress b = Wordpress { runRedis       :: forall a. Redis a -> Handler b (Wordpress b) a
                             , runHTTP        :: Text -> [(Text, Text)] -> IO Text
                             , activeMV       :: MVar (Map WPKey UTCTime)
                             , requestPostSet :: Maybe IntSet
                             , conf           :: WordpressConfig (Handler b b)
                             }

initWordpress :: Snaplet (Heist b)
              -> Simple Lens b (Snaplet RedisDB)
              -> Lens b b (Snaplet (Wordpress b)) (Snaplet (Wordpress b))
              -> SnapletInit b (Wordpress b)
initWordpress = initWordpress' def

initWordpress' :: WordpressConfig (Handler b b)
               -> Snaplet (Heist b)
               -> Simple Lens b (Snaplet RedisDB)
               -> Lens b b (Snaplet (Wordpress b)) (Snaplet (Wordpress b))
               -> SnapletInit b (Wordpress b)
initWordpress' wpconf heist redis wordpress =
  makeSnaplet "wordpress" "" Nothing $
    do conf <- getSnapletUserConfig
       req <- case requester wpconf of
                Nothing -> do u <- liftIO $ C.require conf "username"
                              p <- liftIO $ C.require conf "password"
                              return $ wreqRequester wpconf u p
                Just r -> return r
       active <- liftIO $ newMVar Map.empty
       let wp = Wordpress (withTop' id . R.runRedisDB redis) req active Nothing wpconf
       addConfig heist $ set scCompiledSplices (wordpressSplices wp wpconf wordpress) mempty
       return $ wp

wordpressSplices :: Wordpress b
                 -> WordpressConfig (Handler b b)
                 -> Lens b b (Snaplet (Wordpress b)) (Snaplet (Wordpress b))
                 -> Splices (Splice (Handler b b))
wordpressSplices wp conf wordpress =
  do "wpPosts" ## wpPostsSplice wp conf wordpress
     "wpPostByPermalink" ## wpPostByPermalinkSplice conf wordpress
     "wpNoPostDuplicates" ## wpNoPostDuplicatesSplice wordpress

wpNoPostDuplicatesSplice :: Lens b b (Snaplet (Wordpress b)) (Snaplet (Wordpress b))
                         -> Splice (Handler b b)
wpNoPostDuplicatesSplice wordpress =
  return $ yieldRuntime $
    do w@Wordpress{..} <- lift $ use (wordpress . snapletValue)
       case requestPostSet of
         Nothing -> lift $ assign (wordpress . snapletValue)
                                  w{requestPostSet = (Just IntSet.empty)}
         Just _ -> return ()
       codeGen $ yieldPureText ""

getWordpress :: Handler b v v
getWordpress = view snapletValue <$> getSnapletState

runningQueryFor :: WPKey
                -> Handler b (Wordpress b) Bool
runningQueryFor wpKey =
  do wordpress <- getWordpress
     liftIO $ startWpQueryMutex wordpress wpKey

startWpQueryMutex :: Wordpress b -> WPKey -> IO Bool
startWpQueryMutex Wordpress{..} wpKey =
  do now <- liftIO $ getCurrentTime
     liftIO $ modifyMVar activeMV $ \a ->
      let active = filterCurrent now a
      in if Map.member wpKey active
          then return (active, True)
          else return (Map.insert wpKey now active, False)
  where filterCurrent now = Map.filter (\v -> diffUTCTime now v < 1)


markDoneRunning :: WPKey
                -> Handler b (Wordpress b) ()
markDoneRunning wpKey =
  do Wordpress{..} <- getWordpress
     liftIO $ modifyMVar_ activeMV $ return . Map.delete wpKey

wpPostsSplice :: Wordpress b
              -> WordpressConfig (Handler b b)
              -> Lens b b (Snaplet (Wordpress b)) (Snaplet (Wordpress b))
              -> Splice (Handler b b)
wpPostsSplice wp wpconf wordpress =
  do promise <- newEmptyPromise
     outputChildren <- manyWithSplices runChildren (postSplices (extraFields wpconf))
                                                   (getPromise promise)
     n <- getParamNode
     let limit = (fromMaybe 20 $ readSafe =<< X.getAttribute "limit" n) :: Int
         num = (fromMaybe 20 $ readSafe =<< X.getAttribute "num" n) :: Int
         offset' = (fromMaybe 0 $ readSafe =<< X.getAttribute "offset" n) :: Int
         page' = (fromMaybe 1 $ readSafe =<< X.getAttribute "page" n) :: Int
         page = if page' < 1 then 1 else page'
         offset = num * (page - 1) + offset'
         tags' = unTaxSpecList (fromMaybe (TaxSpecList []) $ readSafe =<< X.getAttribute "tags" n)
         cats' = unTaxSpecList (fromMaybe (TaxSpecList []) $ readSafe =<< X.getAttribute "categories" n)
     tags <- lift $ lookupTagIds wp (endpoint wpconf) tags'
     cats <- lift $ lookupCategoryIds wp (endpoint wpconf) cats'

     let getPosts =
          do Wordpress{..} <- lift $ use (wordpress . snapletValue)
             let wpKey = wpKey' num offset tags cats
             cached <- lift $ with wordpress $ wpCacheGet (cacheBehavior wpconf) wpKey
             case cached of
               Just r -> return r
               Nothing ->
                 do running <- lift $ with wordpress $ runningQueryFor wpKey
                    if running
                       then do liftIO $ threadDelay 100000
                               getPosts
                       else
                         do let endpt = endpoint wpconf
                            h <- liftIO $ runHTTP (endpt <> "/posts") $ buildParams wpKey
                            lift $ with wordpress $ do
                              wpCacheSet (cacheBehavior wpconf) wpKey h
                              markDoneRunning wpKey
                            return h
     return $ yieldRuntime $
       do res <- getPosts
          case (decodeStrict . T.encodeUtf8 $ res) of
            Just posts -> do let postsW = extractPostIds posts
                             Wordpress{..} <- lift (use (wordpress . snapletValue))
                             let postsND = noDuplicates requestPostSet . take limit $ postsW
                             lift $ addPostIds wordpress (map fst postsND)
                             putPromise promise (map snd postsND)
                             codeGen outputChildren
            Nothing -> codeGen (yieldPureText "")
  where noDuplicates :: Maybe IntSet -> [(Int, Object)] -> [(Int, Object)]
        noDuplicates Nothing = id
        noDuplicates (Just postSet) = filter (\(i,_) -> IntSet.notMember i postSet)

wpKey' :: Int -> Int -> [TaxSpecId] -> [TaxSpecId] -> WPKey
wpKey' num offset tags cats =
  PostsKey (Set.fromList $ [ NumFilter num , OffsetFilter offset]
            ++ map TagFilter tags ++ map CatFilter cats)


buildParams :: WPKey -> [(Text, Text)]
buildParams (PostsKey filters) = params
  where params = Set.toList $ Set.map mkFilter filters
        mkFilter (TagFilter (TaxPlusId i)) = ("filter[tag__in]", tshow i)
        mkFilter (TagFilter (TaxMinusId i)) = ("filter[tag__not_in]", tshow i)
        mkFilter (CatFilter (TaxPlusId i)) = ("filter[category__in]", tshow i)
        mkFilter (CatFilter (TaxMinusId i)) = ("filter[category__not_in]", tshow i)
        mkFilter (NumFilter num) = ("filter[posts_per_page]", tshow num)
        mkFilter (OffsetFilter offset) = ("filter[offset]", tshow offset)

newtype TaxRes = TaxRes (Int, Text)

instance FromJSON TaxRes where
  parseJSON (Object o) = TaxRes <$> ((,) <$> o .: "ID" <*> o .: "slug")
  parseJSON _ = mzero

data TaxDict = TaxDict {dict :: [TaxRes], desc :: Text}

lookupTagIds :: Wordpress b -> Text -> [TaxSpec] -> IO [TaxSpecId]
lookupTagIds wordpress = lookupTaxIds wordpress "post_tag"

lookupCategoryIds :: Wordpress b -> Text -> [TaxSpec] -> IO [TaxSpecId]
lookupCategoryIds wordpress = lookupTaxIds wordpress "category"

lookupTaxIds :: Wordpress b -> Text -> Text -> [TaxSpec] -> IO [TaxSpecId]
lookupTaxIds _ _ _ [] = return []
lookupTaxIds wordpress resName end specs =
  do taxDict <- lookupTaxDict wordpress resName end
     return $ map taxDict specs

getSpecId :: TaxDict -> TaxSpec -> TaxSpecId
getSpecId taxDict spec =
  case spec of
   TaxPlus slug -> TaxPlusId $ idFor taxDict slug
   TaxMinus slug -> TaxMinusId $ idFor taxDict slug
  where
    idFor :: TaxDict -> Text -> Int
    idFor (TaxDict{..}) slug =
      case filter (\(TaxRes (_,s)) -> s == slug) dict of
       [] -> error $ T.unpack $ "Couldn't find " <> desc <> ": " <> slug
       (TaxRes (i,_):_) -> i

lookupTaxDict :: Wordpress b -> Text -> Text -> IO (TaxSpec -> TaxSpecId)
lookupTaxDict Wordpress{..} resName end =
  do res <- liftIO $ dcode <$> runHTTP (end <> "/taxonomies/" <> resName <> "/terms") []
     return (getSpecId $ TaxDict res resName)
  where dcode :: Text -> [TaxRes]
        dcode res = case decodeStrict $ T.encodeUtf8 res of
                     Nothing -> error $ T.unpack $ "Unparsable JSON from " <> resName <> ": " <> res
                     Just dict -> dict

extractPostIds :: [Object] -> [(Int, Object)]
extractPostIds = map extractPostId


addPostIds :: Lens b b (Snaplet (Wordpress b)) (Snaplet (Wordpress b)) -> [Int] -> Handler b b ()
addPostIds wordpress ids =
  do w@Wordpress{..} <- use (wordpress . snapletValue)
     assign (wordpress . snapletValue)
            w{requestPostSet = ((`IntSet.union` (IntSet.fromList ids)) <$> requestPostSet) }

getPost :: WPKey -> Handler b (Wordpress b) (Maybe Object)
getPost wpKey@(PostByPermalinkKey year month slug) =
  do Wordpress{..} <- view snapletValue <$> getSnapletState
     mres <- wpCacheGet (cacheBehavior conf) wpKey
     case mres of
       Just r' -> return (decodeStrict . T.encodeUtf8 $ r')
       Nothing ->
         do running <- runningQueryFor wpKey
            if running
               then do liftIO $ threadDelay 100000
                       getPost wpKey
               else do h <- liftIO $ runHTTP (endpoint conf <> "/posts")
                              [("filter[year]",year)
                              ,("filter[monthnum]", month)
                              ,("filter[name]", slug)]
                       let post' = decodeStrict . T.encodeUtf8 $ h
                       case post' of
                         Just (post:_) ->
                           do wpCacheSet (cacheBehavior conf) wpKey
                                (TL.toStrict . TL.decodeUtf8 . encode $ post)
                              markDoneRunning wpKey
                              return $ Just post
                         _ -> do markDoneRunning wpKey
                                 return Nothing
getPost key = error $ "getPost: Don't know how to get a post from key: " ++ show key

wpPostByPermalinkSplice :: WordpressConfig (Handler b b)
                        -> Lens b b (Snaplet (Wordpress b)) (Snaplet (Wordpress b))
                        -> Splice (Handler b b)
wpPostByPermalinkSplice conf wordpress =
  do promise <- newEmptyPromise
     outputChildren <- withSplices runChildren (postSplices (extraFields conf)) (getPromise promise)
     return $ yieldRuntime $
       do mperma <- (parsePermalink . T.decodeUtf8 . rqURI) <$> lift getRequest
          case mperma of
            Nothing -> codeGen (yieldPureText "")
            Just (year, month, slug) ->
              do res <- lift $ with wordpress $ getPost (PostByPermalinkKey year month slug)
                 case res of
                   Just post -> do putPromise promise post
                                   codeGen outputChildren
                   _ -> codeGen (yieldPureText "")

parsePermalink = either (const Nothing) Just . A.parseOnly parser . T.reverse
  where parser = do A.option ' ' (A.char '/')
                    guls <- A.many1 (A.letter <|> A.char '-')
                    A.char '/'
                    htnom <- A.count 2 A.digit
                    A.char '/'
                    raey <- A.count 4 A.digit
                    A.char '/'
                    return (T.reverse $ T.pack raey
                           ,T.reverse $ T.pack htnom
                           ,T.reverse $ T.pack guls)

-- TODO(dbp 2014-10-14): date should be parsed and nested.
data Field m = F Text -- A single flat field
             | P Text (RuntimeSplice m Text -> Splice m) -- A customly parsed flat field
             | N Text [Field m] -- A nested object field
             | M Text [Field m] -- A list field, where each element is an object

instance (Functor m, Monad m) =>  Show (Field m) where
  show (F t) = "F(" ++ T.unpack t ++ ")"
  show (P t _) = "P(" ++ T.unpack t ++ ",{code})"
  show (N t n) = "N(" ++ T.unpack t ++ "," ++ show n ++ ")"
  show (M t m) = "M(" ++ T.unpack t ++ "," ++ show m ++ ")"

postFields :: (Functor m, Monad m) => [Field m]
postFields = [F "ID"
             ,F "title"
             ,F "status"
             ,F "type"
             ,N "author" [F "ID",F "name",F "first_name",F "last_name",F "description"]
             ,F "content"
             ,P "date" dateSplice
             ,F "slug"
             ,F "excerpt"
             ,N "custom_fields" [F "test"]
             ,N "featured_image" [F "content"
                                 ,F "source"
                                 ,N "attachment_meta" [F "width"
                                                      ,F "height"
                                                      ,N "sizes" [N "thumbnail" [F "width"
                                                                                ,F "height"
                                                                                ,F "url"]
                                                                 ]]]
             ,N "terms" [M "category" [F "ID", F "name", F "slug", F "count"]
                        ,M "post_tag" [F "ID", F "name", F "slug", F "count"]]
             ]

mergeFields :: (Functor m, Monad m) => [Field m] -> [Field m] -> [Field m]
mergeFields fo [] = fo
mergeFields fo (f:fs) = mergeFields (overrideInList False f fo) fs
  where overrideInList :: (Functor m, Monad m) => Bool -> Field m -> [Field m] -> [Field m]
        overrideInList False fl [] = [fl]
        overrideInList True _ [] = []
        overrideInList v fl (m:ms) = (if matchesName m fl
                                        then mergeField m fl : (overrideInList True fl ms)
                                        else m : (overrideInList v fl ms))
        matchesName a b = getName a == getName b
        getName (F t) = t
        getName (P t _) = t
        getName (N t _) = t
        getName (M t _) = t
        mergeField (N _ left) (N nm right) = N nm (mergeFields left right)
        mergeField (M _ left) (N nm right) = N nm (mergeFields left right)
        mergeField (N _ left) (M nm right) = M nm (mergeFields left right)
        mergeField (M _ left) (M nm right) = M nm (mergeFields left right)
        mergeField _ right = right

dateSplice :: (Functor m, Monad m) => RuntimeSplice m Text -> Splice m
dateSplice d = withSplices runChildren splices (parseDate <$> d)
  where splices = do "wpYear" ## pureSplice $ textSplice fst3
                     "wpMonth" ## pureSplice $ textSplice snd3
                     "wpDay" ## pureSplice $ textSplice trd3
        parseDate :: Text -> (Text,Text,Text)
        parseDate = tuplify . T.splitOn "-" . T.takeWhile (/= 'T')
        tuplify (y:m:d:_) = (y,m,d)
        fst3 (a,_,_) = a
        snd3 (_,a,_) = a
        trd3 (_,_,a) = a

postSplices :: (Functor m, Monad m) => [Field m] -> Splices (RuntimeSplice m Object -> Splice m)
postSplices extra = mconcat (map buildSplice (mergeFields postFields extra))
  where buildSplice (F n) =
          transformName n ## pureSplice . textSplice $ getText n
        buildSplice (P n splice) =
          transformName n ## \o -> splice (getText n <$> o)
        buildSplice (N n fs) = transformName n ## \o ->
                                 withSplices runChildren
                                                (mconcat $ map buildSplice fs)
                                                (unObj . fromJust . M.lookup n <$> o)
        buildSplice (M n fs) = transformName n ## \o ->
                                 manyWithSplices runChildren
                                                    (mconcat $ map buildSplice fs)
                                                    (unArray . fromJust . M.lookup n <$> o)
        unObj (Object o) = o
        unArray (Array v) = map unObj $ V.toList v
        getText n o = case M.lookup n o of
                        Just (String t) -> t
                        Just (Number i) -> T.pack $ show i
                        _ -> ""


transformName :: Text -> Text
transformName = T.append "wp" . snd . T.foldl f (True, "")
  where f (True, rest) next = (False, T.snoc rest (toUpper next))
        f (False, rest) '_' = (True, rest)
        f (False, rest) '-' = (True, rest)
        f (False, rest) next = (False, T.snoc rest next)


wpCacheGet :: CacheBehavior -> WPKey -> Handler b (Wordpress b) (Maybe Text)
wpCacheGet b wpKey =
  do Wordpress{..} <- view snapletValue <$> getSnapletState
     runRedis $ cacheGet b wpKey


wpCacheSet :: CacheBehavior -> WPKey -> Text -> Handler b (Wordpress b) ()
wpCacheSet b key o = void $
  do Wordpress{..} <- view snapletValue <$> getSnapletState
     runRedis $ cacheSet b key o

wpExpireAggregates :: Handler b (Wordpress b) Bool
wpExpireAggregates =
  do Wordpress{..} <- view snapletValue <$> getSnapletState
     runRedis $ expireAggregates

wpExpirePost :: Int -> Handler b (Wordpress b) Bool
wpExpirePost i =
  do Wordpress{..} <- view snapletValue <$> getSnapletState
     runRedis $ expirePost i

wreqRequester :: WordpressConfig (Handler b b) -> Text -> Text -> Text -> [(Text, Text)] -> IO Text
wreqRequester conf user passw u ps =
  do let opts = (W.defaults & W.params .~ ps
                            & W.auth .~ W.basicAuth user' pass')
     wplog conf $ "wreq: " <> u <> " with params: " <>
                  (T.intercalate "&" . map (\(a,b) -> a <> "=" <> b) $ ps)
     r <- W.getWith opts (T.unpack u)
     return $ TL.toStrict . TL.decodeUtf8 $ r ^. W.responseBody
  where user' = T.encodeUtf8 user
        pass' = T.encodeUtf8 passw

wplog :: WordpressConfig (Handler b b) -> Text -> IO ()
wplog conf msg = case logger conf of
                   Nothing -> return ()
                   Just f -> f msg
