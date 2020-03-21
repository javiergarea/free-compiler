-- | This module contains the compiler pipeline for the translation of the
--   intermediate representation that is generated by the front end into
--   a format that is accepted by the back end.
--
--   The compiler pipeline is organized into 'CompilerPass'es. Each pass
--   performs some transformation on the converted module.

module Compiler.Pipeline where

import           Control.Monad                  ( (>=>) )

import           Compiler.Pass.ImportPass
import           Compiler.Pass.TypeSignaturePass
import           Compiler.Pass.TypeInferencePass
import qualified Compiler.Haskell.AST          as HS
import           Compiler.Monad.Converter

-- | A single pass of the compiler pipeline.
type CompilerPass = HS.Module -> Converter HS.Module

-- | The passes of the compiler pipeline.
pipeline :: [CompilerPass]
pipeline = [importPass, typeSignaturePass, typeInferencePass]

-- | Runs the compiler pipeline on the given module.
runPipeline :: HS.Module -> Converter HS.Module
runPipeline = foldr (>=>) return pipeline
