module Compiler.Language.Haskell.Parser
  ( parseModule
  , parseModuleFile
  )
where

import           System.Exit                    ( exitFailure )

import           Language.Haskell.Exts.Extension
                                                ( Language(..) )
import           Language.Haskell.Exts.Parser   ( ParseMode(..)
                                                , ParseResult(..)
                                                , parseModuleWithMode
                                                )
import qualified Language.Haskell.Exts.Syntax  as H

import           Compiler.Pretty
import           Compiler.Reporter
import           Compiler.SrcSpan

-- | Custom parameters for parsing a Haskell source file with the given name.
--
--   All language extensions are disabled and cannot be enabled using pragmas.
parseMode :: String -> ParseMode
parseMode filename = ParseMode
  { parseFilename         = filename
  , baseLanguage          = Haskell98
  , extensions            = []
  , ignoreLanguagePragmas = True
  , ignoreLinePragmas     = True
    -- TODO because we support some infix operations from the prelude
    -- we should specify their fixities here.
    -- If this is set to @Nothing@, user defined fixities are ignored while
    -- parsing.
  , fixities              = Just []
  , ignoreFunctionArity   = True
  }

-- | Parses a Haskell module.
--
--   Syntax errors cause a fatal error message to be reported.
parseModule
  :: String  -- ^ The name of the Haskell source file.
  -> String  -- ^ The Haskell source code.
  -> Reporter (H.Module SrcSpan)
parseModule filename contents =
  case parseModuleWithMode (parseMode filename) contents of
    ParseOk ast -> return (fmap toMessageSrcSpan ast)
    ParseFailed loc msg ->
      reportFatal $ Message (Just (toMessageSrcSpan loc)) Error msg
 where
  -- | A map that maps the name of the Haskell source file to the lines of
  --   source code.
  codeByFilename :: [(String, [String])]
  codeByFilename = [(filename, lines contents)]

  -- | Converts the source spans generated by the @haskell-src-exts@ package
  --   to source spans that can be used for pretty printing reported messages.
  --
  --   The 'codeByFilename' is needed because when pretty printing a message,
  --   an excerpt of the code that caused the message to be reported is shown.
  toMessageSrcSpan :: SrcSpanConverter l => l -> SrcSpan
  toMessageSrcSpan = convertSrcSpan codeByFilename

-- | Loads and parses a Haskell module from the file with the given name.
--
--   Exists the application if a syntax error is encountered.
--   TODO Don't exit but return the reporter to the caller.
parseModuleFile
  :: String -- ^ The name of the Haskell source file.
  -> IO (H.Module SrcSpan)
parseModuleFile filename = do
  reporter <- reportIOErrors $ do
    contents <- readFile filename
    return (parseModule filename contents)
  putPretty (messages reporter)
  foldReporter reporter return exitFailure
