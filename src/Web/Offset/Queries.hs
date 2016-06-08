{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Web.Offset.Queries where

import           Data.Monoid
import           Data.Text              (Text)

import           Web.Offset.Cache
import           Web.Offset.Cache.Types
import           Web.Offset.Types
import           Web.Offset.Utils

lookupTaxDict :: WPKey -> Wordpress b -> IO (TaxSpec a -> TaxSpecId a)
lookupTaxDict key@(TaxDictKey resName) wp@Wordpress{..} =
  do resp <- cachingGetErrorInt (cacheInternals { wpCacheSet = wpCacheSetInt (runRedis cacheInternals) (CacheSeconds (12 * 60 * 60))}) key
     case decodeJson resp of
       Nothing -> do wpExpirePostInt (runRedis cacheInternals) key
                     terror $ "Unparsable JSON: " <> resp
       Just res -> return (getSpecId $ TaxDict res resName)

getSpecId :: TaxDict a -> TaxSpec a -> TaxSpecId a
getSpecId taxDict spec =
  case spec of
   TaxPlus slug -> TaxPlusId $ idFor taxDict slug
   TaxMinus slug -> TaxMinusId $ idFor taxDict slug
  where
    idFor :: TaxDict a -> Text -> Int
    idFor (TaxDict{..}) slug =
      case filter (\(TaxRes (_,s)) -> s == slug) dict of
       [] -> terror $ "Couldn't find " <> desc <> ": " <> slug
       (TaxRes (i,_):_) -> i
