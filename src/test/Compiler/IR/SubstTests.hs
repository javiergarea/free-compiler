module Compiler.IR.SubstTests where

import           Test.Hspec

import qualified Compiler.IR.Syntax            as HS
import           Compiler.IR.Subst
import           Compiler.Util.Test

-- | Test group for the "Compiler.Hsakell.Subst.ApplySubst" instance for
--   expressions.
testExprSubst :: Spec
testExprSubst = do
  describe "Compiler.IR.Subst.composeSubst" $ do
    it "applies the second substitution first"
      $ shouldSucceed
      $ fromConverter
      $ do
          y <- parseTestExpr "y"
          z <- parseTestExpr "z"
          e <- parseTestExpr "x y z"
          let s1    = singleSubst (HS.UnQual (HS.Ident "x")) z
              s2    = singleSubst (HS.UnQual (HS.Ident "x")) y
              subst = s1 `composeSubst` s2
              e'    = applySubst subst e
          return (e' `prettyShouldBe` "y y z")
    it "applies the second substitution to the first"
      $ shouldSucceed
      $ fromConverter
      $ do
          y <- parseTestExpr "y"
          z <- parseTestExpr "z"
          e <- parseTestExpr "x y z"
          let s1    = singleSubst (HS.UnQual (HS.Ident "y")) z
              s2    = singleSubst (HS.UnQual (HS.Ident "x")) y
              subst = s1 `composeSubst` s2
              e'    = applySubst subst e
          return (e' `prettyShouldBe` "z z z")
  describe "Compiler.IR.Subst.applySubst" $ do
    it "cannot substitute variables bound by lambda"
      $ shouldSucceed
      $ fromConverter
      $ do
          val <- parseTestExpr "42"
          e   <- parseTestExpr "(\\x -> x) x"
          let subst = singleSubst (HS.UnQual (HS.Ident "x")) val
              e'    = applySubst subst e
          return (e' `prettyShouldBe` "(\\x -> x) 42")
    it "cannot substitute variables bound by a case alternative"
      $ shouldSucceed
      $ fromConverter
      $ do
          val <- parseTestExpr "(42, True)"
          e   <- parseTestExpr "case x of { (x, y) -> x }"
          let subst = singleSubst (HS.UnQual (HS.Ident "x")) val
              e'    = applySubst subst e
          return
            (                e'
            `prettyShouldBe` (  "case Prelude.(,) 42 True of {"
                             ++ "   Prelude.(,) x y -> x"
                             ++ " }"
                             )
            )
