-- | This module contains the compiler pipeline for the translation of the
--   intermediate representation that is generated by the front end into
--   a format that is accepted by the back end.
--
--   The compiler pipeline is organized into 'CompilerPass'es. Each pass
--   performs some transformation on the converted module.

module Compiler.Pipeline where

import           Compiler.Pass
import           Compiler.Pass.DefineDeclPass
import           Compiler.Pass.DependencyAnalysisPass
import           Compiler.Pass.EtaConversionPass
import           Compiler.Pass.ExportPass
import           Compiler.Pass.ImplicitPreludePass
import           Compiler.Pass.ImportPass
import           Compiler.Pass.TypeSignaturePass
import           Compiler.Pass.TypeInferencePass
import           Compiler.Pass.QualifierPass
import           Compiler.Pass.ResolverPass
import qualified Compiler.IR.Syntax            as HS
import           Compiler.Monad.Converter

-- | The passes of the compiler pipeline.
pipeline :: [Pass HS.Module]
pipeline =
  [ implicitPreludePass
  , qualifierPass
  , resolverPass
  , importPass
  , dependencyAnalysisPass [defineTypeDeclsPass]
  , typeSignaturePass
  , dependencyAnalysisPass [typeInferencePass, defineFuncDeclsPass]
  , etaConversionPass
  , exportPass
  ]

-- | Runs the compiler pipeline on the given module.
runPipeline :: HS.Module -> Converter HS.Module
runPipeline = runPasses pipeline
