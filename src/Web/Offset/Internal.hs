{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE ImpredicativeTypes    #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeSynonymInstances  #-}

module Web.Offset.Internal where

import           Data.Monoid      ((<>))
import qualified Data.Set         as Set
import           Data.Text        (Text)

import           Web.Offset.HTTP
import           Web.Offset.Types
import           Web.Offset.Utils

wpRequestInt :: Requester -> Text -> WPKey -> IO Text
wpRequestInt runHTTP endpt key =
  case key of
   TaxDictKey resName ->          req ("/" <> resName) []
   PostByPermalinkKey _ _ slug -> req "/posts" [("slug", slug)]
   PostsKey{} ->                  req "/posts" (buildParams key)
   PostKey i ->                   req ("/posts/" <> tshow i) []
   PageKey s ->                   req "/pages" [("slug", s)]
   AuthorKey i ->                 req ("/users/" <> tshow i) []
   TaxSlugKey tName tSlug ->      req ("/" <> tName) [("slug", tSlug)]
   EndpointKey endpoint ->        req ("/" <> endpoint) []
  where req path = unRequester runHTTP (endpt <> path)

buildParams :: WPKey -> [(Text, Text)]
buildParams (PostsKey filters) = params
  where params = Set.toList $ Set.map mkFilter filters
        mkFilter (TaxFilter taxName (TaxPlusId i)) = (taxName <> "[]", tshow i)
        mkFilter (TaxFilter taxName (TaxMinusId i)) = (taxName <> "_exclude[]", tshow i)
        mkFilter (NumFilter num) = ("per_page", tshow num)
        mkFilter (OffsetFilter offset) = ("offset", tshow offset)
        mkFilter (UserFilter user) = ("author[]", user)

wpLogInt :: Maybe (Text -> IO ()) -> Text -> IO ()
wpLogInt logger msg = case logger of
                    Nothing -> return ()
                    Just f -> f msg
