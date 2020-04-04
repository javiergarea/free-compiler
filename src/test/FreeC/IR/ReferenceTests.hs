module FreeC.IR.ReferenceTests where

import           Test.Hspec

import           FreeC.IR.Reference
import qualified FreeC.IR.Syntax               as HS
import           FreeC.Test.Parser

-- | Test group for dependency extraction tests.
testReference :: Spec
testReference = describe "FreeC.IR.Reference" $ do
  testTypeVars

-- | Test group for 'freeTypeVars' tests.
testTypeVars :: Spec
testTypeVars = context "freeTypeVars" $ do
  it "should preserve the order of type arguments" $ do
    typeExpr <- expectParseTestType "C b ((c -> f) -> (e -> d)) a"
    freeTypeVars typeExpr
      `shouldBe` [ HS.UnQual (HS.Ident "b")
                 , HS.UnQual (HS.Ident "c")
                 , HS.UnQual (HS.Ident "f")
                 , HS.UnQual (HS.Ident "e")
                 , HS.UnQual (HS.Ident "d")
                 , HS.UnQual (HS.Ident "a")
                 ]
