-- | Stream out a NAR file from a regular file

{-# language ScopedTypeVariables #-}

module System.Nix.Internal.Nar.Streamer
  ( streamNarIO
  , IsExecutable(..)
  )
where

import qualified Control.Monad.IO.Class          as IO
import qualified Data.ByteString                 as Bytes
import qualified Data.ByteString.Char8           as Bytes.Char8
import qualified Data.ByteString.Lazy            as Bytes.Lazy
import qualified Data.Serialize                  as Serial
import qualified System.Directory                as Directory
import           System.FilePath                  ( (</>) )

import qualified System.Nix.Internal.Nar.Effects as Nar


-- | This implementation of Nar encoding takes an arbitrary @yield@
--   function from any streaming library, and repeatedly calls
--   it while traversing the filesystem object to Nar encode
streamNarIO
  :: forall m
   . (IO.MonadIO m)
  => (ByteString -> m ())
  -> Nar.NarEffects IO
  -> FilePath
  -> m ()
streamNarIO yield effs basePath = do
  yield $ str "nix-archive-1"
  parens $ go basePath

 where

  go :: FilePath -> m ()
  go path = do
    isDir     <- IO.liftIO $ Nar.narIsDir effs path
    isSymLink <- IO.liftIO $ Nar.narIsSymLink effs path
    let isRegular = not $ isDir || isSymLink

    when isSymLink $ do
      target <- IO.liftIO $ Nar.narReadLink effs path
      yield $
        strs ["type", "symlink", "target", Bytes.Char8.pack target]

    when isRegular $ do
      isExec <- IO.liftIO $ isExecutable effs path
      yield $ strs ["type", "regular"]
      when (isExec == Executable) $ yield $ strs ["executable", ""]
      fSize <- IO.liftIO $ Nar.narFileSize effs path
      yield $ str "contents"
      yield $ int fSize
      yieldFile path fSize

    when isDir $ do
      fs <- IO.liftIO (Nar.narListDir effs path)
      yield $ strs ["type", "directory"]
      forM_ (sort fs) $ \f -> do
        yield $ str "entry"
        parens $ do
          let fullName = path </> f
          yield $ strs ["name", Bytes.Char8.pack f, "node"]
          parens $ go fullName

  str :: ByteString -> ByteString
  str t =
    let
      len = Bytes.length t
    in
      int len <> padBS len t

  padBS :: Int -> ByteString -> ByteString
  padBS strSize bs = bs <> Bytes.replicate (padLen strSize) 0

  parens act = do
    yield $ str "("
    r <- act
    yield $ str ")"
    pure r

  -- Read, yield, and pad the file
  yieldFile :: FilePath -> Int64 -> m ()
  yieldFile path fsize = do
    mapM_ yield . Bytes.Lazy.toChunks =<< IO.liftIO (Bytes.Lazy.readFile path)
    yield $ Bytes.replicate (padLen $ fromIntegral fsize) 0

  strs :: [ByteString] -> ByteString
  strs xs = Bytes.concat $ str <$> xs

  int :: Integral a => a -> ByteString
  int n = Serial.runPut $ Serial.putInt64le $ fromIntegral n


data IsExecutable = NonExecutable | Executable
  deriving (Eq, Show)

isExecutable :: Functor m => Nar.NarEffects m -> FilePath -> m IsExecutable
isExecutable effs fp =
  bool
    NonExecutable
    Executable
    . Directory.executable <$> Nar.narGetPerms effs fp

-- | Distance to the next multiple of 8
padLen :: Int -> Int
padLen n = (8 - n) `mod` 8
