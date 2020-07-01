-- | This module contains functions for parsing Haskell modules and other
--   nodes of the Haskell AST.
--
--   We are using the @haskell-src-ext@ package for parsing. This module just
--   provides an interface for the actual parser and configures the parser
--   appropriately.

module FreeC.Frontend.Haskell.Parser
  ( parseHaskell
    -- * Modules
  , parseHaskellModule
  , parseHaskellModuleWithComments
  , parseHaskellModuleFile
  , parseHaskellModuleFileWithComments
  )
where

import           Control.Monad.IO.Class         ( MonadIO(..) )

import qualified Language.Haskell.Exts.Comments
                                               as HSE
import           Language.Haskell.Exts.Extension
                                                ( Language(..)
                                                , Extension(..)
                                                , KnownExtension(..)
                                                )
import           Language.Haskell.Exts.Fixity   ( Fixity
                                                , infix_
                                                , infixl_
                                                , infixr_
                                                )
import           Language.Haskell.Exts.Parser   ( ParseMode(..)
                                                , ParseResult(..)
                                                , Parseable(..)
                                                )
import           Language.Haskell.Exts.SrcLoc   ( SrcSpanInfo )
import qualified Language.Haskell.Exts.Syntax  as HSE

import           FreeC.Frontend.Haskell.SrcSpanConverter
import           FreeC.IR.SrcSpan
import           FreeC.IR.Syntax               as IR
import           FreeC.Monad.Reporter

-- | Custom parameters for parsing a Haskell source file with the given name.
--
--   Only the given language extensions are enabled and no additional
--   language extensions can be enabled using pragmas.
makeParseMode :: [KnownExtension] -> FilePath -> ParseMode
makeParseMode enabledExts filename = ParseMode
  { parseFilename         = filename
  , baseLanguage          = Haskell2010
  , extensions            = map EnableExtension enabledExts
  , ignoreLanguagePragmas = True
  , ignoreLinePragmas     = True
    -- If this is set to @Nothing@, user defined fixities are ignored while
    -- parsing.
  , fixities              = Just predefinedFixities
  , ignoreFunctionArity   = True
  }

-- | Fixities for all predefined operators and infix constructors.
predefinedFixities :: [Fixity]
predefinedFixities = concat
  [ -- Prelude.
    infixr_ 8 ["^"]
  , infixl_ 7 ["*"]
  , infixl_ 6 ["+", "-"]
  , infixr_ 5 [":"]
  , infix_ 4 ["==", "/=", "<", "<=", ">=", ">"]
  , infixr_ 3 ["&&"]
  , infixr_ 2 ["||"]
  -- QuickCheck.
  , infixr_ 0 ["==>"]
  , infixr_ 1 [".&&.", ".||."]
  , infix_ 4 ["===", "=/="]
  ]

-- | Parses a node of the Haskell AST.
parseHaskell
  :: (Functor ast, Parseable (ast SrcSpanInfo), MonadReporter r)
  => SrcFile          -- ^ The name and contents of the Haskell source file.
  -> r (ast SrcSpan)
parseHaskell = fmap fst . parseHaskellWithComments

-- | Like 'parseHaskell' but returns comments in addition to the AST.
parseHaskellWithComments
  :: (Functor ast, Parseable (ast SrcSpanInfo), MonadReporter r)
  => SrcFile          -- ^ The name and contents of the Haskell source file.
  -> r (ast SrcSpan, [IR.Comment])
parseHaskellWithComments = parseHaskellWithCommentsAndExts []

-- | Like 'parseHaskellWithComments' but allows language extensions to be
--   enabled.
parseHaskellWithCommentsAndExts
  :: (Functor ast, Parseable (ast SrcSpanInfo), MonadReporter r)
  => [KnownExtension] -- ^ The extensions to enable.
  -> SrcFile          -- ^ The name and contents of the Haskell source file.
  -> r (ast SrcSpan, [IR.Comment])
parseHaskellWithCommentsAndExts enabledExts srcFile =
  case parseWithComments parseMode (srcFileContents srcFile) of
    ParseOk (node, comments) -> return
      ( fmap (toMessageSrcSpan :: SrcSpanInfo -> SrcSpan) node
      , map convertComment comments
      )
    ParseFailed loc msg ->
      reportFatal $ Message (toMessageSrcSpan loc) Error msg
 where
  -- | Configuration of the Haskell parser.
  parseMode :: ParseMode
  parseMode = makeParseMode enabledExts (srcFileName srcFile)

  -- | A map that maps the name of the Haskell source file to the lines of
  --   source code.
  srcFiles :: SrcFileMap
  srcFiles = mkSrcFileMap [srcFile]

  -- | Converts the source spans generated by the @haskell-src-exts@ package
  --   to source spans that can be used for pretty printing reported messages.
  --
  --   The 'srcFiles' are needed because when pretty printing a message,
  --   an excerpt of the code that caused the message to be reported is shown.
  toMessageSrcSpan :: ConvertibleSrcSpan l => l -> SrcSpan
  toMessageSrcSpan = convertSrcSpanWithCode srcFiles

  -- | Unlike all other AST nodes of @haskell-src-exts@, the
  --   'Language.Haskell.Exts.Comments.Comment' data type does
  --   not have a type parameter for the source span information.
  --   Therefore, we have to convert comments in this phase already.
  convertComment :: HSE.Comment -> IR.Comment
  convertComment (HSE.Comment isBlockComment srcSpan text)
    | isBlockComment = IR.BlockComment (toMessageSrcSpan srcSpan) text
    | otherwise      = IR.LineComment (toMessageSrcSpan srcSpan) text

-------------------------------------------------------------------------------
-- Modules                                                                   --
-------------------------------------------------------------------------------

-- | Parses a Haskell module.
--
--   Syntax errors cause a fatal error message to be reported.
parseHaskellModule
  :: MonadReporter r
  => SrcFile -- ^ The name and contents of the Haskell source file.
  -> r (HSE.Module SrcSpan)
parseHaskellModule = parseHaskell

-- | Like 'parseHaskellModule' but returns the comments in addition to the AST.
parseHaskellModuleWithComments
  :: MonadReporter r
  => SrcFile -- ^ The name and contents of the Haskell source file.
  -> r (HSE.Module SrcSpan, [IR.Comment])
parseHaskellModuleWithComments = parseHaskellWithComments

-- | Loads and parses a Haskell module from the file with the given name.
parseHaskellModuleFile
  :: (MonadIO r, MonadReporter r)
  => FilePath -- ^ The name of the Haskell source file.
  -> r (HSE.Module SrcSpan)
parseHaskellModuleFile = fmap fst . parseHaskellModuleFileWithComments

-- | Like 'parseHaskellModuleFile' but returns the comments in addition to
--   the AST.
parseHaskellModuleFileWithComments
  :: (MonadIO r, MonadReporter r)
  => FilePath -- ^ The name of the Haskell source file.
  -> r (HSE.Module SrcSpan, [IR.Comment])
parseHaskellModuleFileWithComments filename = do
  contents <- liftIO $ readFile filename
  parseHaskellModuleWithComments (mkSrcFile filename contents)
