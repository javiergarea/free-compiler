-- | This module contains functions for converting function declarations from
--   Haskell to Coq.

module Compiler.Converter.FuncDecl where

import           Control.Monad                  ( mapAndUnzipM
                                                , zipWithM
                                                )
import qualified Data.List.NonEmpty            as NonEmpty
import           Data.List                      ( (\\)
                                                , delete
                                                , elemIndex
                                                , intercalate
                                                )
import           Data.Map.Strict                ( Map )
import qualified Data.Map.Strict               as Map
import           Data.Maybe                     ( catMaybes
                                                , fromJust
                                                , fromMaybe
                                                , maybeToList
                                                )
import qualified Data.Set                      as Set
import           Data.Tuple.Extra               ( (&&&) )

import           Compiler.Analysis.DependencyAnalysis
import           Compiler.Analysis.DependencyExtraction
                                                ( typeVars
                                                , typeVarSet
                                                )
import           Compiler.Analysis.PartialityAnalysis
import           Compiler.Analysis.RecursionAnalysis
import           Compiler.Converter.Arg
import           Compiler.Converter.Expr
import           Compiler.Converter.Free
import           Compiler.Converter.Type
import qualified Compiler.Coq.AST              as G
import           Compiler.Environment
import           Compiler.Environment.Entry
import           Compiler.Environment.Fresh
import           Compiler.Environment.LookupOrFail
import           Compiler.Environment.Renamer
import           Compiler.Environment.Scope
import qualified Compiler.Haskell.AST          as HS
import           Compiler.Haskell.Inliner
import           Compiler.Haskell.SrcSpan
import           Compiler.Haskell.Subst
import           Compiler.Haskell.Subterm
import           Compiler.Monad.Converter
import           Compiler.Monad.Reporter
import           Compiler.Pretty

-------------------------------------------------------------------------------
-- Strongly connected components                                             --
-------------------------------------------------------------------------------

-- | Converts a strongly connected component of the function dependency graph.
convertFuncComponent
  :: DependencyComponent HS.FuncDecl -> Converter [G.Sentence]
convertFuncComponent (NonRecursive decl) = do
  defineFuncDecl decl
  decl' <- convertNonRecFuncDecl decl
  return [decl']
convertFuncComponent (Recursive decls) = do
  mapM_ defineFuncDecl decls
  convertRecFuncDecls decls

-------------------------------------------------------------------------------
-- Function declarations                                                     --
-------------------------------------------------------------------------------

-- | Converts the name, arguments and return type of a function to Coq.
--
--   This code is shared between the conversion functions for recursive and
--   no recursive functions (see 'convertNonRecFuncDecl' and
--   'convertRecFuncDecls').
convertFuncHead
  :: HS.QName    -- ^ The name of the function.
  -> [HS.VarPat] -- ^ The function argument patterns.
  -> Converter (G.Qualid, [G.Binder], Maybe G.Term)
convertFuncHead name args = do
  -- Lookup the Coq name of the function.
  Just qualid   <- inEnv $ lookupIdent ValueScope name
    -- Lookup type signature and partiality.
  partial       <- inEnv $ isPartial name
  Just typeArgs <- inEnv $ lookupTypeArgs ValueScope name
  Just argTypes <- inEnv $ lookupArgTypes ValueScope name
  returnType    <- inEnv $ lookupReturnType ValueScope name
  -- Convert arguments and return type.
  typeArgs'     <- generateTypeVarDecls G.Implicit typeArgs
  decArgIndex   <- inEnv $ lookupDecArg name
  args'         <- convertArgs args argTypes decArgIndex
  returnType'   <- mapM convertType returnType
  return
    ( qualid
    , (  genericArgDecls G.Explicit
      ++ [ partialArgDecl | partial ]
      ++ typeArgs'
      ++ args'
      )
    , returnType'
    )

-- | Inserts the given function declaration into the current environment.
defineFuncDecl :: HS.FuncDecl -> Converter ()
defineFuncDecl decl@(HS.FuncDecl srcSpan (HS.DeclIdent _ ident) args _) = do
  let name = HS.UnQual (HS.Ident ident)
  funcType               <- lookupTypeSigOrFail srcSpan name
  (argTypes, returnType) <- splitFuncType name args funcType
  partial                <- isPartialFuncDecl decl
  _                      <- renameAndAddEntry FuncEntry
    { entrySrcSpan    = srcSpan
    , entryArity      = length argTypes
    , entryTypeArgs   = catMaybes $ map HS.identFromQName $ typeVars funcType
    , entryArgTypes   = map Just argTypes
    , entryReturnType = Just returnType
    , entryIsPartial  = partial
    , entryName       = HS.UnQual (HS.Ident ident)
    , entryIdent      = undefined -- filled by renamer
    }
  return ()

-- | Splits the annotated type of a Haskell function with the given arguments
--   into its argument and return types.
--
--   Type synonyms are expanded if neccessary.
splitFuncType
  :: HS.QName    -- ^ The name of the function to display in error messages.
  -> [HS.VarPat] -- ^ The argument variable patterns whose types to split of.
  -> HS.Type     -- ^ The type to split.
  -> Converter ([HS.Type], HS.Type)
splitFuncType name = splitFuncType'
 where
  splitFuncType' :: [HS.VarPat] -> HS.Type -> Converter ([HS.Type], HS.Type)
  splitFuncType' []         typeExpr              = return ([], typeExpr)
  splitFuncType' (_ : args) (HS.TypeFunc _ t1 t2) = do
    (argTypes, returnType) <- splitFuncType' args t2
    return (t1 : argTypes, returnType)
  splitFuncType' args@(arg : _) typeExpr = do
    typeExpr' <- expandTypeSynonym typeExpr
    if typeExpr /= typeExpr'
      then splitFuncType' args typeExpr'
      else
        reportFatal
        $  Message (HS.getSrcSpan arg) Error
        $  "Could not determine type of argument '"
        ++ HS.fromVarPat arg
        ++ "' for function '"
        ++ showPretty name
        ++ "'."

-------------------------------------------------------------------------------
-- Non-recursive function declarations                                       --
-------------------------------------------------------------------------------

-- | Converts a non-recursive Haskell function declaration to a Coq
--   @Definition@ sentence.
convertNonRecFuncDecl :: HS.FuncDecl -> Converter G.Sentence
convertNonRecFuncDecl (HS.FuncDecl _ (HS.DeclIdent _ ident) args expr) =
  localEnv $ do
    let name = HS.UnQual (HS.Ident ident)
    (qualid, binders, returnType') <- convertFuncHead name args
    expr'                          <- convertExpr expr
    return (G.definitionSentence qualid binders returnType' expr')

-------------------------------------------------------------------------------
-- Recursive function declarations                                           --
-------------------------------------------------------------------------------

-- | Converts (mutually) recursive Haskell function declarations to Coq.
convertRecFuncDecls :: [HS.FuncDecl] -> Converter [G.Sentence]
convertRecFuncDecls decls = localEnv $ do
  -- Move constant arguments to section.
  constArgs <- identifyConstArgs decls
  if null constArgs
    then convertRecFuncDeclsWithHelpers decls
    else convertRecFuncDeclsWithSection constArgs decls

-------------------------------------------------------------------------------
-- Section generation                                                        --
-------------------------------------------------------------------------------

-- | Converts recursive function decarations and adds a @Section@ sentence
--   for the given constant arguments.
convertRecFuncDeclsWithSection
  :: [ConstArg] -> [HS.FuncDecl] -> Converter [G.Sentence]
convertRecFuncDeclsWithSection constArgs decls = do
  -- Lookup the argument and return types of all function declarations.
  (argTypeMaps, returnTypeMaps) <- mapAndUnzipM argAndReturnTypeMaps decls
  let argTypeMap    = Map.unions argTypeMaps
      returnTypeMap = Map.unions returnTypeMaps

  -- Create a @Variable@ sentence for the constant arguments and the type
  -- variables in the constant arguments types.
  constArgTypes <- mapM (lookupConstArgType argTypeMap) constArgs
  -- TODO apply mgu on all argument and return types.
  let typeArgNames  = Set.toList (Set.unions (map typeVarSet constArgTypes))
      typeArgIdents = map (fromJust . HS.identFromQName) typeArgNames
  typeArgSentence <- generateConstTypeArgSentence typeArgIdents
  varSentences    <- zipWithM generateConstArgVariable constArgs constArgTypes

  -- Remove the constant arguments from the function declarations and type
  -- signatures.
  decls'          <- mapM (removeConstArgsFromFuncDecl constArgs) decls
  mapM_ (updateTypeSigs typeArgIdents argTypeMap returnTypeMap) decls'

  -- Convert the resulting function declarations as usual.
  decls'' <- convertRecFuncDeclsWithHelpers decls'

  -- Generate a section identifier from the names of all functions in the
  -- section.
  let funcNames = map (HS.fromDeclIdent . HS.getDeclIdent) decls'
  sectionIdent <- freshCoqIdent (intercalate "_" ("section" : funcNames))
  return
    [ G.SectionSentence
        (G.Section
          (G.ident sectionIdent)
          (  G.comment
              ("Constant arguments for " ++ intercalate
                ", "
                (map (HS.fromDeclIdent . HS.getDeclIdent) decls)
              )
          :  maybeToList typeArgSentence
          ++ varSentences
          ++ decls''
          )
        )
    ]

-- | Gets a map that maps the names of the arguments (qualified with the
--   function name) of the given function declaration to their annotated
--   type and a second map that maps the function names to their annotated
--   return types.
argAndReturnTypeMaps
  :: HS.FuncDecl -> Converter (Map (String, String) HS.Type, Map String HS.Type)
argAndReturnTypeMaps (HS.FuncDecl srcSpan (HS.DeclIdent _ ident) args _) = do
  let name    = HS.UnQual (HS.Ident ident)
      funArgs = map (const ident &&& HS.fromVarPat) args
  funcType               <- lookupTypeSigOrFail srcSpan name
  (argTypes, returnType) <- splitFuncType name args funcType
  return (Map.fromList (zip funArgs argTypes), Map.singleton ident returnType)

-- | Looks up the type of a constant argument in the given argument type
--   map (see 'argAndReturnTypeMaps').
--
--   Does not check whether all arguments have the same type but returns the
--   first matching type.
lookupConstArgType
  :: Map (String, String) HS.Type -> ConstArg -> Converter HS.Type
lookupConstArgType argTypeMap constArg = do
  let idents = Map.assocs (constArgIdents constArg)
      types  = catMaybes $ map (flip Map.lookup argTypeMap) idents
  -- TODO unify all types and return mgu for type variables.
  return (head types)

-- | Removes constant arguments from the argument list of the given
--   function declaration and replaces the argument by the fresh
--   identifier of the constant argument.
--
--   The constant arguments are also removed from calls to functions
--   that share the constant argument.
removeConstArgsFromFuncDecl
  :: [ConstArg] -> HS.FuncDecl -> Converter HS.FuncDecl
removeConstArgsFromFuncDecl constArgs (HS.FuncDecl srcSpan declIdent args rhs)
  = do
    let ident = HS.fromDeclIdent declIdent
        removedArgs =
          fromJust
            $ Map.lookup ident
            $ Map.unionsWith (++)
            $ map (Map.map return)
            $ map constArgIdents constArgs
        freshArgs = map constArgFreshIdent constArgs
        args' = [ arg | arg <- args, HS.fromVarPat arg `notElem` removedArgs ]
        subst = composeSubsts
          [ singleSubst' (HS.UnQual (HS.Ident removedArg))
                         (flip HS.Var (HS.UnQual (HS.Ident freshArg)))
          | (removedArg, freshArg) <- zip removedArgs freshArgs
          ]
    rhs' <- applySubst subst rhs >>= removeConstArgsFromExpr constArgs
    return (HS.FuncDecl srcSpan declIdent args' rhs')

-- | Removes constant arguments from the applications in the given expressions.
removeConstArgsFromExpr :: [ConstArg] -> HS.Expr -> Converter HS.Expr
removeConstArgsFromExpr constArgs = flip removeConstArgsFromExpr' []
 where
  -- | Maps the name of functions that share the constant arguments to
  --   the indicies of their corresponding argument.
  constArgIndicesMap :: Map String [Int]
  constArgIndicesMap =
    Map.unionsWith (++) $ map (Map.map return) $ map constArgIndicies constArgs

  -- | Looks up the indicies of arguments that can be removed from the
  --   application of a function with the given name.
  lookupConstArgIndicies :: HS.QName -> Converter [Int]
  lookupConstArgIndicies (HS.UnQual name) =
    return (lookupConstArgIndicies' name)
  lookupConstArgIndicies (HS.Qual modName name) = do
    modName' <- inEnv envModName
    if modName == modName'
      then return []
      else return (lookupConstArgIndicies' name)

  -- | Like 'lookupConstArgIndicies' for unqualified names.
  lookupConstArgIndicies' :: HS.Name -> [Int]
  lookupConstArgIndicies' (HS.Ident ident) =
    fromMaybe [] $ Map.lookup ident constArgIndicesMap
  lookupConstArgIndicies' (HS.Symbol _) = []

  -- | Implementation of 'removeConstArgsFromExpr' that takes the current
  --   sub-expression as its first argument and the arguments it has been
  --   applied to as the second argument.
  removeConstArgsFromExpr'
    :: HS.Expr    -- ^ The expression to remove the constant arguments from.
    -> [HS.Expr]  -- ^ The arguments the expression is applied to.
    -> Converter HS.Expr

  -- If a variable is applied, lookup the indicies of the arguments that
  -- can be removed and remove them.
  removeConstArgsFromExpr' expr@(HS.Var _ name) args = do
    indicies <- lookupConstArgIndicies name
    let args' =
          map fst $ filter ((`notElem` indicies) . snd) $ zip args [0 ..]
    return (HS.app NoSrcSpan expr args')

  -- Remove the constant arguments from the argument and pass the argument
  -- to the applied expression such that it can remove it if necessary.
  removeConstArgsFromExpr' (HS.App _ e1 e2) args = do
    e2' <- removeConstArgsFromExpr' e2 []
    removeConstArgsFromExpr' e1 (e2' : args)

  -- Since we do not know in which branch there is a call to a function which
  -- shares the constant argument, we have to move the argument list into
  -- both branches and remove the arguments individually.
  removeConstArgsFromExpr' (HS.If srcSpan e1 e2 e3) args = do
    e1' <- removeConstArgsFromExpr' e1 []
    e2' <- removeConstArgsFromExpr' e2 args
    e3' <- removeConstArgsFromExpr' e3 args
    return (HS.If srcSpan e1' e2' e3')

  -- Similar to an @if@ expression, the arguments need to be moved into
  -- the alternatives of a @case@ expression.
  removeConstArgsFromExpr' (HS.Case srcSpan expr alts) args = do
    expr' <- removeConstArgsFromExpr' expr []
    alts' <- mapM (flip removeConstArgsFromAlt args) alts
    return (HS.Case srcSpan expr' alts')

  removeConstArgsFromExpr' (HS.Lambda srcSpan varPats expr) args = do
    -- TODO shadow varPats in expr
    expr' <- removeConstArgsFromExpr' expr args
    return (HS.Lambda srcSpan varPats expr')

  -- Leave all other expressions unchanged.
  removeConstArgsFromExpr' expr args = return (HS.app NoSrcSpan expr args)

  -- | Applies 'removeConstArgsFromExpr'' to the right-hand side of the
  --   given @case@ expression alternative.
  removeConstArgsFromAlt :: HS.Alt -> [HS.Expr] -> Converter HS.Alt
  removeConstArgsFromAlt (HS.Alt srcSpan conPat varPats expr) args = do
    -- TODO shadow varPats in expr
    expr' <- removeConstArgsFromExpr' expr args
    return (HS.Alt srcSpan conPat varPats expr')

-- | Modifies the type signature of the given function declaration, such that
--   it does not include the removed constant arguments anymore.
updateTypeSigs
  :: [HS.TypeVarIdent]
  -> Map (String, String) HS.Type
  -> Map String HS.Type
  -> HS.FuncDecl
  -> Converter ()
updateTypeSigs constTypeVars argTypeMap returnTypeMap (HS.FuncDecl _ declIdent args _)
  = do
  -- Modify type signature.
    let ident      = HS.fromDeclIdent declIdent
        name       = HS.UnQual (HS.Ident ident)
        funArgs    = map (const ident &&& HS.fromVarPat) args
        argTypes   = catMaybes (map (flip Map.lookup argTypeMap) funArgs)
        returnType = fromJust (Map.lookup ident returnTypeMap)
        funcType   = HS.funcType NoSrcSpan argTypes returnType
    modifyEnv $ defineTypeSig name funcType
    -- Modify entry.
    Just entry <- inEnv $ lookupEntry ValueScope name
    let entry' = entry { entryTypeArgs   = entryTypeArgs entry \\ constTypeVars
                       , entryArgTypes   = map Just argTypes
                       , entryReturnType = Just returnType
                       }
    modifyEnv $ addEntry name entry'
    modifyEnv $ addEntry (entryName entry) entry'

-- | Generates the @Variable@ sentence for the type variables in the given
--   types of the constant arguments.
generateConstTypeArgSentence
  :: [HS.TypeVarIdent] -> Converter (Maybe G.Sentence)
generateConstTypeArgSentence typeVarIdents
  | null typeVarIdents = return Nothing
  | otherwise = do
    let srcSpans = repeat NoSrcSpan
    typeVarIdents' <- zipWithM renameAndDefineTypeVar srcSpans typeVarIdents
    return (Just (G.variable typeVarIdents' G.sortType))

-- | Generates a @Variable@ sentence for a constant argument with the
--   given type.
generateConstArgVariable :: ConstArg -> HS.Type -> Converter G.Sentence
generateConstArgVariable constArg constArgType = do
  let ident = constArgFreshIdent constArg
  constArgType' <- convertType constArgType
  ident'        <- renameAndDefineVar NoSrcSpan False ident
  return (G.variable [ident'] constArgType')

-------------------------------------------------------------------------------
-- Helper function generation                                                --
-------------------------------------------------------------------------------

-- | Converts recursive function declarations into recursive helper and
--   non-recursive main functions.
convertRecFuncDeclsWithHelpers :: [HS.FuncDecl] -> Converter [G.Sentence]
convertRecFuncDeclsWithHelpers decls = do
  -- Split into helper and main functions.
  decArgs                  <- identifyDecArgs decls
  (helperDecls, mainDecls) <- mapAndUnzipM (uncurry transformRecFuncDecl)
                                           (zip decls decArgs)
  -- Convert helper and main functions.
  -- The right hand side of the main functions are inlined into helper the
  -- functions. Because inlining can produce fesh identifiers, we need to
  -- perform inlining and conversion of helper functions in a local environment.
  helperDecls' <- flip mapM (concat helperDecls) $ \helperDecl -> localEnv $ do
    inlinedHelperDecl <- inlineFuncDecls mainDecls helperDecl
    convertRecHelperFuncDecl inlinedHelperDecl
  mainDecls' <- mapM convertNonRecFuncDecl mainDecls

  -- Create common fixpoint sentence for all helper functions.
  return
    ( G.comment ("Helper functions for " ++ HS.prettyDeclIdents decls)
    : G.FixpointSentence (G.Fixpoint (NonEmpty.fromList helperDecls') [])
    : mainDecls'
    )

-- | Transforms the given recursive function declaration with the specified
--   decreasing argument into recursive helper functions and a non recursive
--   main function.
transformRecFuncDecl
  :: HS.FuncDecl -> DecArgIndex -> Converter ([HS.FuncDecl], HS.FuncDecl)
transformRecFuncDecl (HS.FuncDecl srcSpan declIdent args expr) decArgIndex = do
  -- Generate a helper function declaration and application for each case
  -- expression of the decreasing argument.
  (helperDecls, helperApps) <- mapAndUnzipM generateHelperDecl caseExprsPos

  -- Generate main function declaration. The main function's right hand side
  -- is constructed by replacing all case expressions of the decreasing
  -- argument by an invocation of the corresponding recursive helper function.
  let (Just mainExpr) = replaceSubterms expr (zip caseExprsPos helperApps)
      mainDecl        = HS.FuncDecl srcSpan declIdent args mainExpr

  return (helperDecls, mainDecl)
 where
  -- | The name of the function to transform.
  name :: HS.QName
  name = HS.UnQual (HS.Ident (HS.fromDeclIdent declIdent))

  -- | The names of the function's arguments.
  argNames :: [HS.QName]
  argNames = map (HS.UnQual . HS.Ident . HS.fromVarPat) args

  -- | The name of the decreasing argument.
  decArg :: HS.QName
  decArg = argNames !! decArgIndex

  -- | The positions of @case@-expressions for the decreasing argument.
  caseExprsPos :: [Pos]
  caseExprsPos = [ p | p <- ps, all (not . below p) (delete p ps) ]
   where
    ps :: [Pos]
    ps = filter decArgNotShadowed (findSubtermPos isCaseExpr expr)

  -- | Tests whether the given expression is a @case@-expression for the
  --   the decreasing argument.
  isCaseExpr :: HS.Expr -> Bool
  isCaseExpr (HS.Case _ (HS.Var _ varName) _) = varName == decArg
  isCaseExpr _ = False

  -- | Ensures that the decreasing argument is not shadowed by the binding
  --   of a local variable at the given position.
  decArgNotShadowed :: Pos -> Bool
  decArgNotShadowed p = decArg `Set.notMember` boundVarsAt expr p

  -- | Generates the recursive helper function declaration for the @case@
  --   expression at the given position of the right hand side.
  --
  --   Returns the helper function declaration and an expression for the
  --   application of the helper function.
  generateHelperDecl :: Pos -> Converter (HS.FuncDecl, HS.Expr)
  generateHelperDecl caseExprPos = do
    -- Generate a fresh name for the helper function.
    helperIdent <- freshHaskellIdent (HS.fromDeclIdent declIdent)
    let helperName      = HS.UnQual (HS.Ident helperIdent)
        helperDeclIdent = HS.DeclIdent (HS.getSrcSpan declIdent) helperIdent

    -- Pass used variables as additional arguments to the helper function
    -- but don't pass shadowed arguments to helper function.
    let
      nonArgVars     = boundVarsAt expr caseExprPos
      boundVars      = nonArgVars `Set.union` Set.fromList argNames
      usedVars       = usedVarsAt expr caseExprPos
      helperArgNames = Set.toList (usedVars `Set.intersection` boundVars)
      helperArgs =
        map (HS.VarPat NoSrcSpan . fromJust . HS.identFromQName) helperArgNames

    -- Build helper function declaration and application.
    let (Just caseExpr) = selectSubterm expr caseExprPos
        helperDecl = HS.FuncDecl srcSpan helperDeclIdent helperArgs caseExpr
        helperApp = HS.app NoSrcSpan
                           (HS.Var NoSrcSpan helperName)
                           (map (HS.Var NoSrcSpan) helperArgNames)

    -- Register the helper function to the environment.
    -- The types of the original parameters are known, but we neither know the
    -- type of the additional parameters nor the return type of the helper
    -- function.
    -- If the original function was partial, the helper function is partial as
    -- well.
    Just typeArgs      <- inEnv $ lookupTypeArgs ValueScope name
    funcType      <- lookupTypeSigOrFail srcSpan name
    (argTypes, _) <- splitFuncType name args funcType
    let argTypeMap = foldr Map.delete
                           (Map.fromList (zip argNames argTypes))
                           (Set.toList nonArgVars)
        argTypes' = map (`Map.lookup` argTypeMap) helperArgNames
    partial <- inEnv $ isPartial name
    _       <- renameAndAddEntry $ FuncEntry
      { entrySrcSpan    = NoSrcSpan
      , entryArity      = length argTypes'
      , entryTypeArgs   = typeArgs
      , entryArgTypes   = argTypes'
      , entryReturnType = Nothing
      , entryIsPartial  = partial
      , entryName       = HS.UnQual (HS.Ident helperIdent)
      , entryIdent      = undefined -- filled by renamer
      }

    -- Additionally we need to remember the index of the decreasing argument
    -- (see 'convertDecArg').
    let (Just decArgIndex') = elemIndex decArg helperArgNames
    modifyEnv $ defineDecArg helperName decArgIndex'

    return (helperDecl, helperApp)

-- | Converts a recursive helper function to the body of a Coq @Fixpoint@
--   sentence.
convertRecHelperFuncDecl :: HS.FuncDecl -> Converter G.FixBody
convertRecHelperFuncDecl (HS.FuncDecl _ declIdent args expr) = localEnv $ do
  let helperName = HS.UnQual (HS.Ident (HS.fromDeclIdent declIdent))
      argNames   = map (HS.UnQual . HS.Ident . HS.fromVarPat) args
  (qualid, binders, returnType') <- convertFuncHead helperName args
  expr'                          <- convertExpr expr
  Just decArgIndex               <- inEnv $ lookupDecArg helperName
  Just decArg' <- inEnv $ lookupIdent ValueScope (argNames !! decArgIndex)
  return
    (G.FixBody qualid
               (NonEmpty.fromList binders)
               (Just (G.StructOrder decArg'))
               returnType'
               expr'
    )
