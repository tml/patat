--------------------------------------------------------------------------------
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
module Main where


--------------------------------------------------------------------------------
import           Control.Applicative          ((<$>), (<*>))
import           Control.Concurrent           (forkIO, threadDelay)
import qualified Control.Concurrent.Chan      as Chan
import           Control.Monad                (forever, unless, when)
import           Data.Monoid                  ((<>))
import           Data.Time                    (UTCTime)
import           Data.Version                 (showVersion)
import qualified Options.Applicative          as OA
import           Patat.Presentation
import qualified Paths_patat
import qualified System.Console.ANSI          as Ansi
import           System.Directory             (doesFileExist,
                                               getModificationTime)
import           System.Exit                  (exitFailure)
import qualified System.IO                    as IO
import qualified Text.PrettyPrint.ANSI.Leijen as PP
import           Prelude


--------------------------------------------------------------------------------
data Options = Options
    { oFilePath :: !FilePath
    , oForce    :: !Bool
    , oDump     :: !Bool
    , oWatch    :: !Bool
    } deriving (Show)


--------------------------------------------------------------------------------
parseOptions :: OA.Parser Options
parseOptions = Options
    <$> (OA.strArgument $
            OA.metavar "FILENAME" <>
            OA.help    "Input file")
    <*> (OA.switch $
            OA.long    "force" <>
            OA.short   'f' <>
            OA.help    "Force ANSI terminal" <>
            OA.hidden)
    <*> (OA.switch $
            OA.long    "dump" <>
            OA.short   'd' <>
            OA.help    "Just dump all slides and exit" <>
            OA.hidden)
    <*> (OA.switch $
            OA.long    "watch" <>
            OA.short   'w' <>
            OA.help    "Watch file for changes")


--------------------------------------------------------------------------------
parserInfo :: OA.ParserInfo Options
parserInfo = OA.info (OA.helper <*> parseOptions) $
    OA.fullDesc <>
    OA.header ("patat v" <> showVersion Paths_patat.version) <>
    OA.progDescDoc (Just desc)
  where
    desc = PP.vcat
        [ "Terminal-based presentations using Pandoc"
        , ""
        , "Controls:"
        , "- Next slide:             space, enter, l, right"
        , "- Previous slide:         backspace, h, left"
        , "- Go forward 10 slides:   j, down"
        , "- Go backward 10 slides:  k, up"
        , "- First slide:            0"
        , "- Last slide:             G"
        , "- Reload file:            r"
        , "- Quit:                   q"
        ]


--------------------------------------------------------------------------------
errorAndExit :: [String] -> IO a
errorAndExit msg = do
    mapM_ (IO.hPutStrLn IO.stderr) msg
    exitFailure


--------------------------------------------------------------------------------
assertAnsiFeatures :: IO ()
assertAnsiFeatures = do
    supports <- Ansi.hSupportsANSI IO.stdout
    unless supports $ errorAndExit
        [ "It looks like your terminal does not support ANSI codes."
        , "If you still want to run the presentation, use `--force`."
        ]


--------------------------------------------------------------------------------
main :: IO ()
main = do
    options   <- OA.customExecParser (OA.prefs OA.showHelpOnError) parserInfo
    errOrPres <- readPresentation (oFilePath options)
    pres      <- either (errorAndExit . return) return errOrPres

    unless (oForce options) assertAnsiFeatures

    if oDump options
        then dumpPresentation pres
        else interactiveLoop options pres
  where
    interactiveLoop :: Options -> Presentation -> IO ()
    interactiveLoop options pres0 = do
        IO.hSetBuffering IO.stdin IO.NoBuffering
        commandChan <- Chan.newChan

        _ <- forkIO $ forever $
            readPresentationCommand >>= Chan.writeChan commandChan

        mtime0 <- getModificationTime (pFilePath pres0)
        when (oWatch options) $ do
            _ <- forkIO $ watcher commandChan (pFilePath pres0) mtime0
            return ()

        let loop :: Presentation -> Maybe String -> IO ()
            loop pres mbError = do
                case mbError of
                    Nothing  -> displayPresentation pres
                    Just err -> displayPresentationError pres err

                c      <- Chan.readChan commandChan
                update <- updatePresentation c pres
                case update of
                    ExitedPresentation        -> return ()
                    UpdatedPresentation pres' -> loop pres' Nothing
                    ErroredPresentation err   -> loop pres (Just err)

        loop pres0 Nothing


--------------------------------------------------------------------------------
watcher :: Chan.Chan PresentationCommand -> FilePath -> UTCTime -> IO a
watcher chan filePath mtime0 = do
    -- The extra exists check helps because some editors temporarily make the
    -- file dissapear while writing.
    exists <- doesFileExist filePath
    mtime1 <- if exists then getModificationTime filePath else return mtime0

    when (mtime1 > mtime0) $ Chan.writeChan chan Reload
    threadDelay (200 * 1000)
    watcher chan filePath mtime1
