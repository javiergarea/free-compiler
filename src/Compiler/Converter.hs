module Compiler.Converter where

import qualified Language.Haskell.Exts.Syntax as H
import qualified Language.Coq.Gallina as G
import Language.Coq.Pretty (renderGallina)
import Text.PrettyPrint.Leijen.Text (renderPretty ,displayT)

import Compiler.Types (ConversionMode (..) ,ConversionMonad (..))
import Compiler.FueledFunctions (convertFueledFunBody ,addFuelMatching ,addFuelBinder
  ,addFuelArgToRecursiveCalls ,fuelTerm)
import Compiler.HelperFunctionConverter (convertMatchToMainFunction ,convertMatchToHelperFunction)
import Compiler.MonadicConverter (transformTermMonadic ,transformBindersMonadic ,addReturnToRhs ,addBindOperatorsToDefinition)
import Compiler.NonEmptyList (singleton, toNonemptyList)
import Compiler.HelperFunctions (getTypeSignatureByName ,getReturnType ,getString ,getReturnTypeFromDeclHead
  ,getNonInferrableConstrNames ,getNamesFromDataDecls ,getNameFromDeclHead ,containsRecursiveCall ,applyToDeclHead
  ,applyToDeclHeadTyVarBinds ,gNameToQId ,patToQID, getConstrCountFromDataDecls ,getTypeSignatureByQId ,getInferredBindersFromRetType
  ,isDataDecl ,isTypeSig ,hasNonInferrableConstr ,addInferredTypesToSignature ,qNameToTypeTerm ,qNameToTerm ,qNameToQId
  ,nameToQId ,nameToTerm ,nameToGName ,nameToTypeTerm ,strToQId ,strToGName ,qOpToQId ,termToStrings ,typeTerm ,collapseApp)

import qualified GHC.Base as B

import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Text.PrettyPrint.Leijen.Text (displayT, renderPretty)
import Data.List (partition)
import Data.Maybe (fromJust)


convertModule :: Show l => H.Module l -> ConversionMonad -> ConversionMode -> G.Sentence
convertModule (H.Module _ (Just modHead) _ _ decls) cMonad cMode =
  G.LocalModuleSentence (G.LocalModule (convertModuleHead modHead)
    (dataSentences ++
      convertModuleDecls rDecls (map filterForTypeSignatures typeSigs) dataTypes recursiveFuns cMonad cMode))
  where
    (typeSigs, otherDecls) = partition isTypeSig decls
    (dataDecls, rDecls) = partition isDataDecl otherDecls
    dataSentences = convertModuleDecls dataDecls (map filterForTypeSignatures typeSigs) [] recursiveFuns cMonad cMode
    dataTypes = (strToGName "List", 2) :
                zip (getNamesFromDataDecls dataDecls) (getConstrCountFromDataDecls dataDecls)
    recursiveFuns = getRecursiveFunNames rDecls
convertModule (H.Module _ Nothing _ _ decls) cMonad cMode =
  G.LocalModuleSentence (G.LocalModule (T.pack "unnamed")
    (convertModuleDecls otherDecls  (map filterForTypeSignatures typeSigs) [] recursiveFuns cMonad cMode))
  where
    (typeSigs, otherDecls) = partition isTypeSig decls
    recursiveFuns = getRecursiveFunNames otherDecls

----------------------------------------------------------------------------------------------------------------------
getRecursiveFunNames :: Show l => [H.Decl l] -> [G.Qualid]
getRecursiveFunNames decls =
  map getQIdFromFunDecl (filter isRecursiveFunction decls)

isRecursiveFunction :: Show l => H.Decl l -> Bool
isRecursiveFunction (H.FunBind _ (H.Match _ name _ rhs _ : xs)) =
  containsRecursiveCall (convertRhsToTerm rhs) (nameToQId name)
isRecursiveFunction _ =
  False

getQIdFromFunDecl :: Show l => H.Decl l -> G.Qualid
getQIdFromFunDecl (H.FunBind _ (H.Match _ name _ _ _ : _)) =
  nameToQId name

convertModuleHead :: Show l => H.ModuleHead l -> G.Ident
convertModuleHead (H.ModuleHead _ (H.ModuleName _ modName) _ _) =
  T.pack modName

importDefinitions :: [G.Sentence]
importDefinitions =
  [stringImport, libraryImport, monadImport]
  where
    stringImport = G.ModuleSentence (G.Require Nothing (Just G.Import) (singleton ( T.pack "String")))
    libraryImport = G.ModuleSentence (G.Require Nothing (Just G.Import) (singleton (T.pack "ImportModules")))
    monadImport =  G.ModuleSentence (G.ModuleImport G.Import (singleton (T.pack "Monad")))

convertModuleDecls :: Show l => [H.Decl l] -> [G.TypeSignature] -> [(G.Name, Int)] -> [G.Qualid] -> ConversionMonad -> ConversionMode -> [G.Sentence]
convertModuleDecls (H.FunBind _ (x : xs) : ds) typeSigs dataTypes recursiveFuns cMonad cMode =
  convertMatchDef x typeSigs dataTypes recursiveFuns cMonad cMode ++ convertModuleDecls ds typeSigs dataTypes recursiveFuns cMonad cMode
convertModuleDecls (H.DataDecl _ (H.DataType _ ) Nothing declHead qConDecl _  : ds) typeSigs dataTypes recursiveFuns cMonad cMode =
    if needsArgumentsSentence declHead qConDecl
      then [G.InductiveSentence  (convertDataTypeDecl declHead qConDecl cMonad)] ++
                                convertArgumentSentences declHead qConDecl ++
                                convertModuleDecls ds typeSigs dataTypes recursiveFuns cMonad cMode
      else G.InductiveSentence  (convertDataTypeDecl declHead qConDecl cMonad) :
                                convertModuleDecls ds typeSigs dataTypes recursiveFuns cMonad cMode
convertModuleDecls ((H.TypeDecl _ declHead ty) : ds) typeSigs dataTypes recursiveFuns cMonad cMode =
  G.DefinitionSentence (convertTypeDeclToDefinition declHead ty) :
    convertModuleDecls ds typeSigs dataTypes recursiveFuns cMonad cMode
convertModuleDecls ((H.PatBind _ pat rhs _) : ds) typeSigs dataTypes recursiveFuns cMonad cMode =
  G.DefinitionSentence (convertPatBindToDefinition pat rhs typeSigs dataTypes cMonad) :
    convertModuleDecls ds typeSigs dataTypes recursiveFuns cMonad cMode
convertModuleDecls [] _ _ _ _ _ =
  []
convertModuleDecls (d : ds) _ _ _ _ _ =
   error ("Top-level declaration not implemented: " ++ show d)

convertTypeDeclToDefinition :: Show l => H.DeclHead l -> H.Type l -> G.Definition
convertTypeDeclToDefinition dHead ty =
  G.DefinitionDef G.Global name binders Nothing rhs
  where
    name = (gNameToQId . getNameFromDeclHead) dHead
    binders = applyToDeclHeadTyVarBinds dHead convertTyVarBindToBinder
    rhs = convertTypeToTerm ty

convertPatBindToDefinition :: Show l => H.Pat l -> H.Rhs l -> [G.TypeSignature] ->[(G.Name, Int)] -> ConversionMonad -> G.Definition
convertPatBindToDefinition pat rhs typeSigs dataTypes cMonad =
  G.DefinitionDef G.Global name binders returnType rhsTerm
  where
    dataNames = map fst dataTypes
    binders = getInferredBindersFromRetType (fromJust returnType)
    name = patToQID pat
    typeSig = getTypeSignatureByQId typeSigs name
    returnType = convertReturnType typeSig cMonad
    rhsTerm = addReturnToRhs( convertRhsToTerm rhs) [] [] []

convertArgumentSentences :: Show l => H.DeclHead l -> [H.QualConDecl l] -> [G.Sentence]
convertArgumentSentences declHead qConDecls =
  [G.ArgumentsSentence (G.Arguments Nothing con (convertArgumentSpec declHead)) | con <- constrToDefine]
  where
    constrToDefine = getNonInferrableConstrNames qConDecls

convertArgumentSpec :: Show l => H.DeclHead l -> [G.ArgumentSpec]
convertArgumentSpec declHead =
  [G.ArgumentSpec G.ArgMaximal varName Nothing | varName <- varNames]
  where
   varNames = applyToDeclHeadTyVarBinds declHead convertTyVarBindToName

convertDataTypeDecl :: Show l => H.DeclHead l -> [H.QualConDecl l] -> ConversionMonad -> G.Inductive
convertDataTypeDecl dHead qConDecl cMonad =
  G.Inductive (singleton (G.IndBody typeName binders typeTerm constrDecls)) []
    where
      typeName = applyToDeclHead dHead nameToQId
      binders = applyToDeclHeadTyVarBinds dHead convertTyVarBindToBinder
      constrDecls = convertQConDecls
                      qConDecl
                        (getReturnTypeFromDeclHead (applyToDeclHeadTyVarBinds dHead convertTyVarBindToArg) dHead)
                          cMonad

convertMatchDef :: Show l => H.Match l -> [G.TypeSignature] -> [(G.Name, Int)] -> [G.Qualid] -> ConversionMonad -> ConversionMode -> [G.Sentence]
convertMatchDef (H.Match _ name mPats rhs _) typeSigs dataTypes recursiveFuns cMonad cMode =
    if containsRecursiveCall rhsTerm funName
      then if cMode == FueledFunction
            then [G.FixpointSentence (convertMatchToFueledFixpoint name mPats rhs typeSigs dataTypes recursiveFuns cMonad)]
            else convertMatchWithHelperFunction name mPats rhs typeSigs dataTypes cMonad
      else [G.DefinitionSentence (convertMatchToDefinition name mPats rhs typeSigs dataTypes recursiveFuns cMonad cMode)]
  where
    rhsTerm = convertRhsToTerm rhs
    funName = nameToQId name


convertMatchToDefinition :: Show l => H.Name l -> [H.Pat l] -> H.Rhs l -> [G.TypeSignature] -> [(G.Name, Int)] -> [G.Qualid] -> ConversionMonad -> ConversionMode -> G.Definition
convertMatchToDefinition name pats rhs typeSigs dataTypes recursiveFuns cMonad cMode =
  if cMode == FueledFunction && (not . null) recCalls
    then G.DefinitionDef G.Global funName
            bindersWithFuel
              returnType
                fueledMonadicTerm
    else G.DefinitionDef G.Global funName
            bindersWithInferredTypes
              returnType
                monadicTerm
  where
    returnType = convertReturnType typeSig cMonad
    funName = nameToQId name
    recCalls = filter (containsRecursiveCall rhsTerm) recursiveFuns
    typeSig = getTypeSignatureByName typeSigs name
    binders = convertPatsToBinders pats typeSig
    monadicBinders = transformBindersMonadic binders cMonad
    bindersWithInferredTypes = addInferredTypesToSignature monadicBinders (map fst dataTypes)
    bindersWithFuel = addFuelBinder bindersWithInferredTypes
    rhsTerm = convertRhsToTerm rhs
    monadicTerm = addBindOperatorsToDefinition monadicBinders (addReturnToRhs rhsTerm typeSigs monadicBinders dataTypes)
    fueledTerm = addFuelArgToRecursiveCalls rhsTerm fuelTerm recCalls
    fueledMonadicTerm = addBindOperatorsToDefinition monadicBinders (addReturnToRhs fueledTerm typeSigs monadicBinders dataTypes)

convertMatchToFueledFixpoint :: Show l => H.Name l -> [H.Pat l] -> H.Rhs l -> [G.TypeSignature] -> [(G.Name, Int)] -> [G.Qualid] -> ConversionMonad -> G.Fixpoint
convertMatchToFueledFixpoint name pats rhs typeSigs dataTypes recursiveFuns cMonad =
 G.Fixpoint (singleton (G.FixBody funName
    (toNonemptyList bindersWithFuel)
      Nothing
        (Just (transformTermMonadic (getReturnType typeSig) cMonad))
          fueledRhs)) []
  where
    typeSig = fromJust (getTypeSignatureByName typeSigs name)
    funName = nameToQId name
    binders = convertPatsToBinders pats (Just typeSig)
    monadicBinders = transformBindersMonadic binders cMonad
    bindersWithFuel = addFuelBinder bindersWithInferredTypes
    bindersWithInferredTypes = addInferredTypesToSignature monadicBinders (map fst dataTypes)
    rhsTerm = convertRhsToTerm rhs
    convertedFunBody = convertFueledFunBody (addReturnToRhs rhsTerm typeSigs monadicBinders dataTypes) monadicBinders funName typeSigs recursiveFuns
    fueledRhs = addFuelMatching monadicRhs funName
    monadicRhs = addBindOperatorsToDefinition monadicBinders convertedFunBody



convertMatchWithHelperFunction :: Show l => H.Name l -> [H.Pat l] -> H.Rhs l -> [G.TypeSignature] -> [(G.Name, Int)] -> ConversionMonad -> [G.Sentence]
convertMatchWithHelperFunction name pats rhs typeSigs dataTypes cMonad =
  [G.FixpointSentence (convertMatchToMainFunction name binders rhsTerm typeSigs dataTypes cMonad),
    G.DefinitionSentence (convertMatchToHelperFunction name binders rhsTerm typeSigs dataTypes cMonad)]
  where
    rhsTerm = convertRhsToTerm rhs
    binders = convertPatsToBinders pats typeSig
    typeSig = getTypeSignatureByName typeSigs name


convertTyVarBindToName :: Show l => H.TyVarBind l -> G.Name
convertTyVarBindToName (H.KindedVar _ name _) =
  nameToGName name
convertTyVarBindToName (H.UnkindedVar _ name) =
  nameToGName name

convertTyVarBindToBinder :: Show l => H.TyVarBind l -> G.Binder
convertTyVarBindToBinder (H.KindedVar _ name kind) =
  error "Kind-annotation not implemented"
convertTyVarBindToBinder (H.UnkindedVar _ name) =
  G.Typed G.Ungeneralizable G.Explicit (singleton (nameToGName name)) typeTerm

convertTyVarBindToArg :: Show l => H.TyVarBind l -> G.Arg
convertTyVarBindToArg (H.KindedVar _ name kind) =
  error "Kind-annotation not implemented"
convertTyVarBindToArg (H.UnkindedVar _ name) =
  G.PosArg (nameToTerm name)

convertQConDecls :: Show l => [H.QualConDecl l] -> G.Term -> ConversionMonad -> [(G.Qualid, [G.Binder], Maybe G.Term)]
convertQConDecls qConDecl term cMonad =
  [convertQConDecl c term cMonad | c <- qConDecl]

convertQConDecl :: Show l => H.QualConDecl l -> G.Term -> ConversionMonad -> (G.Qualid, [G.Binder], Maybe G.Term)
convertQConDecl (H.QualConDecl _ Nothing Nothing (H.ConDecl _ name types)) term cMonad =
  (nameToQId name, [] , Just (convertToArrowTerm types term cMonad))

convertToArrowTerm :: Show l => [H.Type l] -> G.Term -> ConversionMonad -> G.Term
convertToArrowTerm types returnType cMonad =
  buildArrowTerm (map (convertTypeToMonadicTerm cMonad) types ) returnType

buildArrowTerm :: [G.Term] -> G.Term -> G.Term
buildArrowTerm terms returnType =
  foldr G.Arrow returnType terms

filterForTypeSignatures :: Show l => H.Decl l -> G.TypeSignature
filterForTypeSignatures (H.TypeSig _ (name : rest) types) =
  G.TypeSignature (nameToGName name)
    (convertTypeToTerms types)

convertTypeToArg :: Show l => H.Type l -> G.Arg
convertTypeToArg ty =
  G.PosArg (convertTypeToTerm ty)

convertTypeToMonadicTerm :: Show l => ConversionMonad -> H.Type l -> G.Term
convertTypeToMonadicTerm cMonad (H.TyVar _ name)  =
  transformTermMonadic (nameToTypeTerm name) cMonad
convertTypeToMonadicTerm cMonad (H.TyCon _ qName)  =
  transformTermMonadic (qNameToTypeTerm qName) cMonad
convertTypeToMonadicTerm cMonad (H.TyParen _ ty)  =
  transformTermMonadic (G.Parens (convertTypeToTerm ty)) cMonad
convertTypeToMonadicTerm _ ty =
  convertTypeToTerm ty

convertTypeToTerm :: Show l => H.Type l -> G.Term
convertTypeToTerm (H.TyVar _ name) =
  nameToTypeTerm name
convertTypeToTerm (H.TyCon _ qName) =
  qNameToTypeTerm qName
convertTypeToTerm (H.TyParen _ ty) =
  G.Parens (convertTypeToTerm ty)
convertTypeToTerm (H.TyApp _ type1 type2) =
  G.App (convertTypeToTerm type1) (singleton (convertTypeToArg type2))
convertTypeToTerm ty =
  error ("Haskell-type not implemented: " ++ show ty )

convertTypeToTerms :: Show l => H.Type l -> [G.Term]
convertTypeToTerms (H.TyFun _ type1 type2) =
  convertTypeToTerms type1 ++
    convertTypeToTerms type2
convertTypeToTerms t =
  [convertTypeToTerm t]

convertReturnType :: Maybe G.TypeSignature -> ConversionMonad -> Maybe G.Term
convertReturnType Nothing  _ =
  Nothing
convertReturnType (Just (G.TypeSignature _ types)) cMonad =
  Just (transformTermMonadic (last types) cMonad )

convertPatsToBinders :: Show l => [H.Pat l] -> Maybe G.TypeSignature -> [G.Binder]
convertPatsToBinders patList Nothing =
  [convertPatToBinder p | p <- patList]
convertPatsToBinders patList (Just (G.TypeSignature _ typeList)) =
  convertPatsAndTypeSigsToBinders patList (init typeList)

convertPatToBinder :: Show l => H.Pat l -> G.Binder
convertPatToBinder (H.PVar _ name) =
  G.Inferred G.Explicit (nameToGName name)
convertPatToBinder pat =
  error ("Pattern not implemented: " ++ show pat)

convertPatsAndTypeSigsToBinders :: Show l => [H.Pat l] -> [G.Term] -> [G.Binder]
convertPatsAndTypeSigsToBinders =
  zipWith convertPatAndTypeSigToBinder

convertPatAndTypeSigToBinder :: Show l => H.Pat l -> G.Term -> G.Binder
convertPatAndTypeSigToBinder (H.PVar _ name) term =
  G.Typed G.Ungeneralizable G.Explicit (singleton (nameToGName name)) term
convertPatAndTypeSigToBinder pat _ =
  error ("Haskell pattern not implemented: " ++ show pat)

convertRhsToTerm :: Show l => H.Rhs l -> G.Term
convertRhsToTerm (H.UnGuardedRhs _ expr) =
  collapseApp (convertExprToTerm expr)
convertRhsToTerm (H.GuardedRhss _ _ ) =
  error "Guards not implemented"

convertExprToTerm :: Show l => H.Exp l -> G.Term
convertExprToTerm (H.Var _ qName) =
  qNameToTerm qName
convertExprToTerm (H.Con _ qName) =
  qNameToTerm qName
convertExprToTerm (H.Paren _ expr) =
  G.Parens (convertExprToTerm expr)
convertExprToTerm (H.App _ expr1 expr2) =
  G.App (convertExprToTerm expr1) (singleton (G.PosArg (convertExprToTerm expr2)))
convertExprToTerm (H.InfixApp _ exprL qOp exprR) =
  G.App (G.Qualid (qOpToQId qOp))
    (toNonemptyList [G.PosArg (convertExprToTerm exprL), G.PosArg (convertExprToTerm exprR)])
convertExprToTerm (H.Case _ expr altList) =
  G.Match (singleton ( G.MatchItem (convertExprToTerm expr)  Nothing Nothing))
    Nothing
      (convertAltListToEquationList altList)
convertExprToTerm (H.Lit _ literal) =
  convertLiteralToTerm literal
convertExprToTerm expr =
  error ("Haskell expression not implemented: " ++ show expr)

convertLiteralToTerm :: Show l => H.Literal l -> G.Term
convertLiteralToTerm (H.Char _ char _) =
  G.HsChar char
convertLiteralToTerm (H.String _ str _ ) =
  G.String (T.pack str)
convertLiteralToTerm (H.Int _ _ int) =
  G.Qualid (strToQId int)
convertLiteralToTerm literal = error ("Haskell Literal not implemented: " ++ show literal)


convertAltListToEquationList :: Show l => [H.Alt l] -> [G.Equation]
convertAltListToEquationList altList =
  [convertAltToEquation s | s <- altList]

convertAltToEquation :: Show l => H.Alt l -> G.Equation
convertAltToEquation (H.Alt _ pat rhs _) =
  G.Equation (singleton (G.MultPattern (singleton ( convertHPatToGPat pat)))) (convertRhsToTerm rhs)

convertHPatListToGPatList :: Show l => [H.Pat l] -> [G.Pattern]
convertHPatListToGPatList patList =
  [convertHPatToGPat s | s <- patList]

convertHPatToGPat :: Show l => H.Pat l -> G.Pattern
convertHPatToGPat (H.PVar _ name) =
  G.QualidPat (nameToQId name)
convertHPatToGPat (H.PApp _ qName pList) =
  G.ArgsPat (qNameToQId qName) (convertHPatListToGPatList pList)
convertHPatToGPat (H.PParen _ pat) =
  convertHPatToGPat pat
convertHPatToGPat (H.PWildCard _) =
  G.UnderscorePat
convertHPatToGPat pat =
  error ("Haskell pattern not implemented: " ++ show pat)

needsArgumentsSentence :: Show l => H.DeclHead l -> [H.QualConDecl l] -> Bool
needsArgumentsSentence declHead qConDecls =
  not (null binders) && hasNonInferrableConstr qConDecls
  where
    binders = applyToDeclHeadTyVarBinds declHead convertTyVarBindToBinder

--check if function is recursive
isRecursive :: Show l => H.Name l -> H.Rhs l -> Bool
isRecursive name rhs =
  elem (getString name) (termToStrings (convertRhsToTerm rhs))

importPath :: String
importPath =
  "Add LoadPath \"../ImportedFiles\". \n \r"

--print the converted module
printCoqAST :: G.Sentence -> IO ()
printCoqAST x =
  putStrLn (renderCoqAst (importDefinitions ++ [x]))

writeCoqFile :: String -> G.Sentence -> IO ()
writeCoqFile path x =
  writeFile path (renderCoqAst (importDefinitions ++ [x]))

renderCoqAst :: [G.Sentence] -> String
renderCoqAst sentences =
  importPath ++
    concat [(TL.unpack . displayT . renderPretty 0.67 120 . renderGallina) s  ++ "\n \r" | s <- sentences]
