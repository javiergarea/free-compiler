-- | This module contains the command line argument parser and the data type
--   that stores the values of the command line options.

module Compiler.Application.Options
  ( Options(..)
  , makeDefaultOptions
  , parseArgs
  , getOpts
  , putUsageInfo
  )
where

import           System.Console.GetOpt
import           System.Environment             ( getArgs
                                                , getProgName
                                                )

import           Compiler.Haskell.SrcSpan
import           Compiler.Monad.Reporter

import           Paths_haskellToCoqCompiler     ( getDataFileName )

-------------------------------------------------------------------------------
-- Command line option data type                                             --
-------------------------------------------------------------------------------

-- | Data type that stores the command line options passed to the compiler.
data Options = Options
  { optShowHelp   :: Bool
    -- ^ Flag that indicates whether to show the usage information.

  , optInputFiles :: [FilePath]
    -- ^ The input files passed to the compiler.
    --   All non-option command line arguments are considered input files.

  , optOutputDir  :: Maybe FilePath
    -- ^ The output directory or 'Nothing' if the output should be printed
    --   to @stdout@.

  , optBaseLibDir :: FilePath
    -- ^ The directory that contains the Coq Base library that accompanies
    --   this compiler.

  , optCreateCoqProject :: Bool
    -- ^ Flag that indicates whether to generate a @_CoqProject@ file in the
    --   ouput directory. This argument is ignored if 'optOutputDir' is not
    --   specified.
  }

-- | The default command line options.
--
--   By default output will be printed to the console.
makeDefaultOptions :: IO Options
makeDefaultOptions = do
  defaultBaseLibDir <- getDataFileName "base"
  return $ Options
    { optShowHelp         = False
    , optInputFiles       = []
    , optOutputDir        = Nothing
    , optBaseLibDir       = defaultBaseLibDir
    , optCreateCoqProject = True
    }

-------------------------------------------------------------------------------
-- Command line option parser                                                --
-------------------------------------------------------------------------------

-- | Command line option descriptors from the @GetOpt@ library.
options :: [OptDescr (Options -> Options)]
options
  = [ Option ['h']
             ["help"]
             (NoArg (\opts -> opts { optShowHelp = True }))
             "Display this message."
    , Option
      ['o']
      ["output"]
      (ReqArg (\p opts -> opts { optOutputDir = Just p }) "DIR")
      (  "Path to output directory.\n"
      ++ "Optional. Prints to the console by default."
      )
    , Option
      ['b']
      ["base-library"]
      (ReqArg (\p opts -> opts { optBaseLibDir = p }) "DIR")
      (  "Optional. Path to directory that contains the compiler's Coq\n"
      ++ "Base library. By default the compiler will look for the Base\n"
      ++ "library in it's data directory."
      )
    , Option
      []
      ["no-coq-project"]
      (NoArg (\opts -> opts { optCreateCoqProject = False }))
      (  "Disables the creation of a `_CoqProject` file in the output\n"
      ++ "directory. If the `--output` option is missing or the `_CoqProject`\n"
      ++ "file exists already, no `_CoqProject` is created.\n"
      )
    ]

-- | Parses the command line arguments.
--
--   If there are errors when parsing the command line arguments, a fatal
--   error message is reported.
--
--   All non-option arguments are considered as input files.
--
--   Returns the default options (first argument) if no arguments are
--   specified.
parseArgs
  :: Options  -- ^ The default options.
  -> [String] -- ^ The command line arguments.
  -> Reporter Options
parseArgs defaultOptions args
  | null errors = do
    let opts = foldr ($) defaultOptions optSetters
    return opts { optInputFiles = nonOpts }
  | otherwise = do
    mapM_ (report . Message NoSrcSpan Error) errors
    reportFatal $ Message
      NoSrcSpan
      Error
      (  "Failed to parse command line arguments.\n"
      ++ "Use '--help' for usage information."
      )
 where
  optSetters :: [Options -> Options]
  nonOpts :: [String]
  errors :: [String]
  (optSetters, nonOpts, errors) = getOpt Permute options args

-- | Gets the 'Options' for the command line arguments that were passed to
--   the application.
--
--   If there are no command line arguments the given default options are
--   returned. Otherwise the given options are modified accordingly.
getOpts :: Options -> ReporterIO Options
getOpts defaultOpts = do
  args <- lift getArgs
  hoist $ parseArgs defaultOpts args

-------------------------------------------------------------------------------
-- Help message                                                              --
-------------------------------------------------------------------------------

-- | The header of the help message.
--
--   This text is added before the description of the command line arguments.
usageHeader :: FilePath -> String
usageHeader progName =
  "Usage: "
    ++ progName
    ++ " [options...] <input-files...>\n\n"
    ++ "Command line options:"

-- | Prints the help message for the compiler.
--
--   The help message is displayed when the user specifies the "--help" option
--   or there are no input files.
putUsageInfo :: IO ()
putUsageInfo = do
  progName <- getProgName
  putStrLn (usageInfo (usageHeader progName) options)
