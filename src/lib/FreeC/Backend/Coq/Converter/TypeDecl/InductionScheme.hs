module FreeC.Backend.Coq.Converter.TypeDecl.InductionScheme where

import           Control.Monad                    ( mapAndUnzipM )
import           Control.Monad.Extra              ( concatMapM )
import qualified Data.List.NonEmpty               as NonEmpty
import           Data.Maybe                       ( catMaybes, fromMaybe, fromJust )
import qualified Data.Map                         as Map
import qualified Data.Text                        as Text

import qualified FreeC.Backend.Coq.Base           as Coq.Base
import           FreeC.Backend.Coq.Converter.Arg
import           FreeC.Backend.Coq.Converter.Free
import           FreeC.Backend.Coq.Converter.Type
import qualified FreeC.Backend.Coq.Syntax         as Coq
import           FreeC.Environment
import           FreeC.Environment.Fresh
  ( freshArgPrefix, freshCoqQualid, freshCoqIdent )
import qualified FreeC.IR.Syntax                  as IR
import           FreeC.IR.TypeSynExpansion
import           FreeC.Monad.Converter

--import FreeC.Pretty
--import Text.PrettyPrint.Leijen.Text ( (<+>) )
--import Debug.Trace

generateInductionSchemes :: [IR.TypeDecl] -> Converter [Coq.Sentence]
generateInductionSchemes dataDecls = do
  let complexDataDecls = filter hasTypeVar dataDecls
  forQualidMap <- Map.fromList <$> mapM (generateName "For" "" . IR.typeDeclQName) complexDataDecls
  forBodies <- mapM (generateForProperty forQualidMap) complexDataDecls
  inQualidMap <- Map.fromList <$> mapM (generateInNames . IR.typeDeclQName) complexDataDecls
  (inBodies, inConNames) <- mapAndUnzipM (generateInProperties inQualidMap) complexDataDecls
  let inBodies' = concat inBodies
  schemeQualidMap <- Map.fromList <$> mapM (generateName "" "_ind" . IR.typeDeclQName) dataDecls
  schemeBodies <- mapM (generateSchemeLemma schemeQualidMap forQualidMap) dataDecls
  forallQualidMap <- Map.fromList <$> mapM (generateName "For" "_forall". IR.typeDeclQName) complexDataDecls
  forallBodies <- mapM (uncurry $ generateForallLemma schemeQualidMap forallQualidMap forQualidMap inQualidMap) $ zip inConNames complexDataDecls
  hintSentences <- concatMapM (generateHints schemeQualidMap forallQualidMap forQualidMap inQualidMap) complexDataDecls
  mapM_ (insertPropertiesInEnv forQualidMap inQualidMap . IR.typeDeclQName) complexDataDecls 
  return
    ( [Coq.InductiveSentence (Coq.Inductive (NonEmpty.fromList forBodies) []) | not (null forBodies)]
    ++[Coq.InductiveSentence (Coq.Inductive (NonEmpty.fromList inBodies') []) | not (null inBodies')]
    ++(map (\(name, binders, term, proof) ->
              Coq.AssertionSentence (Coq.Assertion Coq.Lemma name binders term) proof) (schemeBodies ++ forallBodies))
    ++ hintSentences
    )
 where

  -----------------------------------------------------------------------------
  -- @ForType@ Properties                                                    --
  -----------------------------------------------------------------------------

  generateForProperty :: Map.Map IR.QName Coq.Qualid -> IR.TypeDecl -> Converter Coq.IndBody
  generateForProperty _ (IR.TypeSynDecl _ _ _ _) = error "generateForProperty: Type synonym not allowed"
  generateForProperty forQualidMap (IR.DataDecl _ (IR.DeclIdent _ typeName) typeVarDecls conDecls) = do
    Just typeQualid <- inEnv $ lookupIdent IR.TypeScope typeName
    let forQualid = forQualidMap Map.! typeName
    forConQualids <- mapM (generateConName forQualid . IR.conDeclQName) conDecls
    localEnv $ do
      (typeVarQualids, typeVarBinders) <- convertTypeVarDecls' Coq.Explicit typeVarDecls
      propertyQualids <- mapM  (const $ freshCoqQualid "P") typeVarQualids
      forCons <- mapM (uncurry (generateForConstructor typeVarQualids propertyQualids)) $ zip conDecls forConQualids
      let propertyTypes = map  (\a -> (Coq.Arrow (Coq.Qualid a) (Coq.Sort Coq.Prop))) typeVarQualids
          propertyBinders = map (\(a,t) -> Coq.typedBinder' Coq.Ungeneralizable Coq.Explicit a t) $ zip propertyQualids propertyTypes
          binders = genericArgDecls Coq.Explicit ++ typeVarBinders ++ propertyBinders
          returnType = Coq.Arrow (genericApply typeQualid [] [] (map Coq.Qualid typeVarQualids))
                             (Coq.Sort Coq.Prop)
      return $ Coq.IndBody forQualid binders returnType forCons
   where
    generateForConstructor :: [Coq.Qualid] -> [Coq.Qualid] -> IR.ConDecl -> Coq.Qualid -> Converter (Coq.Qualid, [Coq.Binder], Maybe Coq.Term)
    generateForConstructor typeVarQualids propertyQualids (IR.ConDecl _ (IR.DeclIdent _ conName) args) forConQualid = localEnv $ do
      Just conQualid <- inEnv $ lookupIdent IR.ValueScope conName
      (argQualids, binders) <- unzip <$> mapM (convertAnonymousArg . Just) args
      forHypotheses <- catMaybes <$> (mapM (uncurry generateForHypothesis) $ zip argQualids args)
      let forQualid = forQualidMap Map.! typeName
          forResult = genericApply forQualid [] []
            (   map Coq.Qualid typeVarQualids
             ++ map Coq.Qualid propertyQualids
             ++ [genericApply conQualid [] (map Coq.Qualid typeVarQualids) (map Coq.Qualid argQualids)])
          returnType = Coq.forall binders (foldr Coq.Arrow forResult forHypotheses)
      return (forConQualid, [], Just returnType)
     where
      propertyMap :: Map.Map Coq.Qualid Coq.Qualid
      propertyMap = Map.fromList $ zip typeVarQualids propertyQualids

      generateForHypothesis :: Coq.Qualid -> IR.Type -> Converter (Maybe Coq.Term)
      generateForHypothesis argQualid argType = do
        coqType  <- convertType' argType
        argType' <- expandAllTypeSynonyms argType
        mbHyp <- generateForHypothesis_1 0 argType'
        return $ case mbHyp of
          Just hyp -> Just $ genericApply Coq.Base.forFree [] [] [coqType, hyp, Coq.Qualid argQualid]
          Nothing  -> Nothing
        
      generateForHypothesis_1 :: Int -> IR.Type -> Converter (Maybe Coq.Term)
      generateForHypothesis_1 _ (IR.FuncType _ _ _) = return Nothing
      generateForHypothesis_1 d (IR.TypeApp _ tcon lastArg) = generateForHypothesis_2 d tcon [lastArg]
      generateForHypothesis_1 _ (IR.TypeCon _ _)    = return Nothing -- Ignore type constructors that do not have any type variable or are partially applied
      generateForHypothesis_1 _ tvar@(IR.TypeVar _ _) = do
        Coq.Qualid tvarQualid <- convertType' tvar
        return $ Coq.Qualid <$> propertyMap Map.!? tvarQualid

      generateForHypothesis_2 :: Int -> IR.Type -> [IR.Type] -> Converter (Maybe Coq.Term)
      generateForHypothesis_2 _ (IR.FuncType _ _ _) _ = return Nothing
      generateForHypothesis_2 d (IR.TypeApp _ tcon lastArg) typeArgs = generateForHypothesis_2 d tcon (lastArg : typeArgs)
      generateForHypothesis_2 d (IR.TypeCon _ tconName) typeArgs = do
        Just tconArity <- inEnv $ lookupArity IR.TypeScope tconName
        hypotheses <- mapM (generateForHypothesis_1 (d+1)) typeArgs
        if (tconArity == length typeArgs) && (not $ null $ catMaybes hypotheses)
          then do let hypotheses' = map (fromMaybe (Coq.Qualid Coq.Base.noProperty)) hypotheses
                  coqArgs <- mapM convertType' typeArgs
                  mbForType <- if tconName == typeName && all (\(tvar, targ) -> Coq.Qualid tvar == targ) (zip typeVarQualids coqArgs) && d <= maxDepth
                    then return $ forQualidMap Map.!? tconName
                    else getForType Map.empty tconName -- Do not search in mutually recursive types
                  return ((\forType -> genericApply forType [] [] (coqArgs ++ hypotheses')) <$> mbForType)
          else return Nothing
      generateForHypothesis_2 _ (IR.TypeVar _ _) _ = return Nothing

  -----------------------------------------------------------------------------
  -- @InType@ Properties                                                     --
  -----------------------------------------------------------------------------

  generateInNames :: IR.QName -> Converter (IR.QName, [Coq.Qualid])
  generateInNames typeName = do
    Just arity <- inEnv $ lookupArity IR.TypeScope typeName
    inQualids <- map snd <$>  if arity == 1
      then mapM (generateName "In" "") [typeName]
      else mapM (\index -> generateName "In" ("_" ++ show index) typeName) [1 .. arity]
    return (typeName, inQualids)

  generateInProperties :: Map.Map IR.QName [Coq.Qualid] -> IR.TypeDecl -> Converter ([Coq.IndBody], [Coq.Qualid])
  generateInProperties _ (IR.TypeSynDecl _ _ _ _) = error "generateInProperty: Type synonym not allowed"
  generateInProperties inQualidMap (IR.DataDecl _ (IR.DeclIdent _ typeName) typeVarDecls conDecls) = do
    (bodies, inConNames) <- mapAndUnzipM (generateInProperty inQualidMap typeName typeVarDecls conDecls) [0 .. length typeVarDecls - 1]
    return (bodies, concat inConNames)

  generateInProperty :: Map.Map IR.QName [Coq.Qualid] -> IR.QName -> [IR.TypeVarDecl] -> [IR.ConDecl] -> Int -> Converter (Coq.IndBody, [Coq.Qualid])
  generateInProperty inQualidMap typeName typeVarDecls conDecls index = do
    Just typeQualid <- inEnv $ lookupIdent IR.TypeScope typeName
    let inQualid = (inQualidMap Map.! typeName) !! index
    (cons, mkBody) <- localEnv $ do
      (typeVarQualids, typeVarBinders) <- convertTypeVarDecls' Coq.Explicit typeVarDecls
      let binders = genericArgDecls Coq.Explicit ++ typeVarBinders
          returnType = Coq.Arrow (Coq.Qualid $ typeVarQualids !! index)
                         (Coq.Arrow (genericApply typeQualid [] [] (map Coq.Qualid typeVarQualids))
                           (Coq.Sort Coq.Prop))
          mkBody cons' = Coq.IndBody inQualid binders returnType cons'
      cons <- concatMapM (generateInConstructors typeVarQualids) conDecls
      return (cons, mkBody)
    cons' <- mapM (\(conName, mbConType) -> (\conQualid -> (conQualid, [], mbConType)) <$> generateConName inQualid conName) cons
    return (mkBody cons', map (\(q,_,_) -> q) cons')
   where
    generateInConstructors :: [Coq.Qualid] -> IR.ConDecl -> Converter [(IR.QName, Maybe Coq.Term)]
    generateInConstructors typeVarQualids (IR.ConDecl _ (IR.DeclIdent _ conName) args) = localEnv $ do
      Just conQualid <- inEnv $ lookupIdent IR.ValueScope conName
      (argQualids, argBinders) <- unzip <$> mapM (convertAnonymousArg . Just) args
      elemQualid <- freshCoqQualid "x"
      occurrences <- concatMapM (uncurry $ findOccurrences elemQualid) $ zip argQualids args
      let inQualid = (inQualidMap Map.! typeName) !! index
          inResult = genericApply inQualid [] []
            (   map Coq.Qualid typeVarQualids
             ++ [Coq.Qualid elemQualid]
             ++ [genericApply conQualid [] (map Coq.Qualid typeVarQualids) (map Coq.Qualid argQualids)])
          elemBinder = Coq.typedBinder' Coq.Ungeneralizable Coq.Explicit elemQualid (Coq.Qualid elemType)
          mkConType (occBinders, inHypotheses) = Coq.forall
            (elemBinder : occBinders ++ argBinders)
            (foldr Coq.Arrow inResult (reverse inHypotheses))
          conTypes = map mkConType occurrences
      return $ map ((,) conName . Just) conTypes
     where
      elemType :: Coq.Qualid
      elemType = typeVarQualids !! index

      inHypothesis :: Coq.Qualid -> [Coq.Term] -> Coq.Qualid -> Coq.Qualid -> Coq.Term
      inHypothesis inQualid typeArgs containerQualid elemQualid =
        genericApply inQualid [] [] (typeArgs ++ [Coq.Qualid elemQualid, Coq.Qualid containerQualid])

      findOccurrences :: Coq.Qualid -> Coq.Qualid -> IR.Type -> Converter [([Coq.Binder], [Coq.Term])]
      findOccurrences elemQualid argQualid argType = do
        coqType  <- convertType' argType
        argType' <- expandAllTypeSynonyms argType
        findOccurrences_1 0 elemQualid (inHypothesis Coq.Base.inFree [coqType] argQualid) argType'
        
      findOccurrences_1 :: Int -> Coq.Qualid -> (Coq.Qualid -> Coq.Term) -> IR.Type -> Converter [([Coq.Binder], [Coq.Term])]
      findOccurrences_1 _ _ _ (IR.FuncType _ _ _) = return []
      findOccurrences_1 _ _ _ (IR.TypeCon _ _)    = return [] -- Ignore type constructors that do not have any type variable or are partially applied
      findOccurrences_1 _ elemQualid mkInHyp tvar@(IR.TypeVar _ _) = do
        tvarType <- convertType' tvar
        return [([], [mkInHyp elemQualid]) | tvarType == Coq.Qualid elemType]
      findOccurrences_1 d elemQualid mkInHyp fullType@(IR.TypeApp _ _ _) =
        findOccurrences_2 fullType []
       where
        findOccurrences_2 :: IR.Type -> [IR.Type] -> Converter [([Coq.Binder], [Coq.Term])]
        findOccurrences_2 (IR.FuncType _ _ _) _ = return []
        findOccurrences_2 (IR.TypeApp _ tcon lastArg) typeArgs = findOccurrences_2 tcon (lastArg : typeArgs)
        findOccurrences_2 (IR.TypeVar _ _) _ = return []
        findOccurrences_2 (IR.TypeCon _ tconName) typeArgs = localEnv $ do
          Just tconArity <- inEnv $ lookupArity IR.TypeScope tconName
          if tconArity == length typeArgs
            then do
              coqArgs <- mapM convertType' typeArgs
              mbInTypes <- if tconName == typeName && all (\(tvar, targ) -> Coq.Qualid tvar == targ) (zip typeVarQualids coqArgs) && d <= maxDepth
                then return $ inQualidMap Map.!? tconName
                else getInTypes Map.empty tconName -- Do not search in mutually recursive types
              case mbInTypes of
                Just inTypes -> do
                  (containerQualid, containerBinder) <- convertAnonymousArg' (Just fullType)
                  occurrences <- concatMapM (\(it,arg) -> findOccurrences_1 (d+1) elemQualid (inHypothesis it coqArgs containerQualid) arg) $ zip inTypes typeArgs
                  let mkNewOcc (occBinders, inHypotheses) = (containerBinder : (reverse occBinders), mkInHyp containerQualid : inHypotheses)
                  return $ map mkNewOcc occurrences
                Nothing -> return []
            else return []

  -----------------------------------------------------------------------------
  -- Induction Schemes                                                       --
  -----------------------------------------------------------------------------

  -- | The maximal depth to search for recursive occurrences when construction
  --   induction hypotheses.
  --   @0@ -> Create only induction hypotheses for direct recursion.
  --   @n@ -> Create only induction hypotheses for constructor arguments where
  --          the recursive occurrence is encapsulated in at most @n@ data
  --          types.
  maxDepth :: Int
  maxDepth = 1

  -- | Generates an induction scheme for the data type.
  generateSchemeLemma :: Map.Map IR.QName Coq.Qualid -> Map.Map IR.QName Coq.Qualid -> IR.TypeDecl -> Converter (Coq.Qualid, [Coq.Binder], Coq.Term, Coq.Proof)
  generateSchemeLemma _ _ (IR.TypeSynDecl _ _ _ _) = error "generateInductionLemma: Type synonym not allowed"
  generateSchemeLemma schemeQualidMap forQualidMap (IR.DataDecl _ (IR.DeclIdent _ typeName) typeVarDecls conDecls) = localEnv $ do
    Just typeQualid <- inEnv $ lookupIdent IR.TypeScope typeName
    (tvarQualids, tvarBinders) <- convertTypeVarDecls' Coq.Explicit typeVarDecls
    (propQualid, propBinder) <- generateArg "P"
      (Coq.Arrow (genericApply typeQualid [] [] (map Coq.Qualid tvarQualids))
       (Coq.Sort Coq.Prop))
    indCases <- mapM (generateInductionCase propQualid) conDecls
    (valIdent, valBinder) <- generateArg freshArgPrefix
      (genericApply typeQualid [] [] (map Coq.Qualid tvarQualids))
    (indCaseQualids, fixpointQualid, varQualid) <- localEnv $
      do indCaseQualids <- mapM (const $ freshCoqQualid "InductionCase") indCases
         fixpointQualid <- freshCoqQualid "FP"
         varQualid <- freshCoqQualid "x"
         return (indCaseQualids, fixpointQualid, varQualid)
    let schemeName = schemeQualidMap Map.! typeName
        binders = genericArgDecls Coq.Explicit
          ++ tvarBinders
          ++ [propBinder]
        goal    = Coq.forall [valBinder]
          (Coq.app (Coq.Qualid propQualid) [Coq.Qualid valIdent])
        term    = Coq.forall binders (foldr Coq.Arrow goal indCases)
        vars    = map (fromJust . Coq.unpackQualid) (Coq.Base.shape : Coq.Base.pos : tvarQualids ++ [propQualid] ++ indCaseQualids)
        fixpoint = fromJust $ Coq.unpackQualid fixpointQualid
        var = fromJust $ Coq.unpackQualid varQualid
        proof   = Coq.ProofDefined
                 (Text.pack
                  $  "  intros" ++ concatMap (\v -> ' ' : v) vars ++ ";\n"
                  ++ "  fix " ++ fixpoint ++ " 1; intro " ++ var ++ ";\n"
                  ++ "  " ++ Text.unpack Coq.Base.proveInd
                  ++ ".")
    return (schemeName, [], term, proof)
   where
    -- | Generates an induction case for a given property and constructor.
    generateInductionCase
      :: Coq.Qualid -> IR.ConDecl -> Converter Coq.Term
    generateInductionCase propQualid (IR.ConDecl _ (IR.DeclIdent _ conName) argTypes) = localEnv $ do
      Just conQualid <- inEnv $ lookupIdent IR.ValueScope conName
      argTypes' <- mapM expandAllTypeSynonyms argTypes
      Just conType <- inEnv $ lookupReturnType IR.ValueScope conName
      conType' <- convertType' conType
      (argQualids, argBinders) <- mapAndUnzipM convertAnonymousArg (map Just argTypes)
      hypotheses <- catMaybes <$> mapM (uncurry $ generateInductionHypothesis propQualid conType') (zip argQualids argTypes')
      -- Create induction case.
      let term = foldr Coq.Arrow (Coq.app (Coq.Qualid propQualid) [Coq.app (Coq.Qualid conQualid) (map Coq.Qualid argQualids)]) hypotheses
          indCase = Coq.forall argBinders term
      return indCase

    generateInductionHypothesis :: Coq.Qualid -> Coq.Term -> Coq.Qualid -> IR.Type -> Converter (Maybe Coq.Term)
    generateInductionHypothesis propQualid conType argQualid argType = do
      mbHypothesis <- generateInductionHypothesis_1 maxDepth argType
      argType' <- convertType' argType
      case mbHypothesis of
        Just hypothesis -> return $ Just $ genericApply Coq.Base.forFree [] [] [argType', hypothesis, Coq.Qualid argQualid]
        Nothing -> return Nothing
     where
      generateInductionHypothesis_1 :: Int -> IR.Type -> Converter (Maybe Coq.Term)
      generateInductionHypothesis_1 _ (IR.FuncType _ _ _) = return Nothing
      generateInductionHypothesis_1 md t@(IR.TypeApp _ tcon lastArg) = do
        t' <- convertType' t
        if conType == t'
          then return $ Just $ Coq.Qualid propQualid
          else if md > 0 then generateInductionHypothesis_2 (md-1) tcon [lastArg] else return Nothing
      generateInductionHypothesis_1 _ t@(IR.TypeCon _ _) = do
        t' <- convertType' t
        if conType == t'
          then return $ Just $ Coq.Qualid propQualid
          else return Nothing -- Ignore type constructors that do not have any type variable or are partially applied
      generateInductionHypothesis_1 _ (IR.TypeVar _ _) = return Nothing

      generateInductionHypothesis_2 :: Int -> IR.Type -> [IR.Type] -> Converter (Maybe Coq.Term)
      generateInductionHypothesis_2 _ (IR.FuncType _ _ _) _ = return Nothing
      generateInductionHypothesis_2 md (IR.TypeApp _ tcon lastArg) typeArgs = generateInductionHypothesis_2 md tcon (lastArg : typeArgs)
      generateInductionHypothesis_2 md (IR.TypeCon _ tconName) typeArgs = do
        Just tconArity <- inEnv $ lookupArity IR.TypeScope tconName
        hypotheses <- mapM (generateInductionHypothesis_1 md) typeArgs
        if (tconArity == length typeArgs) && (not $ null $ catMaybes hypotheses)
          then do let hypotheses' = map (fromMaybe (Coq.Qualid Coq.Base.noProperty)) hypotheses
                  coqArgs <- mapM convertType' typeArgs
                  mbForType <- getForType forQualidMap tconName
                  return ((\forType -> genericApply forType [] [] (coqArgs ++ hypotheses')) <$> mbForType)
          else return Nothing
      generateInductionHypothesis_2 _ (IR.TypeVar _ _) _ = return Nothing

  -----------------------------------------------------------------------------
  -- Forall Lemmas                                                           --
  -----------------------------------------------------------------------------

  generateForallLemma :: Map.Map IR.QName Coq.Qualid -> Map.Map IR.QName Coq.Qualid ->
    Map.Map IR.QName Coq.Qualid -> Map.Map IR.QName [Coq.Qualid] ->
    [Coq.Qualid] -> IR.TypeDecl -> Converter (Coq.Qualid, [Coq.Binder], Coq.Term, Coq.Proof)
  generateForallLemma _ _ _ _ _ (IR.TypeSynDecl _ _ _ _) = error "generateForallLemma: Type synonym not allowed"
  generateForallLemma schemeQualidMap forallQualidMap forQualidMap inQualidMap inConNames (IR.DataDecl _ (IR.DeclIdent _ typeName) typeVarDecls _) = localEnv $ do
    Just typeQualid <- inEnv $ lookupIdent IR.TypeScope typeName
    (tvarQualids, tvarBinders) <- convertTypeVarDecls' Coq.Explicit typeVarDecls
    (propQualids, propBinders) <- mapAndUnzipM (\tv -> generateArg "P" (Coq.Arrow (Coq.Qualid tv) (Coq.Sort Coq.Prop))) tvarQualids
    (valQualid, valBinder) <- generateArg freshArgPrefix
      (genericApply typeQualid [] [] (map Coq.Qualid tvarQualids))
    inTerms <- mapM (uncurry $ generateInTerm valQualid tvarQualids) $ zip [0 ..] propQualids
    let forallQualid = forallQualidMap Map.! typeName
        forQualid = forQualidMap Map.! typeName
        binders = genericArgDecls Coq.Explicit ++ tvarBinders ++ propBinders ++ [valBinder]
        lhs = genericApply forQualid [] [] (map Coq.Qualid $ tvarQualids ++ propQualids ++ [valQualid])
        rhs = let (inQualids', [lastIn]) = splitAt (length inTerms - 1) $ inTerms
              in  foldr Coq.conj lastIn inQualids'
        term = Coq.forall binders (Coq.equiv lhs rhs)
        vars    = map (fromJust . Coq.unpackQualid) (Coq.Base.shape : Coq.Base.pos : tvarQualids ++ propQualids)
        Just schemeName = Coq.unpackQualid $ schemeQualidMap Map.! typeName
        proof   = Coq.ProofDefined
                 (Text.pack
                  $  concatMap generateForallHint inConNames
                  ++ "  intros" ++ concatMap (\v -> ' ' : v) vars ++ ";\n"
                  ++ "  " ++ Text.unpack Coq.Base.proveForall ++ ' ': schemeName
                  ++ ".")
    return (forallQualid, [], term, proof)
   where
    generateInTerm :: Coq.Qualid -> [Coq.Qualid] -> Int -> Coq.Qualid -> Converter Coq.Term
    generateInTerm valQualid tvarQualids index propQualid = localEnv $ do
      let inQualid = (inQualidMap Map.! typeName) !! index
      (val2Qualid, val2Binder) <- generateArg "y" (Coq.Qualid $ tvarQualids !! index)
      let isIn = genericApply inQualid [] [] (map Coq.Qualid $ tvarQualids ++ [val2Qualid, valQualid])
      return $ Coq.forall [val2Binder] $ Coq.Arrow isIn (Coq.app (Coq.Qualid propQualid) [Coq.Qualid val2Qualid])

    generateForallHint :: Coq.Qualid -> String
    generateForallHint inCon =
      let Just inStr = Coq.unpackQualid inCon
      in  "  Local Hint Extern 1 => " ++ Text.unpack Coq.Base.proveForall_finish ++
          ' ':inStr ++ " : " ++ Text.unpack Coq.Base.proveForall_db ++ ".\n"

  -----------------------------------------------------------------------------
  -- Hints                                                                   --
  -----------------------------------------------------------------------------
  -- | Generates hints that are used in the proofs of induction schemes and
  --   'forall' sentences.
  generateHints :: Map.Map IR.QName Coq.Qualid -> Map.Map IR.QName Coq.Qualid -> Map.Map IR.QName Coq.Qualid -> Map.Map IR.QName [Coq.Qualid] -> IR.TypeDecl -> Converter [Coq.Sentence]
  generateHints _ _ _ _ (IR.TypeSynDecl _ _ _ _) = error "generateHint: Type synonym not allowed"
  generateHints schemeQualidMap forallQualidMap forQualidMap inQualidMap (IR.DataDecl _ (IR.DeclIdent _ typeName) typeVarDecls _) = do
    let forall  = forallQualidMap Map.! typeName
        forType = forQualidMap Map.! typeName
        inTypes = inQualidMap Map.! typeName
        scheme  = schemeQualidMap Map.! typeName
    proveIndHint      <- generateProveIndHint forType forall scheme (length typeVarDecls)
    proveForallHint1  <- generateProveForallHint1 forType forall (length typeVarDecls)
    proveForallHints2 <- mapM (generateProveForallHint2 forType forall (length typeVarDecls)) inTypes
    return $ [proveIndHint, proveForallHint1] ++ proveForallHints2
  
  generateProveIndHint :: Coq.Qualid -> Coq.Qualid -> Coq.Qualid -> Int -> Converter (Coq.Sentence)
  generateProveIndHint forType forall scheme nTvars = do
    valStr <- localEnv $ freshCoqIdent freshArgPrefix
    let tacticConStr   = Text.unpack Coq.Base.proveInd_proveForType
        Just forallStr = Coq.unpackQualid forall
        Just schemeStr = Coq.unpackQualid scheme
        tactic         = tacticConStr ++ ' ' : valStr ++ ' ' : forallStr ++ ' ' : schemeStr
        underscores    = replicate (2 + 2 * nTvars) Coq.UnderscorePat
        valPattern     = Coq.QualidPat $ Coq.bare $ '?':valStr
        forTypePattern = Coq.ArgsPat forType $ underscores ++ [valPattern]
    return $ Coq.externHint (Just Coq.Global) 0 (Just forTypePattern) tactic [Coq.Base.proveInd_db]

  generateProveForallHint1 :: Coq.Qualid -> Coq.Qualid -> Int -> Converter (Coq.Sentence)
  generateProveForallHint1 forType forall nTvars = do
    let tacticConStr   = Text.unpack Coq.Base.proveForall_proveForType
        Just forallStr = Coq.unpackQualid forall
        tactic         = tacticConStr ++ ' ' : forallStr
        underscores    = replicate (3 + 2 * nTvars) Coq.UnderscorePat
        forTypePattern = Coq.ArgsPat forType $ underscores
    return $ Coq.externHint (Just Coq.Global) 0 (Just forTypePattern) tactic [Coq.Base.proveForall_db]

  generateProveForallHint2 :: Coq.Qualid -> Coq.Qualid -> Int -> Coq.Qualid -> Converter (Coq.Sentence)
  generateProveForallHint2 forType forall nTvars inType = localEnv $ do
    hForStr <- freshCoqIdent "HF"
    hInStr  <- freshCoqIdent "HI"
    valStr1 <- freshCoqIdent freshArgPrefix
    valStr2 <- freshCoqIdent freshArgPrefix
    let tacticConStr    = Text.unpack Coq.Base.proveForall_ForType_InType
        Just forStr     = Coq.unpackQualid forType
        Just inStr      = Coq.unpackQualid inType
        Just forallStr  = Coq.unpackQualid forall
        forPatStrs      = forStr : (replicate (2 + 2 * nTvars) "_") ++ ['?':valStr2]
        inPatStrs       = inStr : (replicate (2 + nTvars) "_") ++ ['?':valStr1, '?':valStr2]
        tactic          = unlines
          [ ""
          , "  match goal with"
          , "  | [ " ++ hForStr ++ " : " ++ unwords forPatStrs
          , "    , " ++ hInStr ++ " : " ++ unwords inPatStrs
          , "    |- _ ] =>"
          , "      " ++ unwords [tacticConStr, hForStr, hInStr, valStr1, forallStr]
          , "  end"
          ]
    return $ Coq.externHint (Just Coq.Global) 0 Nothing tactic [Coq.Base.proveForall_db]

  -----------------------------------------------------------------------------
  -- Helper Functions                                                        --
  -----------------------------------------------------------------------------

  hasTypeVar :: IR.TypeDecl -> Bool
  hasTypeVar (IR.TypeSynDecl _ _ _ _) = error "hasTypeVar: Type synonym not allowed"
  hasTypeVar (IR.DataDecl _ _ typeVarDecls _) = not $ null typeVarDecls

  generateName :: String -> String -> IR.QName -> Converter (IR.QName, Coq.Qualid)
  generateName prefix suffix typeQName = do
    Just typeQualid <- inEnv $ lookupIdent IR.TypeScope typeQName
    let Just typeIdent = Coq.unpackQualid typeQualid
    newQualid <- freshCoqQualid $ prefix ++ typeIdent ++ suffix
    return (typeQName, newQualid)

  generateConName :: Coq.Qualid -> IR.QName -> Converter Coq.Qualid
  generateConName baseQualid conQName = do
    Just conQualid <- inEnv $ lookupIdent IR.ValueScope conQName
    let Just baseName = Coq.unpackQualid baseQualid
        Just conName    = Coq.unpackQualid conQualid 
    freshCoqQualid $ baseName ++ "_" ++ conName

  getForType :: Map.Map IR.QName Coq.Qualid -> IR.QName -> Converter (Maybe Coq.Qualid)
  getForType forQualidMap name = case forQualidMap Map.!? name of
    Just qualid -> return $ Just qualid
    Nothing     -> inEnv $ lookupForProperty name

  getInTypes :: Map.Map IR.QName [Coq.Qualid] -> IR.QName -> Converter (Maybe [Coq.Qualid])
  getInTypes inQualidMap name = case inQualidMap Map.!? name of
    Just qualids -> return $ Just qualids
    Nothing      -> inEnv $ lookupInProperties name

  insertPropertiesInEnv :: Map.Map IR.QName Coq.Qualid -> Map.Map IR.QName [Coq.Qualid] -> IR.QName -> Converter ()
  insertPropertiesInEnv forQualidMap inQualidMap name = do
    let forName = forQualidMap Map.!? name
        inNames = inQualidMap Map.!? name
    modifyEnv $ addPropertyNamesToEntry name forName inNames

  generateArg :: String -> Coq.Term -> Converter (Coq.Qualid, Coq.Binder)
  generateArg argName argType = do
    qualid <- freshCoqQualid argName
    let binder = Coq.typedBinder Coq.Ungeneralizable Coq.Explicit [qualid] argType
    return (qualid, binder)
