-- | This module contains functions for parsing Haskell modules and other
--   nodes of the Haskell AST.

module Compiler.Language.Haskell.Parser
  ( parseHaskell
  , parseModule
  , parseModuleFile
  , parseDecl
  , parseType
  , parseExpr
  )
where

import           Language.Haskell.Exts.Extension
                                                ( Language(..) )
import           Language.Haskell.Exts.Parser   ( ParseMode(..)
                                                , Parseable(..)
                                                , ParseResult(..)
                                                )
import           Language.Haskell.Exts.SrcLoc   ( SrcSpanInfo )
import qualified Language.Haskell.Exts.Syntax  as H

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

-- | Parses a node of the Haskell AST.
parseHaskell
  :: (Functor ast, Parseable (ast SrcSpanInfo))
  => String -- ^ The name of the Haskell source file.
  -> String -- ^ The Haskell source code.
  -> Reporter (ast SrcSpan)
parseHaskell filename contents =
  case parseWithMode (parseMode filename) contents of
    ParseOk node ->
      return (fmap (toMessageSrcSpan :: SrcSpanInfo -> SrcSpan) node)
    ParseFailed loc msg -> do
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

-------------------------------------------------------------------------------
-- Modules                                                                   --
-------------------------------------------------------------------------------

-- | Parses a Haskell module.
--
--   Syntax errors cause a fatal error message to be reported.
parseModule
  :: String  -- ^ The name of the Haskell source file.
  -> String  -- ^ The Haskell source code.
  -> Reporter (H.Module SrcSpan)
parseModule = parseHaskell

-- | Loads and parses a Haskell module from the file with the given name.
parseModuleFile
  :: String -- ^ The name of the Haskell source file.
  -> ReporterIO (H.Module SrcSpan)
parseModuleFile filename = reportIOErrors $ do
  contents <- lift $ readFile filename
  hoist $ parseModule filename contents

-------------------------------------------------------------------------------
-- Declarations                                                              --
-------------------------------------------------------------------------------

-- | Parses a Haskell type.
parseDecl
  :: String -- ^ The name of the Haskell source file.
  -> String -- ^ The Haskell source code.
  -> Reporter (H.Decl SrcSpan)
parseDecl = parseHaskell

-------------------------------------------------------------------------------
-- Types                                                                   --
-------------------------------------------------------------------------------

-- | Parses a Haskell type.
parseType
  :: String -- ^ The name of the Haskell source file.
  -> String -- ^ The Haskell source code.
  -> Reporter (H.Type SrcSpan)
parseType = parseHaskell

-------------------------------------------------------------------------------
-- Expressions                                                               --
-------------------------------------------------------------------------------

-- | Parses a Haskell expression.
parseExpr
  :: String -- ^ The name of the Haskell source file.
  -> String -- ^ The Haskell source code.
  -> Reporter (H.Exp SrcSpan)
parseExpr = parseHaskell
