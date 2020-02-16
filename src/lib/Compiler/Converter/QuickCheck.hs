-- | This module contains functions for converting simple QuickCheck properties
--   to Coq @Theorem@ sentences.
--
--   QuickCheck properties are functions that start with @prop_@ by convection.
--   However, the compiler uses the type of the property to determine whether
--   it is a QuickCheck property or not (i.e. all QuickCheck properties must
--   return a value of type @Property@).

module Compiler.Converter.QuickCheck where

import           Control.Monad.Extra            ( anyM
                                                , findM
                                                , partitionM
                                                )
import qualified Data.List.NonEmpty            as NonEmpty

import           Compiler.Analysis.DependencyAnalysis
import           Compiler.Converter.Expr
import           Compiler.Converter.FuncDecl.Common
import qualified Compiler.Coq.AST              as G
import           Compiler.Environment
import           Compiler.Environment.LookupOrFail
import           Compiler.Environment.Scope
import qualified Compiler.Haskell.AST          as HS
import           Compiler.Monad.Converter
import           Compiler.Monad.Reporter

-------------------------------------------------------------------------------
-- QuickCheck import                                                         --
-------------------------------------------------------------------------------

-- | The name of the QuickCheck module.
quickCheckModuleName :: HS.ModName
quickCheckModuleName = "Test.QuickCheck"

-- | The name of the @Property@ data type.
quickCheckPropertyName :: HS.QName
quickCheckPropertyName = HS.Qual quickCheckModuleName (HS.Ident "Property")

-------------------------------------------------------------------------------
-- Filter QuickCheck property declarations                                   --
-------------------------------------------------------------------------------

-- | Tests whether the given declaration is a QuickCheck property.
--
--   QuickCheck properties are functions with the prefix `prop_` or which
--   return a value of type `Property`.
isQuickCheckProperty :: HS.FuncDecl -> Converter Bool
isQuickCheckProperty (HS.FuncDecl srcSpan (HS.DeclIdent _ ident) args _) = do
  let name = HS.UnQual (HS.Ident ident)
  (HS.TypeSchema _ _ funcType) <- lookupTypeSigOrFail srcSpan name
  (_, returnType)              <- splitFuncType name args funcType
  isProperty returnType
 where
  -- | Tests whether the given type is the `Property`
  isProperty :: HS.Type -> Converter Bool
  isProperty (HS.TypeCon _ name) =
    inEnv $ refersTo quickCheckPropertyName TypeScope name
  isProperty _ = return False

-- | Tests whether the given strongly connected component of the function
--   dependency graph contains a QuickCheck property.
containsQuickCheckProperty :: DependencyComponent HS.FuncDecl -> Converter Bool
containsQuickCheckProperty (NonRecursive decl) = isQuickCheckProperty decl
containsQuickCheckProperty (Recursive decls) = anyM isQuickCheckProperty decls

-- | Partitions the given list of strongly connected components of the
--   function dependency graph into a list of QuickCheck properties
--   and dependency components that contain no QuickCheck properties.
--
--   Reports a fatal error message if there is there is a (mutually) recursive
--   QuickCheck property in one of the components.
filterQuickCheckProperties
  :: [DependencyComponent HS.FuncDecl]
  -> Converter ([HS.FuncDecl], [DependencyComponent HS.FuncDecl])
filterQuickCheckProperties components = do
  (quickCheckComponents, otherComponents) <- partitionM
    containsQuickCheckProperty
    components
  quickCheckProperties <- mapM fromNonRecursive quickCheckComponents
  return (quickCheckProperties, otherComponents)
 where
  -- | Extracts the only (non-recursive) QuickCheck property in the given
  --   strongly connected component.
  --
  --   Reports a fatal error message, if the given component contains
  --   recursive function declarations.
  fromNonRecursive :: DependencyComponent HS.FuncDecl -> Converter HS.FuncDecl
  fromNonRecursive (NonRecursive decl ) = return decl
  fromNonRecursive (Recursive    decls) = do
    Just property <- findM isQuickCheckProperty decls
    reportFatal
      $  Message (HS.getSrcSpan property) Error
      $  "QuickCheck properties must not be recursive. "
      ++ "Found (mutually) recursive function declarations: "
      ++ HS.prettyDeclIdents decls

-------------------------------------------------------------------------------
-- Convert QuickCheck property declarations                                  --
-------------------------------------------------------------------------------

-- | Converts the given QuickCheck property to a Coq @Theorem@ with an
--   empty @Proof@.
convertQuickCheckProperty :: HS.FuncDecl -> Converter [G.Sentence]
convertQuickCheckProperty (HS.FuncDecl _ declIdent args expr) = localEnv $ do
  let name = HS.UnQual (HS.Ident (HS.fromDeclIdent declIdent))
  (qualid, binders, _) <- convertFuncHead name args
  expr'                <- convertExpr expr
  return
    [ G.AssertionSentence
        (G.Assertion G.Theorem
                     qualid
                     []
                     (G.Forall (NonEmpty.fromList binders) expr')
        )
        G.blankProof
    ]
