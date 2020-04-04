module FreeC.Pass.PartialityAnalysisPassTests where

import           Test.Hspec

import           FreeC.Environment
import qualified FreeC.IR.Syntax               as HS
import           FreeC.Monad.Converter

import           FreeC.Util.Test

-- | Test group for 'partialityAnalysisPass' tests.
testPartialityAnalysisPass :: Spec
testPartialityAnalysisPass =
  describe "FreeC.Pass.PartialityAnalysisPassTests" $ do
    it "recognizes directly partial functions using 'undefined'"
      $ shouldSucceed
      $ fromConverter
      $ do
          _ <- convertTestDecls
            [ "head :: [a] -> a"
            , "head xs = case xs of { [] -> undefined; x : xs' -> x }"
            ]
          partial <- inEnv $ isPartial (HS.Qual "Main" (HS.Ident "head"))
          return (partial `shouldBe` True)

    it "recognizes directly partial functions using 'error'"
      $ shouldSucceed
      $ fromConverter
      $ do
          _ <- convertTestDecls
            [ "head :: [a] -> a"
            , "head xs = case xs of {"
            ++ "  []      -> error \"head: empty list\";"
            ++ "  x : xs' -> x"
            ++ "}"
            ]
          partial <- inEnv $ isPartial (HS.Qual "Main" (HS.Ident "head"))
          return (partial `shouldBe` True)

    it "recognizes indirectly partial functions"
      $ shouldSucceed
      $ fromConverter
      $ do
          _       <- defineTestFunc "map" 2 "(a -> b) -> [a] -> [b]"
          _       <- definePartialTestFunc "head" 1 "[a] -> a"
          _ <- convertTestDecls ["heads :: [[a]] -> [a]", "heads = map head"]
          partial <- inEnv $ isPartial (HS.Qual "Main" (HS.Ident "heads"))
          return (partial `shouldBe` True)

    it "recognizes mutually recursive partial functions"
      $ shouldSucceed
      $ fromConverter
      $ do
          _ <- defineTestFunc "map" 2 "(a -> b) -> [a] -> [b]"
          _ <- definePartialTestFunc "head" 1 "[a] -> a"
          _ <- convertTestDecls
            [ "pairs :: [a] -> [(a, a)]"
            , "pairs xys = case xys of {"
            ++ "    []     -> [];"
            ++ "    x : ys -> pairs' x ys"
            ++ "  }"
            , "pairs' :: a -> [a] -> [(a, a)]"
            , "pairs' x yxs = case yxs of {"
            ++ "    []     -> undefined;"
            ++ "    y : xs -> (x, y) : pairs xs"
            ++ "  }"
            ]
          partial <- inEnv $ isPartial (HS.Qual "Main" (HS.Ident "pairs"))
          return (partial `shouldBe` True)