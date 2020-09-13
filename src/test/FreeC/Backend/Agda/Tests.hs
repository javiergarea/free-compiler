-- | Test group for tests of modules below @FreeC.Backend.Agda@.
module FreeC.Backend.Agda.Tests ( testAgdaBackend ) where

import           Test.Hspec

import           FreeC.Backend.Agda.Converter.FuncDeclTests
import           FreeC.Backend.Agda.Converter.TypeDeclTests

-- | Test group for tests of modules below @FreeC.Backend.Agda@.
testAgdaBackend :: Spec
testAgdaBackend = do
  testConvertDataDecls
  testConvertFuncDecls