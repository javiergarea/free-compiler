-- | This module contains the compiler pipeline for the translation of the
--   intermediate representation that is generated by the front end into
--   a format that is accepted by the back end.
--
--   The compiler pipeline is organized into compiler 'Pass'es. Each pass
--   performs some transformation on the converted module.
module FreeC.Pipeline where

import           Control.Monad                     ( (>=>) )

import qualified FreeC.IR.Syntax                   as IR
import           FreeC.Monad.Converter
import           FreeC.Pass
import           FreeC.Pass.CompletePatternPass
import           FreeC.Pass.DefineDeclPass
import           FreeC.Pass.DependencyAnalysisPass
import           FreeC.Pass.EffectAnalysisPass
import           FreeC.Pass.EtaConversionPass
import           FreeC.Pass.ExportPass
import           FreeC.Pass.FlattenExprPass --TODO uncomment me
import           FreeC.Pass.ImplicitPreludePass
import           FreeC.Pass.ImportPass
import           FreeC.Pass.KindCheckPass
import           FreeC.Pass.LetSortPass
import           FreeC.Pass.PragmaPass
import           FreeC.Pass.QualifierPass
import           FreeC.Pass.ResolverPass
import           FreeC.Pass.SharingAnalysisPass
import           FreeC.Pass.TypeInferencePass
import           FreeC.Pass.TypeSignaturePass

-- | The passes of the compiler pipeline.
pipeline :: Pass IR.Module IR.Module
pipeline = implicitPreludePass
  >=> qualifierPass
  >=> resolverPass
  >=> importPass
  >=> dependencyAnalysisPass defineTypeDeclsPass
  >=> kindCheckPass
  >=> letSortPass
  >=> typeSignaturePass
  >=> pragmaPass
  >=> sharingAnaylsisPass
  >=> flattenExprPass --TODO uncomment me
  >=> dependencyAnalysisPass
  (typeInferencePass >=> defineFuncDeclsPass >=> effectAnalysisPass)
  >=> completePatternPass
  >=> etaConversionPass
  >=> exportPass

-- | Runs the compiler pipeline on the given module.
runPipeline :: IR.Module -> Converter IR.Module
runPipeline = runPass pipeline
