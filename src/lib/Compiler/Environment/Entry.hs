-- | This module contains data types that are used to store information
--   about declared functions, (type) variables and (type) constructors
--   in the environment.

module Compiler.Environment.Entry where

import           Data.Function                  ( on )
import           Data.Tuple.Extra               ( (&&&) )

import qualified Compiler.Coq.AST              as G
import           Compiler.Environment.Scope
import qualified Compiler.Haskell.AST          as HS
import           Compiler.Haskell.SrcSpan
import           Compiler.Util.Predicate

-- | Entry of the environment.
data EnvEntry
  = -- | Entry for a data type declaration.
    DataEntry
    { entrySrcSpan :: SrcSpan
      -- ^ The source code location where the data type was declared.
    , entryArity   :: Int
      -- ^ The number of type arguments expected by the type constructor.
    , entryIdent   :: G.Qualid
      -- ^ The name of the data type in Coq.
    , entryName    :: HS.QName
      -- ^ The name of the data type in the module it has been defined in.
    }
  | -- | Entry for a type synonym declaration.
    TypeSynEntry
    { entrySrcSpan  :: SrcSpan
      -- ^ The source code location where the type synonym was declared.
    , entryArity    :: Int
      -- ^ The number of type arguments expected by the type constructor.
    , entryTypeArgs :: [HS.TypeVarIdent]
      -- ^ The names of the type arguments.
    , entryTypeSyn  :: HS.Type
      -- ^ The type that is abbreviated by this type synonym.
    , entryIdent    :: G.Qualid
      -- ^ The name of the type synonym in Coq.
    , entryName     :: HS.QName
      -- ^ The name of the type synonym in the module it has been defined in.
    }
  | -- | Entry for a type variable.
    TypeVarEntry
    { entrySrcSpan :: SrcSpan
      -- ^ The source code location where the type variable was declared.
    , entryIdent   :: G.Qualid
      -- ^ The name of the type variable in Coq.
    , entryName    :: HS.QName
      -- ^ The name of the type variable (must be unqualified).
    }
  | -- | Entry for a data constructor.
    ConEntry
    { entrySrcSpan    :: SrcSpan
      -- ^ The source code location where the data constructor was declared.
    , entryArity      :: Int
      -- ^ The number of arguments expected by the data constructor.
    , entryArgTypes   :: [Maybe HS.Type]
      -- ^ The types of the constructor's arguments (if known).
      --   Contains exactly 'entryArity' elements.
    , entryReturnType :: Maybe HS.Type
      -- ^ The return type of the data constructor (if known).
    , entryIdent      :: G.Qualid
      -- ^ The name of the regular data constructor in Coq.
    , entrySmartIdent :: G.Qualid
      -- ^ The name of the corresponding smart constructor in Coq.
    , entryName       :: HS.QName
      -- ^ The name of the data constructor in the module it has been
      --   defined in.
    }
  | -- | Entry for a function declaration.
    FuncEntry
    { entrySrcSpan       :: SrcSpan
      -- ^ The source code location where the function was declared.
    , entryArity         :: Int
      -- ^ The number of arguments expected by the function.
    , entryTypeArgs      :: [HS.TypeVarIdent]
      -- ^ The names of the type arguments.
    , entryArgTypes      :: [Maybe HS.Type]
      -- ^ The types of the function arguments (if known).
      --   Contains exactly 'entryArity' elements.
    , entryReturnType    :: Maybe HS.Type
      -- ^ The return type of the function (if known).
    , entryNeedsFreeArgs :: Bool
      -- ^ Whether the arguments of the @Free@ monad need to be
      --   passed to the function.
    , entryIsPartial     :: Bool
      -- ^ Whether the function is partial, i.e., requires an instance of
      --   the @Partial@ type class when translated to Coq.
    , entryIdent         :: G.Qualid
      -- ^ The name of the function in Coq.
    , entryName          :: HS.QName
      -- ^ The name of the function in the module it has been defined in.
    }
  | -- | Entry for a variable.
    VarEntry
    { entrySrcSpan :: SrcSpan
      -- ^ The source code location where the variable was declared.
    , entryIsPure  :: Bool
      -- ^ Whether the variable has not been lifted to the free monad.
    , entryIdent   :: G.Qualid
      -- ^ The name of the variable in Coq.
    , entryName    :: HS.QName
      -- ^ The name of the variable (must be unqualified).
    }
 deriving Show

-------------------------------------------------------------------------------
-- Comparision                                                               --
-------------------------------------------------------------------------------

-- | Entries are identified by their original name.
instance Eq EnvEntry where
  (==) = (==) `on` entryScopedName

-- | Entries are ordered by their original name.
instance Ord EnvEntry where
  compare = compare `on` entryScopedName

-------------------------------------------------------------------------------
-- Getters                                                                   --
-------------------------------------------------------------------------------

-- | Gets the scope an entry needs to be defined in.
entryScope :: EnvEntry -> Scope
entryScope DataEntry{}    = TypeScope
entryScope TypeSynEntry{} = TypeScope
entryScope TypeVarEntry{} = TypeScope
entryScope ConEntry{}     = ValueScope
entryScope FuncEntry{}    = ValueScope
entryScope VarEntry{}     = ValueScope

-- | Gets the scope and name of the given entry.
entryScopedName :: EnvEntry -> ScopedName
entryScopedName = entryScope &&& entryName

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

-- | Tests whether the given entry of the environment describes a top-level
--   data type, type synonym, constructor or function.
--
--   Type variables and local variables are no top level entries.
isTopLevelEntry :: EnvEntry -> Bool
isTopLevelEntry = not . (isVarEntry .||. isTypeVarEntry)

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
