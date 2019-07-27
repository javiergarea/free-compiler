module Compiler.Converter.Inliner where

import           Data.Map.Strict                ( Map )
import qualified Data.Map.Strict               as Map

import           Compiler.Converter.Fresh
import           Compiler.Converter.State
import           Compiler.Converter.Subst
import qualified Compiler.Language.Haskell.SimpleAST
                                               as HS
import           Compiler.SrcSpan

-- | Inlines the right hand sides of the given function declarations into
--   the right hand sides of other function declarations.
inlineDecl :: [HS.Decl] -> HS.Decl -> Converter HS.Decl
inlineDecl decls (HS.FuncDecl srcSpan declIdent args expr) = do
  expr' <- inlineExpr decls expr
  return (HS.FuncDecl srcSpan declIdent args expr')
inlineDecl _ decl = return decl

-- | Inlines the right hand sides of the given function declarations into an
--   expression.
inlineExpr :: [HS.Decl] -> HS.Expr -> Converter HS.Expr
inlineExpr decls = inlineAndBind
 where
   -- | Maps the names of function declarations in 'decls' to the argument
   --   identifiers and right hand sides.
  declMap :: Map HS.Name ([String], HS.Expr)
  declMap = foldr insertFuncDecl Map.empty decls

   -- | Inserts a function declaration into 'declMap'.
  insertFuncDecl
    :: HS.Decl                          -- ^ The declaration to insert.
    -> Map HS.Name ([String], HS.Expr) -- ^ The map to insert into.
    -> Map HS.Name ([String], HS.Expr)
  insertFuncDecl (HS.FuncDecl _ (HS.DeclIdent _ ident) args expr) =
    Map.insert (HS.Ident ident) (map HS.fromVarPat args, expr)
  insertFuncDecl _ = id

  -- | Applies 'inlineExpr'' on the given expression and wraps the result with
  --   lambda abstractions for the remaining arguments.
  inlineAndBind :: HS.Expr -> Converter HS.Expr
  inlineAndBind expr = do
    (remainingArgIdents, expr') <- inlineExpr' expr
    if null remainingArgIdents
      then return expr'
      else do
        let remainingArgPats = map (HS.VarPat NoSrcSpan) remainingArgIdents
        return (HS.Lambda NoSrcSpan remainingArgPats expr')

  -- | Performs inlining on the given subexpression.
  --
  --   If a function is inlined, fresh free variables are introduced for the
  --   function arguments. The first component of the returned pair contains
  --   the names of the variables that still need to be bound. Function
  --   application expressions automatically substitute the corresponding
  --   argument for the passed value.
  inlineExpr' :: HS.Expr -> Converter ([String], HS.Expr)
  inlineExpr' var@(HS.Var _ name) = case Map.lookup name declMap of
    Nothing               -> return ([], var)
    Just (argIdents, rhs) -> do
      argIdents' <- mapM freshHaskellIdent argIdents
      let argNames = map HS.Ident argIdents
          argVars' = map (flip HS.Var . HS.Ident) argIdents'
          subst    = composeSubsts (zipWith singleSubst' argNames argVars')
      rhs' <- applySubst subst rhs
      return (argIdents', rhs')

  -- Substitute argument of inlined function and inline recursively in
  -- function arguments.
  inlineExpr' (HS.App srcSpan e1 e2) = do
    (remainingArgs, e1') <- inlineExpr' e1
    e2'                  <- inlineAndBind e2
    case remainingArgs of
      []                     -> return ([], HS.App srcSpan e1' e2')
      (arg : remainingArgs') -> do
        let subst = singleSubst (HS.Ident arg) e2'
        e1'' <- applySubst subst e1'
        return (remainingArgs', e1'')

  -- Inline recursively.
  inlineExpr' (HS.If srcSpan e1 e2 e3) = do
    e1' <- inlineAndBind e1
    e2' <- inlineAndBind e2
    e3' <- inlineAndBind e3
    return ([], HS.If srcSpan e1' e2' e3')
  inlineExpr' (HS.Case srcSpan expr alts) = do
    expr' <- inlineAndBind expr
    alts' <- mapM inlineAlt alts
    return ([], HS.Case srcSpan expr' alts')
  inlineExpr' (HS.Lambda srcSpan args expr) = do
    expr' <- inlineAndBind expr
    return ([], HS.Lambda srcSpan args expr')

  -- All other expressions remain unchanged.
  inlineExpr' expr@(HS.Con _ _       ) = return ([], expr)
  inlineExpr' expr@(HS.Undefined _   ) = return ([], expr)
  inlineExpr' expr@(HS.ErrorExpr  _ _) = return ([], expr)
  inlineExpr' expr@(HS.IntLiteral _ _) = return ([], expr)

  inlineAlt :: HS.Alt -> Converter HS.Alt
  inlineAlt (HS.Alt srcSpan conPat varPats expr) = do
    expr' <- inlineAndBind expr
    return (HS.Alt srcSpan conPat varPats expr')
