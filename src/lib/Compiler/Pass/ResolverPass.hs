{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- | This module contains a compiler pass that resolves all references in a
--   module to the original names of their declaration.
--
--   = Examples
--
--   == Example 1
--
--   If a module @B@ imports a module @A@ and @A@ exports a function @f@
--   (whose name has already been qualified to @A.f@)
--
--   @
--   module A where
--   A.f = 42
--   A.g = f
--
--   module B where
--   import A
--   B.h = f
--   @
--
--   all references to @f@ in both @A@ and @B@ are resolved to @A.f@.
--
--   @
--   module A where
--   A.f = 42
--   A.g = A.f
--
--   module B where
--   import A
--   B.h = A.f
--   @
--
--   = Specification
--
--   == Preconditions
--
--   * Module interfaces for all imported modules should be available.
--
--   * The names of all declarations in the module should have been qualified
--     with the name of the module.
--
--   == Translation
--
--   First two environments @Eᵀ@ and @Eⱽ@ are constructed. @Eᵀ@ denotes the
--   type-level environment and @Eⱽ@ denotes the value-level environment. The
--   environments map names in the module to sets of original names of the
--   entries the name could refer to. The environments are constructed as
--   follows.
--
--   * For each import declaration of the form
--
--     @
--     import M
--     @
--
--     the environments contain the exported names unqualified and
--     qualified with the name of the module @M@ (but not qualified with the
--     name of the module @N@ where they have been defined in originally).
--
--     @
--     N.t ∈ Mᵀ ⇒ N.t ∈ Eᵀ(t) ∧ N.t ∈ Eᵀ(M.t)
--     N.v ∈ Mⱽ ⇒ N.v ∈ Eⱽ(v) ∧ N.v ∈ Eⱽ(M.v)
--     @
--
--     where @Mᵀ@ and @Mⱽ@ denote the sets of original names of the entries
--     exported by the module @M@ at type- and value-level respectively.
--
--   * For each type synonym declaration of the form
--
--     @
--     type M.T α₁ … αₘ = τ
--     @
--
--     the type-level environment contains the qualified and unqualified
--     names of the type synonym.
--
--     @
--     M.T ∈ Eᵀ(T)
--     M.T ∈ Eᵀ(M.T)
--     @
--
--     Within the right-hand side @τ@, the type-level environment is extended
--     by the type arguments of the type-synonym.
--
--     @
--     ∀ 1 ≤ i ≤ m. αᵢ ∈ Eᵀ(αᵢ)
--     @
--
--   * For each data type declaration of the form
--
--     @
--     data D α₁ … αₘ = C₁ τ₍₁,₁₎ … τ₍₁,ₖ₁₎ | … | Cₙ τ₍ₙ,₁₎ … τ₍ₙ,ₖₙ₎
--     @
--
--     the type-level environment contains the qualified and unqualified
--     names of the data type and the value-level environment contains
--     the names of the constructors qualified and unqualified.
--
--     @
--     M.D ∈ Eᵀ(D) ∧ M.D ∈ Eᵀ(M.D)
--     ∀ 1 ≤ i ≤ n. M.Cᵢ ∈ Eⱽ(Cᵢ) ∧ M.Cᵢ ∈ Eⱽ(M.Cᵢ)
--     @
--
--     Within the fields @τ₍ᵢ,ⱼ₎@ of the constructors, the type-level
--     environment is extended by the type arguments of the data type.
--
--     @
--     ∀ 1 ≤ i ≤ m. αᵢ ∈ Eᵀ(αᵢ)
--     @
--
--   * For each function declaration of the form
--
--     @
--     M.f @α₁ … @αₘ (x₁ :: τ₁) … (xₙ :: τₙ) = e
--     @
--
--     the value-level environment contains the name of the function qualified
--     and unqualified.
--
--     @
--     M.f ∈ Eⱽ(f)
--     M.f ∈ Eⱽ(M.f)
--     @
--
--     Within the right-hand side @e@ and the type annotations @τᵢ@ of the
--     function's arguments, the type-level environment is extended by the
--     type arguments of the function and the value-level environment by the
--     regular arguments.
--
--     @
--     ∀ 1 ≤ i ≤ m. αᵢ ∈ Eᵀ(αᵢ)
--     ∀ 1 ≤ i ≤ n. xᵢ ∈ Eⱽ(xᵢ)
--     @
--
--   * Within lambda abstraction expressions and @case@ expression
--     alternatives of the form
--
--     @
--     \(x₁ :: τ₁) … (xₙ :: τₙ) -> e
--     case s of { …; C (x₁ :: τ₁) … (xₙ :: τₙ) -> e ; … }
--     @
--
--     the value-level environment is extended by the arguments of the lambda
--     abstraction and the variable patterns, respectively.
--
--     @
--     ∀ 1 ≤ i ≤ n. xᵢ ∈ Eⱽ(xᵢ)
--     @
--
--   The environments are then used to recursively resolve references in all
--   types and expression in the module. Local modifications that are performed
--   while descending into the AST are outlined above already.
--
--   * For each variable or constructor (including constructor patterns) @x@,
--     the name @x@ is looked up in the current value-level environment.
--
--       * If @Eⱽ(x) = ∅@, @x@ is not defined and a fatal error is reported.
--       * If @Eⱽ(x) = { x' }@, @x@ is defined and refers to the entry with
--         the original name @x'@. The occurrence of @x@ is replaced by @x'@.
--       * Otherwise @|Eⱽ(x)| ≥ 2@ and a fatal error is reported since the
--         occurrence of @x@ is ambiguous.
--
--    * For each type variable or type constructor @α@, the name @α@ is
--      looked up analogously in the current type-level environment and
--      replaced by the original name of the declaration it refers to.
--      If @α@ is not defined or ambiguous a fatal error is reported as well.
--
--   == Postconditions
--
--   * All names are qualified with the name of the module where the entry was
--     originally defined. All references are therefore unambiguous.
--
--   * All names refer to a declaration for which an entry will eventually be
--     added to the environment by subsequent passes.
--
--   == Error cases
--
--   * If there are multiple declarations with the same name in the same scope
--     and on the same nesting level, a fatal error is reported.
--
--   * If a name could not be resolved, a fatal error is reported.
--
--   * If a name could refer to multiple declarations (i.e., is ambiguous),
--     a fatal error is reported.
module Compiler.Pass.ResolverPass
  ( resolverPass
  )
where

import           Control.Monad.Fail             ( MonadFail )
import           Control.Monad.State            ( MonadState(..)
                                                , StateT(..)
                                                , evalStateT
                                                , gets
                                                , modify
                                                )
import           Data.Composition               ( (.:.) )
import           Data.Function                  ( on )
import           Data.List                      ( group
                                                , intercalate
                                                , sort
                                                )
import           Data.Map.Strict                ( Map )
import qualified Data.Map.Strict               as Map
import           Data.Set                       ( Set )
import qualified Data.Set                      as Set
import           Data.Tuple.Extra               ( (&&&) )

import           Compiler.Environment
import           Compiler.Environment.Scope
import qualified Compiler.IR.Syntax            as HS
import           Compiler.Haskell.SrcSpan
import           Compiler.Monad.Converter
import           Compiler.Monad.Reporter
import           Compiler.Pass
import           Compiler.Pretty         hiding ( group )

-- | Compiler pass that replaces all references by the original names of the
--   entries they refer to.
resolverPass :: Pass HS.Module
resolverPass ast = do
  env <- resolverEnvFromModule ast
  liftReporter $ runResolver env (resolve ast)

-------------------------------------------------------------------------------
-- Environment entries                                                       --
-------------------------------------------------------------------------------

-- | An entry of the resolver's environment.
--
--   Stores information about imported or locally defined names. Most of this
--   information is needed for error reporting. The original name of an entry
--   is used to actually resolve references.
data ResolverEntry
  = -- | Environment entry for an imported name.
    ImportedEntry
      { resolverEntrySrcSpan :: SrcSpan
        -- ^ The location of the @import@ that brought the entry into scope.
      , resolverEntryImportName :: HS.ModName
        -- ^ The name of the module the entry was imported from.
      , resolverEntryScope :: Scope
        -- ^ The scope the entry is defined in.
      , resolverEntryLocalName :: HS.QName
        -- ^ The qualified name of the entry in the current module.
      , resolverEntryOriginalName :: HS.QName
        -- ^ The name of the entry in the module it was originally defined in.
      }
  | -- | Environment entry for a locally defined name (for example, a top-level
    --   declaration or a local variable).
    LocalEntry
      { resolverEntrySrcSpan :: SrcSpan
        -- ^ The location of the declaration.
      , resolverEntryScope :: Scope
        -- ^ The scope of the declaration.
      , resolverEntryOriginalName :: HS.QName
        -- ^ The name of the declaration.
      }

-- | Gets the scope and name of the given entry.
resolverEntryScopedName :: ResolverEntry -> ScopedName
resolverEntryScopedName = resolverEntryScope &&& resolverEntryOriginalName

-- | Entries are identified by their original name.
--
--   Two entries are equal if they have the same original name and are
--   declared in the same scope.
instance Eq ResolverEntry where
  (==) = (==) `on` resolverEntryScopedName

-- | Entries are ordered by their scope and original name.
instance Ord ResolverEntry where
  compare = compare `on` resolverEntryScopedName

-- | Pretty prints the name of the given entry and there it has been declared
--   or imported for error messages.
instance Pretty ResolverEntry where
  pretty (ImportedEntry srcSpan importName _ localName originalName) =
    squotes (pretty localName)
      <>  comma
      <+> prettyString "imported from"
      <+> squotes (pretty importName)
      <+> prettyString "at"
      <+> pretty srcSpan
      <+> prettyOriginal
   where
    prettyOriginal :: Doc
    prettyOriginal
      | HS.Qual modName _ <- originalName
      = parens
        (prettyString "and originally defined in" <+> squotes (pretty modName))
      | otherwise
      = empty
  pretty (LocalEntry srcSpan _ originalName) =
    squotes (pretty originalName)
      <>  comma
      <+> prettyString "defined at"
      <+> pretty srcSpan

-------------------------------------------------------------------------------
-- Environment                                                               --
-------------------------------------------------------------------------------

-- | The environment data type that is used by the resolver to keep track
--   of which identifiers are in scope and what they refer to.
--
--   Each name can be associated with multiple entries as long as there is
--   no such reference.
newtype ResolverEnv = ResolverEnv
  { unwrapResolverEnv :: Map ScopedName (Set ResolverEntry)
  }

-- | Creates an environment that contains the given entries.
--
--   Each entry is associated with its original name.
resolverEnvFromEntries :: [ResolverEntry] -> ResolverEnv
resolverEnvFromEntries =
  resolverEnvFromNamedEntries . map (resolverEntryOriginalName &&& id)

-- | Like 'resolverEnvFromEntries' but the entries are associated with
--   an unqualified version of their original name.
--
--   This is used for unqualified imports.
resolverEnvFromUnQualEntries :: [ResolverEntry] -> ResolverEnv
resolverEnvFromUnQualEntries = resolverEnvFromNamedEntries
  . map (HS.toUnQual . resolverEntryOriginalName &&& id)

-- | Creates an environment that associates the given names with the given
--   entries.
resolverEnvFromNamedEntries :: [(HS.QName, ResolverEntry)] -> ResolverEnv
resolverEnvFromNamedEntries = ResolverEnv . Map.fromListWith Set.union . map
  (\(name, entry) -> ((resolverEntryScope entry, name), Set.singleton entry))

-- | Creates an environment that contains all entries of the given environments.
--
--   If multiple environments contain entries for the same name, all entries
--   are kept.
mergeResolverEnvs :: [ResolverEnv] -> ResolverEnv
mergeResolverEnvs =
  ResolverEnv . Map.unionsWith Set.union . map unwrapResolverEnv

-- | Creates an environment that contains all entries of both environments.
--
--   If the environments contain an entry for the same name, both entries
--   are kept.
mergeResolverEnv :: ResolverEnv -> ResolverEnv -> ResolverEnv
mergeResolverEnv e1 e2 = ResolverEnv
  (Map.unionWith Set.union (unwrapResolverEnv e1) (unwrapResolverEnv e2))

-- | Like 'mergeResolverEnv' but if both environments contain an entry for
--   the same name, only the entry from the first environment is kept.
shadowResolverEnv :: ResolverEnv -> ResolverEnv -> ResolverEnv
shadowResolverEnv e1 e2 =
  ResolverEnv (Map.union (unwrapResolverEnv e1) (unwrapResolverEnv e2))

-- | Looks up the resolver entries that have been associated with the given
--   name in the given scope.
lookupResolverEntries :: Scope -> HS.QName -> ResolverEnv -> Set ResolverEntry
lookupResolverEntries scope name env =
  Map.findWithDefault Set.empty (scope, name) (unwrapResolverEnv env)

-------------------------------------------------------------------------------
-- Modules                                                                   --
-------------------------------------------------------------------------------

-- | Creates an environment for the entries that are visible at top-level
--   of the given module.
--
--   In addition to top-level declarations, imported entries are visible
--   at top-level as well.
--
--   If there is a declaration with a name that is also imported, no error
--   is reported unless there is an actual reference (i.e., when the name is
--   looked up in the returned environment using 'lookupResolverEntryOrFail').
resolverEnvFromModule :: HS.Module -> Converter ResolverEnv
resolverEnvFromModule ast = do
  importEnv   <- resolverEnvFromImports (HS.modImports ast)
  topLevelEnv <- resolverEnvFromTopLevel ast
  return (importEnv `mergeResolverEnv` topLevelEnv)

-------------------------------------------------------------------------------
-- Imports                                                                   --
-------------------------------------------------------------------------------

-- | Creates an environment that contains entries for the exported names
--   of the modules imported by the given @import@ declarations.
--
--   If multiple imports bring different entries with the same name into
--   scope, both are entered into the environment. That the name is ambiguous
--   is reported only if there is an actual reference (i.e., when the name is
--   looked up in the returned environment using 'lookupResolverEntryOrFail').
resolverEnvFromImports :: [HS.ImportDecl] -> Converter ResolverEnv
resolverEnvFromImports = fmap mergeResolverEnvs . mapM resolverEnvFromImport

-- | Creates an environment that contains entries for the names exported by
--   the module that is imported by the given @import@ declaration.
--
--   The entries are brought into the environment both with their unqualified
--   name and qualified with the name of the module they are imported from
--   (not the name of the module they were originally defined in).
resolverEnvFromImport :: HS.ImportDecl -> Converter ResolverEnv
resolverEnvFromImport (HS.ImportDecl srcSpan modName) = do
  Just iface <- inEnv $ lookupAvailableModule modName
  let exports     = interfaceExports iface
      entries     = map makeImportedEntry (Set.toList exports)
      qualNames   = map resolverEntryLocalName entries
      unQualNames = map HS.toUnQual qualNames
  return $ resolverEnvFromNamedEntries
    (zip unQualNames entries ++ zip qualNames entries)
 where
  -- | Creates an entry for the import of the given name by the current
  --   import declaration.
  makeImportedEntry :: ScopedName -> ResolverEntry
  makeImportedEntry (scope, originalName) = ImportedEntry
    { resolverEntrySrcSpan      = srcSpan
    , resolverEntryImportName   = modName
    , resolverEntryScope        = scope
    , resolverEntryLocalName    = HS.toQual modName originalName
    , resolverEntryOriginalName = originalName
    }

-------------------------------------------------------------------------------
-- Top-level declarations                                                    --
-------------------------------------------------------------------------------

-- | Type class for declarations that declare top-level entries.
class TopLevelDeclaration node where
  -- | Gets the top-level entries declared by the given node.
  topLevelEntries :: node -> [ResolverEntry]

-- | A module declares all of the contained type synonym, data type and
--   function declarations at top-level.
instance TopLevelDeclaration HS.Module where
  topLevelEntries ast =
    concatMap topLevelEntries (HS.modTypeDecls ast)
      ++ concatMap topLevelEntries (HS.modFuncDecls ast)

-- | Type synonym declarations declare a type constructor at top-level and
--   data type declarations declare a type constructor and their data
--   constructors at top-level.
instance TopLevelDeclaration HS.TypeDecl where
  topLevelEntries typeSynDecl@HS.TypeSynDecl{} =
    [makeTopLevelEntry TypeScope (HS.typeDeclIdent typeSynDecl)]
  topLevelEntries dataDecl@HS.DataDecl{} =
    makeTopLevelEntry TypeScope (HS.typeDeclIdent dataDecl)
      : concatMap topLevelEntries (HS.dataDeclCons dataDecl)

-- | Constructors of data type declarations are declared at top-level.
instance TopLevelDeclaration HS.ConDecl where
  topLevelEntries conDecl =
    [makeTopLevelEntry ValueScope (HS.conDeclIdent conDecl)]

-- | Function declarations are declared at top-level.
instance TopLevelDeclaration HS.FuncDecl where
  topLevelEntries funcDecl =
    [makeTopLevelEntry ValueScope (HS.funcDeclIdent funcDecl)]

-- | Creates the entry for a top-level declaration with the given name
--   in the given scope.
makeTopLevelEntry :: Scope -> HS.DeclIdent -> ResolverEntry
makeTopLevelEntry scope declIdent = LocalEntry
  { resolverEntrySrcSpan      = HS.declIdentSrcSpan declIdent
  , resolverEntryScope        = scope
  , resolverEntryOriginalName = HS.declIdentName declIdent
  }

-- | Creates an environment that contains entries for top-level declarations.
--
--   Top-level declarations are brought into scope both with their qualified
--   and unqualified name.
--
--   There must not be two declarations for the same name in the same scope.
--   Otherwise a fatal error is reported.
resolverEnvFromTopLevel :: TopLevelDeclaration a => a -> Converter ResolverEnv
resolverEnvFromTopLevel node = do
  entries <- checkSingleDeclarations (topLevelEntries node)
  let qualEnv   = resolverEnvFromEntries entries
      unQualEnv = resolverEnvFromUnQualEntries entries
  return (qualEnv `mergeResolverEnv` unQualEnv)

-------------------------------------------------------------------------------
-- Local declarations                                                        --
-------------------------------------------------------------------------------

-- | Extends the environment with entries for the type variables declared by
--   the given declarations.
--
--   Reports a fatal error if there are multiple declarations for the same
--   type variable in the given list. Existing type variables can be shadowed.
defineTypeVars :: [HS.TypeVarDecl] -> Resolver ()
defineTypeVars typeVarDecls = do
  entries <- checkSingleDeclarations (map makeTypeVarEntry typeVarDecls)
  modify $ shadowResolverEnv (resolverEnvFromEntries entries)
 where
  makeTypeVarEntry :: HS.TypeVarDecl -> ResolverEntry
  makeTypeVarEntry typeVarDecl = LocalEntry
    { resolverEntrySrcSpan      = HS.typeVarDeclSrcSpan typeVarDecl
    , resolverEntryScope        = TypeScope
    , resolverEntryOriginalName = HS.typeVarDeclQName typeVarDecl
    }

-- | Extends the environment with entries for variables bound by the given
--   variable patterns.
--
--   Reports a fatal error if there are multiple patterns for the same variable
--   in the given list. However, existing variables can be shadowed.
defineVarPats :: [HS.VarPat] -> Resolver ()
defineVarPats varPats = do
  entries <- checkSingleDeclarations (map makeVarPatEntry varPats)
  modify $ shadowResolverEnv (resolverEnvFromEntries entries)
 where
  makeVarPatEntry :: HS.VarPat -> ResolverEntry
  makeVarPatEntry varPat = LocalEntry
    { resolverEntrySrcSpan      = HS.varPatSrcSpan varPat
    , resolverEntryScope        = ValueScope
    , resolverEntryOriginalName = HS.varPatQName varPat
    }

-------------------------------------------------------------------------------
-- Utility functions                                                         --
-------------------------------------------------------------------------------

-- | Tests whether the given list does not contain two entries with the
--   same name.
checkSingleDeclarations
  :: MonadReporter r => [ResolverEntry] -> r [ResolverEntry]
checkSingleDeclarations = mapM checkSingleDeclaration . group . sort

-- | Tests whether the given list of entries with the same name contains
--   exactly one element (i.e., there are not multiple entries with the
--   same name).
--
--   Reports a fatal error if there are multiple entries with the same name.
checkSingleDeclaration :: MonadReporter r => [ResolverEntry] -> r ResolverEntry
checkSingleDeclaration [entry] = return entry
checkSingleDeclaration entries = do
  let srcSpan = resolverEntrySrcSpan (last entries)
      name    = HS.toUnQual (resolverEntryOriginalName (head entries))
  reportFatal
    $  Message srcSpan Error
    $  "Multiple declarations of '"
    ++ showPretty name
    ++ "'\n"
    ++ "Declared at: "
    ++ intercalate " and " (map (showPretty . resolverEntrySrcSpan) entries)

-------------------------------------------------------------------------------
-- Resolver monad                                                            --
-------------------------------------------------------------------------------

-- | The state monad that is used to resolve references to the original names
--   of the referenced entries.
newtype Resolver a = Resolver
  { unwrapResolver :: StateT ResolverEnv Reporter a
  }
 deriving (Functor, Applicative, Monad, MonadState ResolverEnv, MonadFail)

-- | Errors can be reported when resolving references.
instance MonadReporter Resolver where
  liftReporter = Resolver . lift

-- | Runs the resolver with the given initial environment.
runResolver :: ResolverEnv -> Resolver a -> Reporter a
runResolver initialEnv = flip evalStateT initialEnv . unwrapResolver

-- | Runs the given resolver and resets all modifications to the environment
--   afterwards.
withLocalResolverEnv :: Resolver a -> Resolver a
withLocalResolverEnv mx = do
  env <- get
  x   <- mx
  put env
  return x

-- | Looks up the entry with the given name in the given scope.
--
--   If there is no such entry or the reference is ambiguous because multiple
--   entries are associated with the name, a fatal error is reported.
lookupResolverEntryOrFail
  :: SrcSpan -> Scope -> HS.QName -> Resolver ResolverEntry
lookupResolverEntryOrFail srcSpan scope name = do
  entrySet <- gets $ lookupResolverEntries scope name
  case Set.toList entrySet of
    [] ->
      reportFatal
        $  Message srcSpan Error
        $  fst (showPrettyScope scope)
        ++ " not in scope: '"
        ++ showPretty name
        ++ "'"
    [entry] -> return entry
    entries ->
      reportFatal
        $  Message srcSpan Error
        $  "Ambiguous occurrence of "
        ++ snd (showPrettyScope scope)
        ++ " '"
        ++ showPretty name
        ++ "'\n"
        ++ "It could refer to either "
        ++ intercalate " or " (map showPretty entries)
 where
  -- | Pretty prints the capitalized and the lower case name of the scopes.
  showPrettyScope :: Scope -> (String, String)
  showPrettyScope TypeScope  = ("Type", "type")
  showPrettyScope ValueScope = ("Value", "value")

-- | Looks up the original name of the entry associated with the given name
--   in the given scope.
--
--   If there is no such entry or the reference is ambiguous because multiple
--   entries are associated with the name, a fatal error is reported.
lookupOriginalNameOrFail :: SrcSpan -> Scope -> HS.QName -> Resolver HS.QName
lookupOriginalNameOrFail =
  fmap resolverEntryOriginalName .:. lookupResolverEntryOrFail

-- | Tests whether the given name has been associated with an entry in the
--   given scope.
--
--   If there is no such entry or the reference is ambiguous because multiple
--   entries are associated with the name, a fatal error is reported.
checkIsDefined :: SrcSpan -> Scope -> HS.QName -> Resolver ()
checkIsDefined srcSpan scope name = do
  _ <- lookupResolverEntryOrFail srcSpan scope name
  return ()

-------------------------------------------------------------------------------
-- Resolving references                                                      --
-------------------------------------------------------------------------------

-- | Type class for AST nodes that contain references which can be resolved.
class Resolvable node where
  resolve :: node -> Resolver node

-- | References in top-level declarations and type signatures can be
--   resolved.
instance Resolvable HS.Module where
  resolve ast = do
    typeDecls' <- mapM resolve (HS.modTypeDecls ast)
    typeSigs'  <- mapM resolve (HS.modTypeSigs ast)
    funcDecls' <- mapM resolve (HS.modFuncDecls ast)
    return ast { HS.modTypeDecls = typeDecls'
               , HS.modTypeSigs  = typeSigs'
               , HS.modFuncDecls = funcDecls'
               }

-- | References to other types can be resolved in type synonyms and the fields
--   of constructors of data type declarations.
--
--   On the right-hand sides of type declarations the type variables introduced
--   by the left-hand side can be referenced.
instance Resolvable HS.TypeDecl where
  resolve typeSynDecl@HS.TypeSynDecl{} = withLocalResolverEnv $ do
    defineTypeVars (HS.typeDeclArgs typeSynDecl)
    rhs' <- resolve (HS.typeSynDeclRhs typeSynDecl)
    return typeSynDecl { HS.typeSynDeclRhs = rhs' }
  resolve dataDecl@HS.DataDecl{} = withLocalResolverEnv $ do
    defineTypeVars (HS.typeDeclArgs dataDecl)
    cons' <- mapM resolve (HS.dataDeclCons dataDecl)
    return dataDecl { HS.dataDeclCons = cons' }

-- | References can be resolved in the field types of constructor declarations.
instance Resolvable HS.ConDecl where
  resolve conDecl = do
    fields' <- mapM resolve (HS.conDeclFields conDecl)
    return conDecl { HS.conDeclFields = fields' }

-- | References to types in type signatures can be resolved.
instance Resolvable HS.TypeSig where
  resolve typeSig = do
    typeSchema' <- resolve (HS.typeSigTypeSchema typeSig)
    return typeSig { HS.typeSigTypeSchema = typeSchema' }

-- | The type variables quantified by the @forall@ of a type schema can be
--   referenced by its type expression.
instance Resolvable HS.TypeSchema where
  resolve (HS.TypeSchema srcSpan args typeExpr) = withLocalResolverEnv $ do
    defineTypeVars args
    typeExpr' <- resolve typeExpr
    return (HS.TypeSchema srcSpan args typeExpr')

-- | References to type constructors can be resolved in type expressions and
--   all type variables that occur in the type expression must be declared.
instance Resolvable HS.Type where
  -- Type variables will always resolve to themselves, however we should still
  -- perform a lookup to make sure the type variable has been defined.
  resolve (HS.TypeVar srcSpan ident) = do
    checkIsDefined srcSpan TypeScope (HS.UnQual (HS.Ident ident))
    return (HS.TypeVar srcSpan ident)

  -- Lookup the original name
  resolve (HS.TypeCon srcSpan name) = do
    originalName <- lookupOriginalNameOrFail srcSpan TypeScope name
    return (HS.TypeCon srcSpan originalName)

  -- Resolve recursively.
  resolve (HS.TypeApp srcSpan t1 t2) = do
    t1' <- resolve t1
    t2' <- resolve t2
    return (HS.TypeApp srcSpan t1' t2')
  resolve (HS.FuncType srcSpan t1 t2) = do
    t1' <- resolve t1
    t2' <- resolve t2
    return (HS.FuncType srcSpan t1' t2')

-- | Types that are used in the type annotations of a function declaration
--   and functions and constructors that are used on the right-hand side
--   can be resolved.
--
--   The types in all annotations of the declaration can reference type
--   variables introduced on the left-hand side of the function declaration.
--   The variables bound by the arguments can be referenced on the right-hand
--   side of the function declaration.
instance Resolvable HS.FuncDecl where
  resolve funcDecl = withLocalResolverEnv $ do
    defineTypeVars (HS.funcDeclTypeArgs funcDecl)
    defineVarPats (HS.funcDeclArgs funcDecl)
    args'    <- mapM resolve (HS.funcDeclArgs funcDecl)
    rhs'     <- resolve (HS.funcDeclRhs funcDecl)
    retType' <- mapM resolve (HS.funcDeclReturnType funcDecl)
    return funcDecl { HS.funcDeclArgs       = args'
                    , HS.funcDeclRhs        = rhs'
                    , HS.funcDeclReturnType = retType'
                    }

-- | References to constructors and variables (including functions) can be
--   resolved in expressions. Additionally types in type annotations and
--   visible type applications are resolvable.
--
--   Variables introduced by variable patterns in lambda abstractions and
--   @case@ expression alternatives can be referenced on their right-hand
--   sides.
instance Resolvable HS.Expr where
  -- Lookup the original name of constructors and functions.
  resolve (HS.Con srcSpan conName exprType) = do
    originalName <- lookupOriginalNameOrFail srcSpan ValueScope conName
    exprType'    <- mapM resolve exprType
    return (HS.Con srcSpan originalName exprType')
  resolve (HS.Var srcSpan varName exprType) = do
    originalName <- lookupOriginalNameOrFail srcSpan ValueScope varName
    exprType'    <- mapM resolve exprType
    return (HS.Var srcSpan originalName exprType')

  -- Shadow lambda arguments and resolve recursively.
  resolve (HS.Lambda srcSpan args rhs exprType) = withLocalResolverEnv $ do
    defineVarPats args
    args'     <- mapM resolve args
    rhs'      <- resolve rhs
    exprType' <- mapM resolve exprType
    return (HS.Lambda srcSpan args' rhs' exprType')

  -- Resolve references recursively.
  resolve (HS.App srcSpan e1 e2 exprType) = do
    e1'       <- resolve e1
    e2'       <- resolve e2
    exprType' <- mapM resolve exprType
    return (HS.App srcSpan e1' e2' exprType')
  resolve (HS.TypeAppExpr srcSpan expr typeExpr exprType) = do
    expr'     <- resolve expr
    typeExpr' <- resolve typeExpr
    exprType' <- mapM resolve exprType
    return (HS.TypeAppExpr srcSpan expr' typeExpr' exprType')
  resolve (HS.If srcSpan e1 e2 e3 exprType) = do
    e1'       <- resolve e1
    e2'       <- resolve e2
    e3'       <- resolve e3
    exprType' <- mapM resolve exprType
    return (HS.If srcSpan e1' e2' e3' exprType')
  resolve (HS.Case srcSpan scrutinee alts exprType) = do
    scrutinee' <- resolve scrutinee
    alts'      <- mapM resolve alts
    exprType'  <- mapM resolve exprType
    return (HS.Case srcSpan scrutinee' alts' exprType')

  -- Only resolve in type annotation of other expressions.
  resolve (HS.Undefined srcSpan exprType) = do
    exprType' <- mapM resolve exprType
    return (HS.Undefined srcSpan exprType')
  resolve (HS.ErrorExpr srcSpan msg exprType) = do
    exprType' <- mapM resolve exprType
    return (HS.ErrorExpr srcSpan msg exprType')
  resolve (HS.IntLiteral srcSpan value exprType) = do
    exprType' <- mapM resolve exprType
    return (HS.IntLiteral srcSpan value exprType')

-- | The reference to the constructor in the constructor pattern of a
--   @case@-expression alternative as well as references to types in the
--   type annotations of variable patterns can be resolved.
--
--   References on the right-hand side are resolved recursively. The right-hand
--   can reference the variable patterns.
instance Resolvable HS.Alt where
  resolve (HS.Alt srcSpan conPat varPats rhs) = withLocalResolverEnv $ do
    defineVarPats varPats
    conPat'  <- resolve conPat
    varPats' <- mapM resolve varPats
    rhs'     <- resolve rhs
    return (HS.Alt srcSpan conPat' varPats' rhs')

-- | The name of the constructor matched by the a constructor pattern can be
--   resolved to its original name.
instance Resolvable HS.ConPat where
  resolve (HS.ConPat srcSpan conName) = do
    originalName <- lookupOriginalNameOrFail srcSpan ValueScope conName
    return (HS.ConPat srcSpan originalName)

-- | The types referenced by the type annotation of a variable pattern can
--   be resolved.
instance Resolvable HS.VarPat where
  resolve varPat = do
    varType' <- mapM resolve (HS.varPatType varPat)
    return varPat { HS.varPatType = varType' }
