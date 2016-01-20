module Language.PureScript.Make.Lua (
                                      buildMakeActions
                                    ) where

import qualified Data.ByteString.Lazy as BS

import qualified Data.Map.Strict as M

import Data.Foldable (for_)

import Data.Maybe (fromMaybe)
import Data.String (fromString)

import System.Directory (doesFileExist, getModificationTime, createDirectoryIfMissing)
import System.FilePath
import System.IO.Error (tryIOError)
import System.IO.UTF8 (readUTF8File)
import System.IO

import Data.Time
import Data.Version

import Control.Monad ((>=>), guard)
import Control.Monad.Error.Class
import Control.Monad.IO.Class
import Control.Monad.Trans.Class
import Control.Monad.Writer.Class

import Language.PureScript hiding (buildMakeActions)
import qualified Language.PureScript.CoreFn as CF
import Language.PureScript.CodeGen.Lua

import qualified Language.Lua.Syntax as L
import qualified Language.Lua.PrettyPrinter as L


buildMakeActions :: FilePath -- ^ The output directory
                    -> M.Map ModuleName (Either RebuildPolicy FilePath)
                    -- ^ Map between module names and the containing PureScript file.
                    -> M.Map ModuleName FilePath
                    -- ^ Map between module names and the file containing foreign lua.
                    -> Bool -- ^ Generate a prefix comment?
                    -> MakeActions Make
buildMakeActions outputDir filePathMap foreigns usePrefix =
  MakeActions getInputTimestamp getOutputTimestamp readExterns codegen progress
  where

    getInputTimestamp :: ModuleName -> Make (Either RebuildPolicy (Maybe UTCTime))
    getInputTimestamp mn = do
      let path = fromMaybe (internalError "Module has no filename in 'make'") $ M.lookup mn filePathMap
      e1 <- traverse getTimestamp path
      fPath <- maybe (return Nothing) getTimestamp $ M.lookup mn foreigns
      return $ fmap (max fPath) e1

    getOutputTimestamp :: ModuleName -> Make (Maybe UTCTime)
    getOutputTimestamp mn = do
      let filePath = runModuleName mn
          luaFile = outputDir </> filePath ++ ".lua"
      getTimestamp luaFile

    -- No externs
    readExterns :: ModuleName -> Make (FilePath, Externs)
    readExterns mn = do
      let path = outputDir </> runModuleName mn ++ ".externs"
      return (path, BS.empty)

    codegen :: CF.Module CF.Ann -> Environment -> Externs -> SupplyT Make ()
    codegen m _ exts = do
      let mn = CF.moduleName m
          filePath = runModuleName mn
      foreignInclude <- case mn `M.lookup` foreigns of
        Just path
          | not $ requiresForeign m -> do
              tell $ errorMessage $ UnnecessaryFFIModule mn path
              return Nothing
          | otherwise -> return $ Just $ funcall (var "require") [L.String $ filePath ++ ".foreign"]
        Nothing
          | requiresForeign m -> throwError . errorMessage $ MissingFFIModule mn
          | otherwise -> return Nothing      
      plua <- prettyPrintLua  <$> moduleToLua m foreignInclude
      let luaFile = outputDir </> filePath ++ ".lua"
          externsFile = outputDir </> filePath ++ ".externs"
          foreignFile = outputDir </> filePath ++ ".foreign"
          prefix =
            ["Generated by psc-lua-redux"]
          lua = unlines $ map ("-- " ++) prefix ++ [plua]
      lift $ do
        writeTextFile luaFile lua
        for_ (mn `M.lookup` foreigns) (readTextFile >=> writeTextFile foreignFile)
        writeTextFile externsFile ""

    prettyPrintLua :: L.Block -> String
    prettyPrintLua = show . L.pprint

    requiresForeign :: CF.Module a -> Bool
    requiresForeign = not . null . CF.moduleForeign

    getTimestamp :: FilePath -> Make (Maybe UTCTime)
    getTimestamp path = makeIO (const (ErrorMessage [] $ CannotGetFileInfo path)) $ do
      exists <- doesFileExist path
      traverse (const $ getModificationTime path) $ guard exists

    readTextFile :: FilePath -> Make String
    readTextFile path =
      makeIO (const (ErrorMessage [] $ CannotReadFile path)) $ readUTF8File path

    writeTextFile :: FilePath -> String -> Make ()
    writeTextFile path text = makeIO (const (ErrorMessage [] $ CannotWriteFile path)) $ do
      mkdirp path
      writeUTF8File path text
      where
        mkdirp :: FilePath -> IO ()
        mkdirp = createDirectoryIfMissing True . takeDirectory

    progress :: ProgressMessage -> Make ()
    progress = liftIO . putStrLn . renderProgressMessage


makeIO :: (IOError -> ErrorMessage) -> IO a -> Make a
makeIO f io = do
  e <- liftIO $ tryIOError io
  either (throwError . singleError . f) return e


writeUTF8File :: FilePath -> String -> IO ()
writeUTF8File inFile text = do
    h <- openFile inFile WriteMode
    hSetEncoding h utf8
    hPutStr h text
    hClose h
