{-# LANGUAGE OverloadedStrings #-}

module Luna.Manager.System where

import           Prologue                     hiding (FilePath,null, filter, appendFile, readFile, toText, fromText)

import qualified Control.Exception.Safe       as Exception
import           Control.Monad.Raise
import           Control.Monad.State.Layered
import           Control.Monad.Trans.Resource (MonadBaseControl)
import           Data.ByteString.Lazy         (ByteString, null)
import           Data.ByteString.Lazy.Char8   (filter, unpack)
import           Data.Maybe                   (listToMaybe)
import           Data.List                    (isInfixOf)
import           Data.List.Split              (splitOn)
import           Data.Text.IO                 (appendFile, readFile)
import qualified Data.Text                    as Text
import           Filesystem.Path.CurrentOS    (FilePath, (</>), encodeString, toText, parent)
import           System.Directory             (executable, setPermissions, getPermissions, doesDirectoryExist, doesPathExist, getHomeDirectory)
import qualified System.Environment           as Environment
import           System.Exit
import qualified System.FilePath              as Path
import           System.Process.Typed         as Process

import           Luna.Manager.Command.Options (Options)
import qualified Luna.Manager.Logger          as Logger
import           Luna.Manager.Logger          (LoggerMonad)
import qualified Luna.Manager.Shell.Shelly    as Shelly
import           Luna.Manager.Shell.Shelly    (MonadSh, MonadShControl)
import           Luna.Manager.System.Env
import           Luna.Manager.System.Host


data Shell = Bash | Zsh | Unknown deriving (Show)

isEnter :: Char -> Bool
isEnter a = a /= '\n'

filterEnters :: ByteString ->   ByteString
filterEnters bytestr = res where
    res = filter isEnter bytestr

callShell :: MonadIO m => Text -> m ByteString
callShell cmd = do
    (exitCode, out, err) <- liftIO $ readProcess (shell $ convert cmd)
    return $ filterEnters out

checkIfNotEmpty :: MonadIO m => Text -> m Bool
checkIfNotEmpty cmd = not . null <$> callShell cmd

checkBash :: MonadIO m => m  (Maybe Shell)
checkBash = do
    sys <- checkIfNotEmpty "$SHELL -c 'echo $BASH_VERSION'"
    return $ if sys then Just Bash else Nothing

checkZsh :: MonadIO m => m  (Maybe Shell)
checkZsh = do
    sys <- checkIfNotEmpty "$SHELL -c 'echo $ZSH_VERSION'"
    return $ if sys then Just Zsh else Nothing

checkShell :: MonadIO m => m Shell
checkShell = do
    bash <- checkBash
    zsh  <- checkZsh
    return $ fromMaybe Unknown $ bash <|> zsh

runControlCheck :: MonadIO m => FilePath -> m (Maybe FilePath)
runControlCheck file = do
    home <- getHomePath
    let location = home </> file
    pathCheck <- liftIO $ doesPathExist $ encodeString location
    return $ if pathCheck then Just location else Nothing

data BashConfigNotFoundError = BashConfigNotFoundError deriving (Show)
instance Exception BashConfigNotFoundError where
    displayException _ = "Bash config not found"

bashConfigNotFoundError :: SomeException
bashConfigNotFoundError = toException BashConfigNotFoundError

data UnrecognizedShellException = UnrecognizedShellException deriving (Show)
instance Exception UnrecognizedShellException where
    displayException _ = "Unrecognized shell. Please add ~/.local/bin to your exports."

unrecognizedShellError :: SomeException
unrecognizedShellError = toException UnrecognizedShellException

getShExportFile :: MonadIO m => m (Maybe FilePath)
getShExportFile = do
    shellType <- checkShell
    let files = case shellType of
             Bash -> [".bashrc", ".bash_profile", ".profile"]
             Zsh  -> [".zshrc",  ".zprofile",     ".profile"]
             _    -> [".profile"]
    checkedFiles <- mapM runControlCheck files
    return $ listToMaybe $ catMaybes checkedFiles

--TODO extract common logic for all unix terminals
exportPathUnix :: (MonadIO m, MonadBaseControl IO m, LoggerMonad m, MonadCatch m) => FilePath -> m ()
exportPathUnix pathToExport = do
    pathIsDirectory    <- liftIO $ doesDirectoryExist $ encodeString pathToExport
    properPathToExport <- if pathIsDirectory then return pathToExport else do
        let parentDir = parent pathToExport
        Logger.warning $ convert $ encodeString pathToExport <> " is not a directory, exporting " <> encodeString parentDir <> " instead"
        return parentDir
    file               <- getShExportFile
    let pathToExportText = Shelly.toTextIgnore properPathToExport
        exportToAppend   = Text.concat ["\nexport PATH=", pathToExportText, ":$PATH\n"]
        warn             = Logger.warning "Unable to export Luna path. Please add ~/.local/bin to your PATH"
    case file of
        Just f  -> do
            let path = encodeString f
            Exception.handleAny (const warn) $ do
                exportExists <- Text.isInfixOf exportToAppend <$> liftIO (readFile path)
                unless exportExists $
                    (liftIO $ appendFile path exportToAppend)
        Nothing -> warn

exportPathWindows :: (LoggerMonad m, MonadIO m, MonadBaseControl IO m, LoggerMonad m) => FilePath -> m ()
exportPathWindows path = do
    Logger.log "System.exportPathWindows"
    (exitCode1, pathenv, err1) <- Process.readProcess $ "echo %PATH%"
    let pathToexport = Path.dropTrailingPathSeparator $ encodeString $ parent path
        systemPath   = unpack pathenv
    unless (isInfixOf pathToexport systemPath) $ do
        (exitCode, out, err) <- Process.readProcess $ Process.shell $ "setx PATH \"%PATH%;" ++ pathToexport ++ "\""
        unless (exitCode == ExitSuccess) $ Logger.warning $ "Path was not exported."

makeExecutable :: MonadIO m => FilePath -> m ()
makeExecutable file = unless (currentHost == Windows) $ liftIO $ do
        p <- getPermissions $ encodeString file
        setPermissions (encodeString file) (p {executable = True})

runServicesWindows :: (LoggerMonad m, MonadSh m, MonadIO m, MonadShControl m) => FilePath -> FilePath -> m ()
runServicesWindows path logsPath = Shelly.chdir path $ do
    Logger.log "System.runServicesWindows"
    Logger.log "Making the logs dir"
    Shelly.mkdir_p logsPath
    let installPath = path </> Shelly.fromText "installAll.bat"
    Shelly.setenv "LUNA_STUDIO_LOG_PATH" $ Shelly.toTextIgnore logsPath
    Shelly.silently $ Shelly.cmd installPath --TODO create proper error

stopServicesWindows :: (LoggerMonad m, MonadCatch m, MonadIO m) => FilePath -> m ()
stopServicesWindows path = Shelly.chdir path $ do
        let uninstallPath = path </> Shelly.fromText "uninstallAll.bat"
        Shelly.silently $ Shelly.cmd uninstallPath `catch` handler where
            handler :: (LoggerMonad m, MonadSh m) => SomeException -> m ()
            handler ex = Logger.exception "System.stopServicesWindows" ex -- Shelly.liftSh $ print ex --TODO create proper error
