-- | This module contains data types that are used to store information
--   about declared functions, (type) variables and (type) constructors
--   in the environment.

module Compiler.Environment.Entry where

import qualified Compiler.Haskell.AST          as HS
import           Compiler.Haskell.SrcSpan

-- | Entry of the environment.
data EnvEntry
  = -- | Entry for a data type declaration.
    DataEntry
    { entrySrcSpan :: SrcSpan
      -- ^ The source code location where the data type was declared.
    , entryArity :: Int
      -- ^ The number of type arguments expected by the type constructor.
    , entryIdent :: String
      -- ^ The name of the data type in Coq.
    }
  | -- | Entry for a type synonym declaration.
    TypeSynEntry
    { entrySrcSpan :: SrcSpan
      -- ^ The source code location where the type synonym was declared.
    , entryArity :: Int
      -- ^ The number of type arguments expected by the type constructor.
    , entryTypeArgs :: [HS.TypeVarIdent]
      -- ^ The names of the type arguments.
    , entryTypeSyn :: HS.Type
      -- ^ The type that is abbreviated by this type synonym.
    , entryIdent :: String
      -- ^ The name of the type synonym in Coq.
    }
  | -- | Entry for a type variable.
    TypeVarEntry
    { entrySrcSpan :: SrcSpan
      -- ^ The source code location where the type variable was declared.
    , entryIdent :: String
      -- ^ The name of the type variable in Coq.
    }
  | -- | Entry for a data constructor.
    ConEntry
    { entrySrcSpan :: SrcSpan
      -- ^ The source code location where the data constructor was declared.
    , entryArity :: Int
      -- ^ The number of arguments expected by the data constructor.
    , entryArgTypes :: [Maybe HS.Type]
      -- ^ The types of the constructor's arguments (if known).
      --   Contains exactly 'entryArity' elements.
    , entryReturnType :: Maybe HS.Type
      -- ^ The return type of the data constructor (if known).
    , entryIdent :: String
      -- ^ The name of the regular data constructor in Coq.
    , entrySmartIdent :: String
      -- ^ The name of the corresponding smart constructor in Coq.
    }
  | -- | Entry for a function declaration.
    FuncEntry
    { entrySrcSpan :: SrcSpan
      -- ^ The source code location where the function was declared.
    , entryArity :: Int
      -- ^ The number of arguments expected by the function.
    , entryTypeArgs :: [HS.TypeVarIdent]
      -- ^ The names of the type arguments.
    , entryArgTypes :: [Maybe HS.Type]
      -- ^ The types of the function arguments (if known).
      --   Contains exactly 'entryArity' elements.
    , entryReturnType :: Maybe HS.Type
      -- ^ The return type of the function (if known).
    , entryIdent :: String
      -- ^ The name of the function in Coq.
    }
  | -- | Entry for a variable.
    VarEntry
    { entrySrcSpan :: SrcSpan
      -- ^ The source code location where the variable was declared.
    , entryIsPure :: Bool
      -- ^ Whether the variable has not been lifted to the free monad.
    , entryIdent :: String
      -- ^ The name of the variable in Coq.
    }
 deriving Show

-------------------------------------------------------------------------------
-- Predicates                                                                --
-------------------------------------------------------------------------------

-- | Tests whether the given entry of the environment describes a data type.
isDataEntry :: EnvEntry -> Bool
isDataEntry DataEntry{} = True
isDataEntry _           = False

-- | Tests whether the given entry of the environment describes a type synonym.
isTypeSynEntry :: EnvEntry -> Bool
isTypeSynEntry TypeSynEntry{} = True
isTypeSynEntry _              = False

-- | Tests whether the given entry of the environment describes a type
--   variable.
isTypeVarEntry :: EnvEntry -> Bool
isTypeVarEntry TypeVarEntry{} = True
isTypeVarEntry _              = False

-- | Tests whether the given entry of the environment describes a data
--   constructor.
isConEntry :: EnvEntry -> Bool
isConEntry ConEntry{} = True
isConEntry _          = False

-- | Tests whether the given entry of the environment describes a function.
isFuncEntry :: EnvEntry -> Bool
isFuncEntry FuncEntry{} = True
isFuncEntry _           = False

-- | Tests whether the given entry of the environment describes a variable.
isVarEntry :: EnvEntry -> Bool
isVarEntry VarEntry{} = True
isVarEntry _          = False

-------------------------------------------------------------------------------
-- Pretty printing                                                           --
-------------------------------------------------------------------------------

-- | Gets a human readable description of the entry type.
prettyEntryType :: EnvEntry -> String
prettyEntryType DataEntry{}    = "data type"
prettyEntryType TypeSynEntry{} = "type synonym"
prettyEntryType TypeVarEntry{} = "type variable"
prettyEntryType ConEntry{}     = "constructor"
prettyEntryType FuncEntry{}    = "function"
prettyEntryType VarEntry{}     = "variable"