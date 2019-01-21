module Compiler.MonadicConverter where

import Language.Coq.Gallina as G
import Language.Coq.Util (qualidIsOp)

import Compiler.Types (ConversionMonad(..) )
import Compiler.NonEmptyList (singleton, fromNonEmptyList, toNonemptyList)
import Compiler.HelperFunctions (getQIdsFromPattern, getBinderName, getBinderType, getBinderByQId
      ,getPatternFromMultPattern ,gNameToQId, termToQId ,strToQId, strToGName, typeTerm, eqQId
      ,getTypeSignatureByQId, getStringFromGName, getTermFromMatchItem, eqGName, qIdEqBinder, qIdToGName)

import qualified Data.Text as T
import qualified GHC.Base as B
import Data.Maybe (isJust, fromJust)
import Data.List (elemIndex)

---------------------- Add Bind Operator to Definition
addBindOperatorsToDefinition :: [G.Binder] -> G.Term -> G.Term
addBindOperatorsToDefinition [] term =
  term
addBindOperatorsToDefinition (x : xs) term =
  G.App bindOperator
    (toNonemptyList [G.PosArg argumentName, G.PosArg lambdaFun])
  where
    argumentName = getBinderName x
    lambdaFun = G.Fun (singleton (removeMonadFromBinder x)) (addBindOperatorsToDefinition xs term )

---------------------- Add Return Operator if rhs isn't already monadic
addReturnToRhs :: G.Term -> [G.TypeSignature] -> [G.Binder] -> [(G.Name, Int)]-> G.Term
addReturnToRhs (G.Match mItem retType equations) typeSigs binders dataTypes=
  addReturnToMatch (G.Match mItem retType equations) typeSigs binders dataTypes []
addReturnToRhs rhs typeSigs binders _ =
  addReturnToTerm rhs typeSigs binders []

addReturnToMatch :: G.Term -> [G.TypeSignature] -> [G.Binder] -> [(G.Name, Int)] -> [G.Qualid] -> G.Term
addReturnToMatch (G.Match mItem retType equations) typeSigs binders dataTypes patNames =
  if (not . null) matchedBinder &&
        isJust (elemIndex dataName dataNames) &&
          length monadicEquations /= constrNumber
  then G.Match mItem retType (monadicEquations ++ errorEquation)
  else G.Match mItem retType monadicEquations
  where
    monadicEquations = [addReturnToEquation e typeSigs binders patNames | e <- equations]
    dataNames = map fst dataTypes
    constrNumbers = map snd dataTypes
    nonMonadicBinders = map removeMonadFromBinder binders
    matchedQId = (termToQId . getTermFromMatchItem . head . fromNonEmptyList) mItem
    matchedBinder = filter (qIdEqBinder matchedQId)  nonMonadicBinders
    dataName = (qIdToGName . termToQId . getBinderType . head) matchedBinder
    constrNumber = constrNumbers !! fromJust (elemIndex dataName dataNames)

addReturnToEquation :: G.Equation -> [G.TypeSignature] -> [G.Binder] -> [G.Qualid] -> G.Equation
addReturnToEquation (G.Equation multPats rhs) typeSigs binders prevPatNames =
  G.Equation multPats (addReturnToTerm rhs typeSigs binders patNames)
  where
    pats = concatMap getPatternFromMultPattern (fromNonEmptyList multPats)
    patNames = prevPatNames ++ concatMap getQIdsFromPattern pats

addReturnToTerm :: G.Term -> [G.TypeSignature] -> [G.Binder] -> [G.Qualid] -> G.Term
addReturnToTerm (G.App constr args) typeSigs binders patNames
  | isMonadicTerm constr || isMonadicFunctionCall constr typeSigs || isMonadicBinder constr binders =
      G.App constr fixedArgs
  | qualidIsOp (termToQId constr) =
      toReturnTerm (G.App constr args)
  | otherwise =
      toReturnTerm (G.App constr fixedArgs)
  where
    fixedArgs = toNonemptyList (addReturnToArgs (fromNonEmptyList args) typeSigs binders patNames)
addReturnToTerm (G.Parens term) typeSigs binders patNames =
  G.Parens (addReturnToTerm term typeSigs binders patNames)
addReturnToTerm (G.Fun fBinders term) _ _ _ =
  G.Fun fBinders term
addReturnToTerm term typeSigs binders patNames =
  if isMonadicTerm term || isMonadicFunctionCall term typeSigs
      || isMonadicBinder term binders || isPatName term patNames
      || isFuelArg term
    then term
    else toReturnTerm term

addReturnToArgs :: [G.Arg] -> [G.TypeSignature] -> [G.Binder] -> [G.Qualid] -> [G.Arg]
addReturnToArgs (x : xs) typeSigs binders patNames =
  addReturnToArg x typeSigs binders patNames : addReturnToArgs xs typeSigs binders patNames
addReturnToArgs [] _ _ _ =
  []

addReturnToArg :: G.Arg -> [G.TypeSignature] -> [G.Binder] -> [G.Qualid] -> G.Arg
addReturnToArg (G.PosArg term) typeSigs binders patNames =
  G.PosArg (addReturnToTerm term typeSigs binders patNames)

---------------------- transform Data Structures Monadic
transformBindersMonadic :: [G.Binder] -> ConversionMonad -> [G.Binder]
transformBindersMonadic binders m =
  [transformBinderMonadic (addMonadicPrefixToBinder m b) m | b <- binders]

transformBinderMonadic :: G.Binder -> ConversionMonad -> G.Binder
transformBinderMonadic (G.Typed gen expl name term) m =
  G.Typed gen expl name (transformTermMonadic term m)

transformTermMonadic :: G.Term -> ConversionMonad -> G.Term
transformTermMonadic (G.Sort G.Type) m =
  typeTerm
transformTermMonadic term m =
  monad term
  where
    monad = case m of
          Option -> toOptionTerm
          Identity -> toIdentityTerm

-- Convert Terms Monadic
toOptionTerm :: G.Term -> G.Term
toOptionTerm term =
  G.App optionTerm (singleton (G.PosArg term))

toIdentityTerm :: G.Term -> G.Term
toIdentityTerm term =
  G.App identityTerm (singleton (G.PosArg term))

toReturnTerm :: G.Term -> G.Term
toReturnTerm term =
  G.App returnTerm (singleton (G.PosArg term))

---------------------- Add Monadic Prefixes

addMonadicPrefix :: String -> G.Name -> G.Name
addMonadicPrefix str (G.Ident (G.Bare ident)) =
  G.Ident (strToQId (str ++ name))
  where
    name = T.unpack ident

addMonadicPrefixToBinder ::  ConversionMonad -> G.Binder -> G.Binder
addMonadicPrefixToBinder m (G.Inferred expl name) =
  G.Inferred expl (getPrefixFromMonad m name)
addMonadicPrefixToBinder m (G.Typed gen expl (name B.:| xs) ty) =
  G.Typed gen expl (singleton (getPrefixFromMonad m name)) ty

addMonadicPrefixToQId ::  ConversionMonad -> G.Qualid -> G.Qualid
addMonadicPrefixToQId m qId =
  gNameToQId (getPrefixFromMonad m (G.Ident qId))


getPrefixFromMonad :: ConversionMonad -> (G.Name -> G.Name)
getPrefixFromMonad Option = addOptionPrefix
getPrefixFromMonad Identity = addIdentityPrefix

-- Monadic Prefixes used
addOptionPrefix :: G.Name -> G.Name
addOptionPrefix =
  addMonadicPrefix "o"

addIdentityPrefix :: G.Name -> G.Name
addIdentityPrefix =
  addMonadicPrefix "i"

  ---------------------- Remove Monadic Elements

removeMonadFromBinder :: G.Binder -> G.Binder
removeMonadFromBinder (G.Typed gen expl (n B.:| xs) term) =
  G.Typed gen expl (singleton (removeMonadicPrefix n)) (fromMonadicTerm term)

removeMonadicPrefix :: G.Name -> G.Name
removeMonadicPrefix name =
  strToGName (tail (getStringFromGName name))

fromMonadicTerm :: G.Term -> G.Term
fromMonadicTerm (G.App _ (G.PosArg term B.:| xs)) =
  term
fromMonadicTerm term =
  term
---------------------- Bool Functions
isFuelArg :: G.Term -> Bool
isFuelArg (G.Qualid qId) =
  any (eqQId qId) (map strToQId ["rFuel", "fuel"])

isPatName :: G.Term -> [G.Qualid] -> Bool
isPatName (G.Qualid qId) =
  any (eqQId qId)

isMonadicTerm :: G.Term -> Bool
isMonadicTerm (G.App term _ ) =
  isMonad term
isMonadicTerm term =
  False

isMonad :: G.Term -> Bool
isMonad (G.Qualid qId) =
  any (eqQId qId) (map strToQId ["option", "identity", "return_"])

predefinedMonadicFunctions :: [G.Qualid]
predefinedMonadicFunctions =
  map strToQId ["singleton"]

isMonadicFunctionCall :: G.Term -> [G.TypeSignature] -> Bool
isMonadicFunctionCall (G.Qualid qId) typeSigs =
  isJust maybeTypeSig || any (eqQId qId) predefinedMonadicFunctions || eqQId qId (termToQId bindOperator)
  where maybeTypeSig = getTypeSignatureByQId typeSigs qId
isMonadicFunctionCall term _ =
  False

isMonadicBinder :: G.Term -> [G.Binder] -> Bool
isMonadicBinder (G.Qualid qId) binders =
  isJust maybeBinder && isMonadicTerm (getBinderType (fromJust maybeBinder))
  where maybeBinder = getBinderByQId binders qId

errorEquation :: [G.Equation]
errorEquation =
  [G.Equation (singleton (G.MultPattern (singleton G.UnderscorePat))) (G.Qualid (strToQId "None"))]
---------------------- Predefined Terms
identityTerm :: G.Term
identityTerm =
  G.Qualid (strToQId "identity")

optionTerm :: G.Term
optionTerm =
  G.Qualid (strToQId "option")

returnTerm :: G.Term
returnTerm =
  G.Qualid (strToQId "return_")

bindOperator :: G.Term
bindOperator =
  G.Qualid (strToQId "op_>>=__")
