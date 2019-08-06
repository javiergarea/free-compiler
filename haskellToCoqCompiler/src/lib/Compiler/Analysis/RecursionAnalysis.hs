-- | This module contains functions for analysising recursive function, e.g. to
--   finding the decreasing argument of a recursive function.

module Compiler.Analysis.RecursionAnalysis where

import           Data.List                      ( nub
                                                , find
                                                )
import           Data.Map.Strict                ( Map )
import qualified Data.Map.Strict               as Map
import           Data.Maybe                     ( catMaybes
                                                , maybe
                                                )
import           Data.Set                       ( Set
                                                , (\\)
                                                )
import qualified Data.Set                      as Set

import qualified Compiler.Haskell.AST          as HS
import           Compiler.Monad.Converter
import           Compiler.Monad.Reporter

-- | Type for the index of a decreasing argument.
type DecArgIndex = Int

-- | Guesses all possible combinations of decreasing arguments for the given
--   mutually recursive function declarations.
--
--   Returns a list of all possible combinations of argument indecies.
guessDecArgs :: [HS.Decl] -> [[DecArgIndex]]
guessDecArgs []                               = return []
guessDecArgs (HS.FuncDecl _ _ args _ : decls) = do
  decArgIndecies <- guessDecArgs decls
  decArgIndex    <- [0 .. length args - 1]
  return (decArgIndex : decArgIndecies)

-- | Tests whether the given combination of choices for the decreasing
--   arguments of function declarations in a strongly connected component
--   is valid (i.e. all function declarations actually decrease the
--   corresponding argument)
checkDecArgs :: [HS.Decl] -> [DecArgIndex] -> Bool
checkDecArgs decls decArgIndecies = all (uncurry checkDecArg)
                                        (zip decArgIndecies decls)
 where
  -- | Maps the names of functions in the strongly connected component
  --   to the index of their decreasing argument.
  decArgMap :: Map HS.Name DecArgIndex
  decArgMap =
    foldr (uncurry insertFuncDecl) Map.empty (zip decls decArgIndecies)

  -- | Inserts a function declaration with the given decreasing argument index
  --   into 'decArgMap'.
  insertFuncDecl
    :: HS.Decl
    -> DecArgIndex
    -> Map HS.Name DecArgIndex
    -> Map HS.Name DecArgIndex
  insertFuncDecl (HS.FuncDecl _ (HS.DeclIdent _ ident) _ _) decArg =
    Map.insert (HS.Ident ident) decArg

  -- | Tests whether the given function declaration actually decreases on the
  --   argument with the given index.
  checkDecArg :: DecArgIndex -> HS.Decl -> Bool
  checkDecArg decArgIndex (HS.FuncDecl _ _ args expr) =
    let decArg = HS.Ident (HS.fromVarPat (args !! decArgIndex))
    in  checkExpr decArg Set.empty expr []

  -- | Tests whether there is a variable that is structurally smaller than the
  --   argument with the given name in the position of decreasing arguments of
  --   all applications of functions from the strongly connected component.
  --
  --   The second argument is a set of variables that are known to be
  --   structurally smaller than the decreasing argument of the function
  --   whose right hand side is checked.
  --
  --   The last argument is a list of actual arguments passed to the given
  --   expression.
  checkExpr :: HS.Name -> Set HS.Name -> HS.Expr -> [HS.Expr] -> Bool
  checkExpr decArg smaller = checkExpr'
   where
    checkExpr' (HS.Var _ name) args = case Map.lookup name decArgMap of
      Nothing -> True
      Just decArgIndex
        | decArgIndex >= length args -> False
        | otherwise -> case args !! decArgIndex of
          (HS.Var _ argName) -> argName `elem` smaller
          _                  -> False

    checkExpr' (HS.App _ e1 e2) args =
      checkExpr' e1 (e2 : args) && checkExpr' e2 []

    checkExpr' (HS.If _ e1 e2 e3) _ =
      checkExpr' e1 [] && checkExpr' e2 [] && checkExpr' e3 []

    checkExpr' (HS.Case _ expr alts) _ = case expr of
      (HS.Var _ varName) | varName == decArg || varName `Set.member` smaller ->
        all checkSmallerAlt alts
      _ -> all checkAlt alts

    checkExpr' (HS.Lambda _ args expr) _ =
      let smaller' = withoutArgs args smaller
      in  checkExpr decArg smaller' expr []

    checkExpr' (HS.Con _ _       ) _ = True
    checkExpr' (HS.Undefined _   ) _ = True
    checkExpr' (HS.ErrorExpr  _ _) _ = True
    checkExpr' (HS.IntLiteral _ _) _ = True

    checkAlt :: HS.Alt -> Bool
    checkAlt (HS.Alt _ _ varPats expr) =
      let smaller' = withoutArgs varPats smaller
      in  checkExpr decArg smaller' expr []

    checkSmallerAlt :: HS.Alt -> Bool
    checkSmallerAlt (HS.Alt _ _ args expr) =
      let smaller' = withArgs args smaller in checkExpr decArg smaller' expr []

    -- | Adds the given variables to the set of structurally smaller variables.
    withArgs :: [HS.VarPat] -> Set HS.Name -> Set HS.Name
    withArgs args set =
      set `Set.union` Set.fromList (map (HS.Ident . HS.fromVarPat) args)

    -- | Removes the given variables to the set of structurally smaller
    --   variables (because they are shadowed by an argument from a lambda
    --   abstraction or @case@-alternative).
    withoutArgs :: [HS.VarPat] -> Set HS.Name -> Set HS.Name
    withoutArgs args set =
      set \\ Set.fromList (map (HS.Ident . HS.fromVarPat) args)

-- | Identifies the decreasing arguments of the given mutually recursive
--   function declarations.
--
--   Returns @Nothing@ if the decreasing argument could not be identified.
maybeIdentifyDecArgs :: [HS.Decl] -> Maybe [Int]
maybeIdentifyDecArgs decls = find (checkDecArgs decls) (guessDecArgs decls)

-- | Identifies the decreasing arguments of the given mutually recursive
--   function declarations.
--
--   Reports a fatal error message, if the decreasing arguments could not be
--   identified.
identifyDecArgs :: [HS.Decl] -> Converter [Int]
identifyDecArgs decls = maybe decArgError return (maybeIdentifyDecArgs decls)
 where
  decArgError :: Converter a
  decArgError =
    reportFatal
      $  Message (HS.getSrcSpan (head decls)) Error
      $  "Could not identify decreasing arguments of "
      ++ HS.prettyDeclIdents decls

-- | Identifies the decreasing argument of a function with the given right
--   hand side.
--
--   Returns the name of the decreasing argument, the @case@ expressions that
--   match the decreasing argument and a function that replaces the @case@
--   expressions by other expressions.
--
--   TODO verify that all functions in the SCC are decreasing on this argument.
identifyDecArg
  :: HS.Expr
  -> Converter (HS.Name, [([HS.VarPat], HS.Expr)], [HS.Expr] -> HS.Expr)
identifyDecArg rootExpr = do
  case identifyDecArg' rootExpr of
    (Nothing, _, _) ->
      reportFatal
        $ Message (HS.getSrcSpan rootExpr) Error
        $ "Cannot identify decreasing argument."
    (Just decArg, caseExprs, replaceCases) ->
      return (decArg, caseExprs, replaceCases)
 where
  -- | Recursively identifies the decreasing argument (variable matched by the
  --   outermost-case expression).
  identifyDecArg'
    :: HS.Expr
    -> (Maybe HS.Name, [([HS.VarPat], HS.Expr)], [HS.Expr] -> HS.Expr)
  identifyDecArg' expr@(HS.Case _ (HS.Var _ decArg) _) =
    (Just decArg, [([], expr)], \[expr'] -> expr')
  identifyDecArg' (HS.App srcSpan e1 e2) =
    let (decArg1, cases1, replace1) = identifyDecArg' e1
        (decArg2, cases2, replace2) = identifyDecArg' e2
    in  ( uniqueDecArg [decArg1, decArg2]
        , cases1 ++ cases2
        , \exprs ->
          let e1' = replace1 (take (length cases1) exprs)
              e2' = replace2 (drop (length cases1) exprs)
          in  HS.App srcSpan e1' e2'
        )
  identifyDecArg' (HS.If srcSpan e1 e2 e3) =
    let (decArg1, cases1, replace1) = identifyDecArg' e1
        (decArg2, cases2, replace2) = identifyDecArg' e2
        (decArg3, cases3, replace3) = identifyDecArg' e3
    in  ( uniqueDecArg [decArg1, decArg2, decArg3]
        , cases1 ++ cases2 ++ cases3
        , \exprs ->
          let e1' = replace1 (take (length cases1) exprs)
              e2' =
                replace2 (take (length cases2) (drop (length cases1) exprs))
              e3' = replace3 (drop (length cases1 + length cases2) exprs)
          in  HS.If srcSpan e1' e2' e3'
        )
  identifyDecArg' (HS.Lambda srcSpan args expr) =
    let (decArg, cases, replace) = identifyDecArg' expr
    in  ( decArg
        , map (\(usedVars, caseExpr) -> (args ++ usedVars, caseExpr)) cases
        , \exprs -> let expr' = replace exprs in HS.Lambda srcSpan args expr'
        )
  identifyDecArg' expr = (Nothing, [], const expr)

  -- | Ensures that all the names of the given list are identical (except for
  --   @Nothing@) and then returns that unique name.
  --
  --   Returns @Nothing@ if there is no such unique name (i.e. because the list
  --   is empty or because there are different names).
  uniqueDecArg :: [Maybe HS.Name] -> Maybe HS.Name
  uniqueDecArg decArgs = case nub (catMaybes decArgs) of
    []       -> Nothing
    [decArg] -> Just decArg
    _        -> Nothing
