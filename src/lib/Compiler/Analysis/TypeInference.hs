-- | This module contains a function for infering the type of an expression.

module Compiler.Analysis.TypeInference
  ( -- * Function declarations
    inferFuncDeclTypes
  , addTypeAppExprsToFuncDecls
  , addTypeAppExprsToFuncDecls'
    -- * Expressions
  , inferExprType
  , addTypeAppExprs
  , addTypeAppExprs'
  )
where

import           Control.Applicative            ( (<|>) )
import           Control.Monad.Extra            ( concatMapM
                                                , ifM
                                                , mapAndUnzipM
                                                , replicateM
                                                )
import           Control.Monad.Writer
import           Data.Composition               ( (.:) )
import           Data.List                      ( (\\)
                                                , nub
                                                , partition
                                                )
import           Data.Maybe                     ( fromJust )

import           Compiler.Analysis.DependencyExtraction
                                                ( typeVars )
import           Compiler.Environment
import           Compiler.Environment.Fresh
import           Compiler.Environment.Scope
import qualified Compiler.Haskell.AST          as HS
import           Compiler.Haskell.SrcSpan
import           Compiler.Haskell.Subst
import           Compiler.Haskell.Unification
import           Compiler.Monad.Converter
import           Compiler.Monad.Reporter
import           Compiler.Pretty
import           Compiler.Util.Predicate        ( (.||.) )

-------------------------------------------------------------------------------
-- Function declarations                                                     --
-------------------------------------------------------------------------------

-- | Tries to infer the types of (mutually recursive) function declarations.
inferFuncDeclTypes :: [HS.FuncDecl] -> Converter [HS.TypeSchema]
inferFuncDeclTypes = fmap snd . addTypeAppExprsToFuncDecls'

-- | Like 'inferFuncDeclTypes' but does not abstract the type to a type
--   schema and returns the substitution.
inferFuncDeclTypes' :: [HS.FuncDecl] -> Converter ([HS.Type], Subst HS.Type)
inferFuncDeclTypes' funcDecls = localEnv $ do
  (typedExprs, funcTypes) <- mapAndUnzipM makeTypedExprs funcDecls
  eqns                    <- execTypedExprSimplifier $ do
    zipWithM_ addTypeSigEquation funcDecls funcTypes
    concatMapM (uncurry simplifyTypedExpr) (concat typedExprs)
  mgu        <- unifyEquations eqns
  funcTypes' <- mapM (applySubst mgu) funcTypes
  return (funcTypes', mgu)

-- | Creates fresh type variables @a@ and @a1 ... an@ and the expression/type
--   pairs @f :: a1 -> ... -> an -> a, x1 :: a1, ..., xn :: an@ and @e :: a@
--   for the given function declaration @f x1 ... xn = e@ and returns the
--   expression/type pairs as well as the type of the function.
makeTypedExprs :: HS.FuncDecl -> Converter ([(HS.Expr, HS.Type)], HS.Type)
makeTypedExprs (HS.FuncDecl _ (HS.DeclIdent srcSpan ident) args rhs) = do
  (args', rhs') <- renameArgs args rhs
  argTypeVars   <- replicateM (length args) freshTypeVar
  resTypeVar    <- freshTypeVar
  let funcName = HS.UnQual (HS.Ident ident)
      funcExpr = HS.Var srcSpan funcName
      funcType = HS.funcType NoSrcSpan argTypeVars resTypeVar
      argExprs = map HS.varPatToExpr args'
      typedExprs =
        (funcExpr, funcType) : (rhs', resTypeVar) : zip argExprs argTypeVars
  return (typedExprs, funcType)

-- If the given function has a type signature @f :: τ@ and 'makeTypedExprs'
-- added the expression type pair @f :: τ'@, the type equation @τ = τ'@ is
-- added without instantiating the type variables in the type signature with
-- fresh identifiers such that the inferred type uses the same type variable
-- names as specified by the user.
addTypeSigEquation :: HS.FuncDecl -> HS.Type -> TypedExprSimplifier ()
addTypeSigEquation funcDecl funcType = do
  let funcIdent = HS.fromDeclIdent (HS.getDeclIdent funcDecl)
      funcName  = HS.UnQual (HS.Ident funcIdent)
  maybeTypeSig <- lift $ inEnv $ lookupTypeSig funcName
  mapM_ (\(HS.TypeSchema _ _ typeSig) -> addTypeEquation typeSig funcType)
        maybeTypeSig

-- | Infers the types of type arguments to functions and constructors
--   used by the right-hand side of the given function declaration.
addTypeAppExprsToFuncDecls :: [HS.FuncDecl] -> Converter [HS.FuncDecl]
addTypeAppExprsToFuncDecls = fmap fst . addTypeAppExprsToFuncDecls'

-- | Like 'addTypeAppExprsToFuncDecls' but also returns the type of the
--   function declaration.
addTypeAppExprsToFuncDecls'
  :: [HS.FuncDecl] -> Converter ([HS.FuncDecl], [HS.TypeSchema])
addTypeAppExprsToFuncDecls' funcDecls = localEnv $ do
  funcDecls'       <- mapM addTypeAppVarsToFuncDecl funcDecls
  (typeExprs, mgu) <- inferFuncDeclTypes' funcDecls'
  funcDecls''      <- mapM (applySubst mgu) funcDecls'
  let typeArgs           = map typeVars typeExprs
      additionalTypeArgs = map typeVars funcDecls''
      allTypeArgs        = zipWith (nub .: (++)) additionalTypeArgs typeArgs
  (typeSchemas, substs) <-
    unzip <$> zipWithM abstractTypeSchema' allTypeArgs typeExprs
  funcDecls''' <- zipWithM applySubst substs funcDecls''
  return (funcDecls''', typeSchemas)

-------------------------------------------------------------------------------
-- Expressions                                                               --
-------------------------------------------------------------------------------

-- | Tries to infer the type of the given expression from the current context
--   and abstracts it's type to a type schema.
inferExprType :: HS.Expr -> Converter HS.TypeSchema
inferExprType = fmap snd . addTypeAppExprs'

-- | Like 'inferExprType' but does not abstract the type to a type schema and
--   also returns the substitution.
inferExprType' :: HS.Expr -> Converter (HS.Type, Subst HS.Type)
inferExprType' expr = localEnv $ do
  typeVar  <- freshTypeVar
  eqns     <- execTypedExprSimplifier $ simplifyTypedExpr expr typeVar
  mgu      <- unifyEquations eqns
  exprType <- applySubst mgu typeVar
  return (exprType, mgu)

-- | Infers the types of type arguments to functions and constructors
--   used by the given expression.
--
--   Returns an expression where the type arguments of functions and
--   constructors are applied explicitly.
addTypeAppExprs :: HS.Expr -> Converter HS.Expr
addTypeAppExprs = fmap fst . addTypeAppExprs'

-- | Like 'addTypeAppExprs' but also returns the type of the expression.
addTypeAppExprs' :: HS.Expr -> Converter (HS.Expr, HS.TypeSchema)
addTypeAppExprs' expr = localEnv $ do
  expr'           <- addTypeAppVars expr
  (typeExpr, mgu) <- inferExprType' expr'
  expr''          <- applySubst mgu expr'
  let typeArgs = nub (typeVars expr'' ++ typeVars typeExpr)
  (typeSchema, subst) <- abstractTypeSchema' typeArgs typeExpr
  expr'''             <- applySubst subst expr''
  return (expr''', typeSchema)

-------------------------------------------------------------------------------
-- Visible type application                                                  --
-------------------------------------------------------------------------------

-- | Add one visible type application node with a fresh type variable around
--   the given expression for each type argument of the function or constructor
--   with the given name.
addTypeAppVarsFor
  :: HS.QName -- ^ The name of the function or constructor.
  -> HS.Expr  -- ^ The variable or constructor expression.
  -> Converter HS.Expr
addTypeAppVarsFor name expr = do
  Just typeArgIdents <- inEnv $ lookupTypeArgs ValueScope name
  typeArgIdents'     <- mapM freshHaskellIdent typeArgIdents
  let srcSpan  = HS.getSrcSpan expr
      typeArgs = map (HS.TypeVar srcSpan) typeArgIdents'
  return (HS.visibleTypeApp srcSpan expr typeArgs)

-- | Applies the type arguments of each function and constructor invoked
--   by the given expression visibly using fresh type variables.
--
--   The fresh type variables are later replced by the actual type to
--   instantiate the type argument with using the substitution computed
--   during type inference.
addTypeAppVars :: HS.Expr -> Converter HS.Expr

-- Add visible type application to functions and constructors.
addTypeAppVars expr@(HS.Con _ conName) = do
  addTypeAppVarsFor conName expr
addTypeAppVars expr@(HS.Var _ varName) = ifM (inEnv $ isFunction varName)
                                             (addTypeAppVarsFor varName expr)
                                             (return expr)

-- Add visible type application to error terms.
addTypeAppVars expr@(HS.Undefined srcSpan) = do
  typeArgIdents <- freshTypeVar
  return (HS.TypeAppExpr srcSpan expr typeArgIdents)
addTypeAppVars expr@(HS.ErrorExpr srcSpan _) = do
  typeArgIdents <- freshTypeVar
  return (HS.TypeAppExpr srcSpan expr typeArgIdents)

-- Discard existing visible type applications.
addTypeAppVars (HS.TypeAppExpr _       expr _ ) = addTypeAppVars expr

-- Add visible type applications recursively.
addTypeAppVars (HS.App         srcSpan e1   e2) = do
  e1' <- addTypeAppVars e1
  e2' <- addTypeAppVars e2
  return (HS.App srcSpan e1' e2')
addTypeAppVars (HS.If srcSpan e1 e2 e3) = do
  e1' <- addTypeAppVars e1
  e2' <- addTypeAppVars e2
  e3' <- addTypeAppVars e3
  return (HS.If srcSpan e1' e2' e3')
addTypeAppVars (HS.Case srcSpan expr alts) = do
  expr' <- addTypeAppVars expr
  alts' <- mapM addTypeAppVarsToAlt alts
  return (HS.Case srcSpan expr' alts')
addTypeAppVars (HS.Lambda srcSpan varPats expr) = shadowVarPats varPats $ do
  expr' <- addTypeAppVars expr
  return (HS.Lambda srcSpan varPats expr')
addTypeAppVars (HS.ExprTypeSig srcSpan expr typeSchema) = do
  expr' <- addTypeAppVars expr
  return (HS.ExprTypeSig srcSpan expr' typeSchema)
addTypeAppVars expr@(HS.IntLiteral _ _) = return expr

-- | Applies 'addTypeAppVars' to the right-hand side of an alternative of  a
--   @case@-expression.
addTypeAppVarsToAlt :: HS.Alt -> Converter HS.Alt
addTypeAppVarsToAlt (HS.Alt srcSpan conPat varPats expr) =
  shadowVarPats varPats $ do
    expr' <- addTypeAppVars expr
    return (HS.Alt srcSpan conPat varPats expr')

-- | Applies 'addTypeAppVars' to the right-hand side of a function declaration.
addTypeAppVarsToFuncDecl :: HS.FuncDecl -> Converter HS.FuncDecl
addTypeAppVarsToFuncDecl (HS.FuncDecl srcSpan declIdent args rhs) =
  shadowVarPats args $ do
    rhs' <- addTypeAppVars rhs
    return (HS.FuncDecl srcSpan declIdent args rhs')

-------------------------------------------------------------------------------
-- Simplification of expression/type pairs                                   --
-------------------------------------------------------------------------------

-- | A pair of a variable name and it's type.
type TypedVar = (HS.VarName, HS.Type)

-- | A type equation.
type TypeEquation = (HS.Type, HS.Type)

-- | A writer monad that allows 'simplifyTypedExpr' to generate 'TypedVar's
--   and 'TypeEquation's implicitly.
type TypedExprSimplifier a = WriterT ([TypedVar], [TypeEquation]) Converter a

-- | Runs the given simplifier for expression/type pairs and returns the
--   yielded type equations (including type equations for variable/type pairs
--   with the same name, see 'makeTypeEquations') in addition to the
--   simplifiers result.
runTypedExprSimplifier :: TypedExprSimplifier a -> Converter (a, [TypeEquation])
runTypedExprSimplifier mx = do
  (x, (varTypes, eqns)) <- runWriterT mx
  let eqns' = makeTypeEquations varTypes ++ eqns
  return (x, eqns')

-- | Like 'runTypedExprSimplifier' but discards the result.
execTypedExprSimplifier :: TypedExprSimplifier a -> Converter [TypeEquation]
execTypedExprSimplifier = fmap snd . runTypedExprSimplifier

-- | Adds a 'TypedVar' entry to a 'TypedExprSimplifier'.
addVarType :: HS.QName -> HS.Type -> TypedExprSimplifier ()
addVarType v t = tell ([(v, t)], [])

-- | Adds a 'TypeEquation' entry to a 'TypedExprSimplifier'.
addTypeEquation :: HS.Type -> HS.Type -> TypedExprSimplifier ()
addTypeEquation t t' = tell ([], [(t, t')])

-- | Instantiates the type schema of the function or constructor with the
--   given name and adds a 'TypeEquation' for the resulting type and the
--   given type.
--
--   Returns the type variables the type schema of a predefined function
--   or constructor has been instantiated with. This is needed for the
--   implementation of visible type applications.
--
--   If there is no entry for the given name, a fatal error is reported.
--   The error message refers to the given source location information.
addTypeEquationFor
  :: SrcSpan -> HS.QName -> HS.Type -> TypedExprSimplifier [HS.Type]
addTypeEquationFor srcSpan name resType = do
  typeSchema           <- lift $ lookupTypeSchemaOrTypeSig srcSpan name
  (funcType, typeArgs) <- lift $ instantiateTypeSchema' typeSchema
  addTypeEquation funcType resType
  return typeArgs

-- | Looks up the type schema of a predefined function or constructor or
--   the type signature of a function.
lookupTypeSchemaOrTypeSig :: SrcSpan -> HS.QName -> Converter HS.TypeSchema
lookupTypeSchemaOrTypeSig srcSpan name = do
  maybeTypeSchema <- inEnv $ lookupTypeSchema ValueScope name
  maybeTypeSig    <- inEnv $ lookupTypeSig name
  case maybeTypeSchema <|> maybeTypeSig of
    Nothing ->
      reportFatal
        $  Message srcSpan Error
        $  "Identifier not in scope '"
        ++ showPretty name
        ++ "'"
    Just typeSchema -> return typeSchema

-- | Simplifies expression/type pairs to pairs of variables and types and
--   type equations.
--
--   Returns the type variables the type schema of a predefined function
--   or constructor has been instantiated with. This is needed for the
--   implementation of visible type applications.
simplifyTypedExpr :: HS.Expr -> HS.Type -> TypedExprSimplifier [HS.Type]

-- | If @C :: τ@ is a predefined constructor with @C :: forall α₀ … αₙ. τ'@,
--   then @τ = σ(τ')@ with @σ = { α₀ ↦ β₀, …, αₙ ↦ βₙ }@ where @β₀, …, βₙ@ are
--   new type variables.
simplifyTypedExpr (HS.Con srcSpan conName) resType =
  addTypeEquationFor srcSpan conName resType

-- | If @f :: τ@ is a predefined function with @f :: forall α₀ … αₙ. τ'@, then
--   @τ = σ(τ')@ with @σ = { α₀ ↦ β₀, …, αₙ ↦ βₙ }@ where @β₀, …, βₙ@ are new
--   type variables.
--   If @x :: τ@ is not a predefined function (i.e., a local variable or a
--   function whose type to infer), just remember that @x@ is of type @τ@.
simplifyTypedExpr (HS.Var srcSpan varName) resType = ifM
  (lift $ inEnv $ (isFunction varName .||. hasTypeSig varName))
  (addTypeEquationFor srcSpan varName resType)
  (addVarType varName resType >> return [])

-- If @(e₁ e₂) :: τ@, then @e₁ :: α -> τ@ and @e₂ :: α@ where @α@ is a new
-- type variable.
simplifyTypedExpr (HS.App _ e1 e2) resType = do
  argType <- lift freshTypeVar
  simplifyTypedExpr' e1 (HS.TypeFunc NoSrcSpan argType resType)
  simplifyTypedExpr' e2 argType
  return []

-- If @e \@τ :: τ'@ and @e@ is a predefined function or constructor of type
-- @forall α₀ … αₙ. κ@ that has been instantiated with
-- @σ = { α₀ ↦ β₀, …, αₙ ↦ βₙ }@ and the first @i@ type arguments of @e@ have
-- been applied visibly already, add the type equation @τ = βᵢ@.
simplifyTypedExpr (HS.TypeAppExpr srcSpan expr typeExpr) resType = do
  typeArgs <- simplifyTypedExpr expr resType
  case typeArgs of
    [] ->
      lift
        $  reportFatal
        $  Message srcSpan Error
        $  "Every visible type application must have a corresponding "
        ++ "type argument."
    (typeArg : typeArgs') -> do
      addTypeEquation typeArg typeExpr
      return typeArgs'

-- If @if e₁ then e₂ else e₃ :: τ@, then @e₁ :: Bool@ and @e₂, e₃ :: τ@.
simplifyTypedExpr (HS.If _ e1 e2 e3) resType = do
  let condType = HS.TypeCon NoSrcSpan HS.boolTypeConName
  simplifyTypedExpr' e1 condType
  simplifyTypedExpr' e2 resType
  simplifyTypedExpr' e3 resType
  return []

-- If @case e of {p₀ -> e₀; …; pₙ -> eₙ} :: τ@, then @e₀, …, eₙ :: τ@ and
-- @e :: α@ and @p₀, …, pₙ :: α@ where @α@ is a new type variable.
simplifyTypedExpr (HS.Case _ expr alts) resType = do
  exprType <- lift freshTypeVar
  simplifyTypedExpr' expr exprType
  mapM_ (\alt -> simplifyTypedAlt alt exprType resType) alts
  return []

-- Error terms are always typed correctly.
simplifyTypedExpr (HS.Undefined _   ) resType = return [resType]
simplifyTypedExpr (HS.ErrorExpr  _ _) resType = return [resType]

-- If @n :: τ@ for some integer literal @n@, then @τ = Integer@.
simplifyTypedExpr (HS.IntLiteral _ _) resType = do
  addTypeEquation resType (HS.TypeCon NoSrcSpan HS.integerTypeConName)
  return []

-- If @\x₀ … xₙ -> e :: τ@, then @x₀ :: α₀, … xₙ :: αₙ@ and @x :: β@ for new
-- type variables @α₀ … αₙ@ and @α₀ -> … -> αₙ -> β = τ@.
simplifyTypedExpr (HS.Lambda _ args expr) resType = do
  (args', expr') <- lift $ renameArgs args expr
  argTypes       <- replicateM (length args') (lift freshTypeVar)
  returnType     <- lift freshTypeVar
  zipWithM_ simplifyTypedExpr (map HS.varPatToExpr args') argTypes
  simplifyTypedExpr' expr' returnType
  let funcType = HS.funcType NoSrcSpan argTypes returnType
  addTypeEquation funcType resType
  return []

-- If @(e :: forall α₀, …, αₙ. τ) :: τ'@, then @e :: σ(τ)@ and @σ(τ) = τ'@
-- where @σ = { α₀ ↦ β₀, …, αₙ ↦ βₙ }@ maps the quantified type variables
-- of @τ@ to new type variables @β₀, …, βₙ@.
simplifyTypedExpr (HS.ExprTypeSig _ expr typeSchema) resType = do
  exprType <- lift $ instantiateTypeSchema typeSchema
  simplifyTypedExpr' expr exprType
  addTypeEquation exprType resType
  return []

-- | Applies 'simplifyTypedExpr' to the pattern and right-hand side of a
--   @case@-expression alternative.
simplifyTypedAlt
  :: HS.Alt  -- ^ The @case@-expression alternative.
  -> HS.Type -- ^ The type of the pattern.
  -> HS.Type -- ^ The type of the right-hand side.
  -> TypedExprSimplifier ()
simplifyTypedAlt (HS.Alt _ conPat varPats expr) patType exprType = do
  (varPats', expr') <- lift $ renameArgs varPats expr
  simplifyTypedPat conPat varPats' patType
  simplifyTypedExpr' expr' exprType

-- | Like 'simplifyTypedExpr' but reports an internal fatal error if not
--   all type arguments have been applied visibly.
simplifyTypedExpr' :: HS.Expr -> HS.Type -> TypedExprSimplifier ()
simplifyTypedExpr' expr typeExpr = do
  typeArgs <- simplifyTypedExpr expr typeExpr
  when (not (null typeArgs))
    $  lift
    $  reportFatal
    $  Message (HS.getSrcSpan expr) Internal
    $  "Every type argument must be applied visibly. Got "
    ++ show (length typeArgs)
    ++ " unapplied type arguments."

simplifyTypedPat
  :: HS.ConPat -> [HS.VarPat] -> HS.Type -> TypedExprSimplifier ()
simplifyTypedPat conPat varPats patType = do
  varPatTypes <- lift $ replicateM (length varPats) freshTypeVar
  let conExpr    = HS.conPatToExpr conPat
      varExprs   = map HS.varPatToExpr varPats
      conPatType = HS.funcType NoSrcSpan varPatTypes patType
  _ <- simplifyTypedExpr conExpr conPatType
  zipWithM_ simplifyTypedExpr varExprs varPatTypes
  return ()

-------------------------------------------------------------------------------
-- Solving type equations                                                    --
-------------------------------------------------------------------------------

-- | Converts @n@ 'TypedVar' entries for the same variable to @n-1@
--   type equations.
makeTypeEquations :: [TypedVar] -> [TypeEquation]
makeTypeEquations []                     = []
makeTypeEquations ((var, typeExpr) : ps) = case lookup var ps of
  Nothing        -> makeTypeEquations ps
  Just typeExpr' -> (typeExpr, typeExpr') : makeTypeEquations ps

-- | Finds the most general unificator that satisfies all given type equations.
unifyEquations :: [TypeEquation] -> Converter (Subst HS.Type)
unifyEquations = unifyEquations' identitySubst
 where
  unifyEquations'
    :: Subst HS.Type -> [TypeEquation] -> Converter (Subst HS.Type)
  unifyEquations' subst []                = return subst
  unifyEquations' subst ((t1, t2) : eqns) = do
    t1' <- applySubst subst t1
    t2' <- applySubst subst t2
    mgu <- unify t1' t2'
    let subst' = composeSubst mgu subst
    unifyEquations' subst' eqns

-------------------------------------------------------------------------------
-- Type schemas                                                              --
-------------------------------------------------------------------------------

-- | Replaces the type variables in the given type schema by fresh type
--   variables.
instantiateTypeSchema :: HS.TypeSchema -> Converter HS.Type
instantiateTypeSchema = fmap fst . instantiateTypeSchema'

-- | Like 'instantiateTypeSchema'' but also returns the fresh type variables,
--   the type schema has been instantiated with.
instantiateTypeSchema' :: HS.TypeSchema -> Converter (HS.Type, [HS.Type])
instantiateTypeSchema' (HS.TypeSchema _ typeArgs typeExpr) = do
  let typeArgIdents = map HS.fromDeclIdent typeArgs
  (typeArgIdents', subst) <- renameTypeArgsSubst typeArgIdents
  typeExpr'               <- applySubst subst typeExpr
  let typeArgs' = map (HS.TypeVar NoSrcSpan) typeArgIdents'
  return (typeExpr', typeArgs')

-- | Normalizes the names of type variables in the given type and returns
--   it as a type schema.
--
--   The first argument contains the names of type variables that should be
--   bound by the type schema. Usually these are the type variables that
--   occur in the given type (see 'typeVars').
--
--   Fresh type variables used by the given type are replaced by regular type
--   varibales with the prefix 'freshTypeArgPrefix'. All other type variables
--   are not renamed.
abstractTypeSchema :: [HS.QName] -> HS.Type -> Converter HS.TypeSchema
abstractTypeSchema = fmap fst .: abstractTypeSchema'

-- | Like 'abstractTypeSchema' but also returns the substitution that
--   was applied to replace the type variables.
abstractTypeSchema'
  :: [HS.QName] -> HS.Type -> Converter (HS.TypeSchema, Subst HS.Type)
abstractTypeSchema' ns t = do
  let vs         = map (fromJust . HS.identFromQName) ns
      (ivs, uvs) = partition HS.isInternalIdent vs
      vs'        = uvs ++ take (length ivs) (map makeTypeArg [0 ..] \\ uvs)
      ns'        = map (HS.UnQual . HS.Ident) (uvs ++ ivs)
      ts         = map (HS.TypeVar NoSrcSpan) vs'
      subst      = composeSubsts (zipWith singleSubst ns' ts)
  t' <- applySubst subst t
  return (HS.TypeSchema NoSrcSpan (map (HS.DeclIdent NoSrcSpan) vs') t', subst)
 where
  makeTypeArg :: Int -> HS.TypeVarIdent
  makeTypeArg = (freshTypeArgPrefix ++) . show
