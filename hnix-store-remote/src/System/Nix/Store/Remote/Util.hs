{-# language RecordWildCards     #-}
module System.Nix.Store.Remote.Util where

import           Prelude                 hiding ( putText )
import           Control.Monad.Except

import           Data.Binary.Get
import           Data.Binary.Put
import qualified Data.Text.Lazy.Encoding       as TL
import           Data.Time
import           Data.Time.Clock.POSIX
import qualified Data.ByteString.Char8         as BSC
import qualified Data.ByteString.Lazy          as BSL

import           Network.Socket.ByteString      ( recv
                                                , sendAll
                                                )

import           Nix.Derivation

import           System.Nix.Build
import           System.Nix.StorePath
import           System.Nix.Store.Remote.Binary
import           System.Nix.Store.Remote.Types

import qualified Data.HashSet
import qualified Data.Map

genericIncremental :: (MonadIO m) => m (Maybe ByteString) -> Get a -> m a
genericIncremental getsome parser = go decoder
 where
  decoder = runGetIncremental parser
  go (Done _leftover _consumed x  ) = pure x
  go (Partial k                   ) = do
    chunk <- getsome
    go (k chunk)
  go (Fail _leftover _consumed msg) = error $ fromString msg

getSocketIncremental :: Get a -> MonadStore a
getSocketIncremental = genericIncremental sockGet8
 where
  sockGet8 :: MonadStore (Maybe BSC.ByteString)
  sockGet8 = do
    soc <- asks storeSocket
    liftIO $ Just <$> recv soc 8

sockPut :: Put -> MonadStore ()
sockPut p = do
  soc <- asks storeSocket
  liftIO $ sendAll soc $ toStrict $ runPut p

sockGet :: Get a -> MonadStore a
sockGet = getSocketIncremental

sockGetInt :: Integral a => MonadStore a
sockGetInt = getSocketIncremental getInt

sockGetBool :: MonadStore Bool
sockGetBool = (== (1 :: Int)) <$> sockGetInt

sockGetStr :: MonadStore ByteString
sockGetStr = getSocketIncremental getByteStringLen

sockGetStrings :: MonadStore [ByteString]
sockGetStrings = getSocketIncremental getByteStrings

sockGetPath :: MonadStore StorePath
sockGetPath = do
  sd  <- getStoreDir
  pth <- getSocketIncremental (getPath sd)
  either
    throwError
    pure
    pth

sockGetPathMay :: MonadStore (Maybe StorePath)
sockGetPathMay = do
  sd  <- getStoreDir
  pth <- getSocketIncremental (getPath sd)
  pure $
    either
      (const Nothing)
      Just
      pth

sockGetPaths :: MonadStore StorePathSet
sockGetPaths = do
  sd <- getStoreDir
  getSocketIncremental (getPaths sd)

bsToText :: ByteString -> Text
bsToText = decodeUtf8

textToBS :: Text -> ByteString
textToBS = encodeUtf8

bslToText :: BSL.ByteString -> Text
bslToText = toText . TL.decodeUtf8

textToBSL :: Text -> BSL.ByteString
textToBSL = TL.encodeUtf8 . toLText

putText :: Text -> Put
putText = putByteStringLen . textToBSL

putTexts :: [Text] -> Put
putTexts = putByteStrings . fmap textToBSL

getPath :: FilePath -> Get (Either String StorePath)
getPath sd = parsePath sd <$> getByteStringLen

getPaths :: FilePath -> Get StorePathSet
getPaths sd =
  Data.HashSet.fromList . rights . fmap (parsePath sd) <$> getByteStrings

putPath :: StorePath -> Put
putPath = putByteStringLen . fromStrict . storePathToRawFilePath

putPaths :: StorePathSet -> Put
putPaths = putByteStrings . Data.HashSet.toList . Data.HashSet.map
  (fromStrict . storePathToRawFilePath)

putBool :: Bool -> Put
putBool True  = putInt (1 :: Int)
putBool False = putInt (0 :: Int)

getBool :: Get Bool
getBool = (== 1) <$> (getInt :: Get Int)

putEnum :: (Enum a) => a -> Put
putEnum = putInt . fromEnum

getEnum :: (Enum a) => Get a
getEnum = toEnum <$> getInt

putTime :: UTCTime -> Put
putTime = (putInt :: Int -> Put) . round . utcTimeToPOSIXSeconds

getTime :: Get UTCTime
getTime = posixSecondsToUTCTime <$> getEnum

getBuildResult :: Get BuildResult
getBuildResult =
  BuildResult
    <$> getEnum
    <*> (Just . bsToText <$> getByteStringLen)
    <*> getInt
    <*> getBool
    <*> getTime
    <*> getTime

putDerivation :: Derivation StorePath Text -> Put
putDerivation Derivation{..} = do
  flip putMany (Data.Map.toList outputs)
    $ \(outputName, DerivationOutput{..}) -> do
        putText outputName
        putPath path
        putText hashAlgo
        putText hash

  putMany putPath inputSrcs
  putText platform
  putText builder
  putMany putText args

  flip putMany (Data.Map.toList env)
    $ \(a1, a2) -> putText a1 *> putText a2
