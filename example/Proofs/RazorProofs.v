From Base Require Import Free Free.Instance.Maybe Free.Instance.Error Prelude Test.QuickCheck.
From Generated Require Import Proofs.Razor.

Require Import Coq.Logic.FunctionalExtensionality.
Require Import Coq.Program.Equality.

(* Define some additional tactics. *)
Ltac simplifyInductionHypothesis ident1 ident2 :=
  match goal with
  | [ ident1 : ForFree ?Shape ?Pos ?A ?P (pure _) |- _ ] => inversion ident1 as [ Heq ident2 |]; clear ident1; subst Heq; simpl
  | [ ident1 : ForFree ?Shape ?Pos ?A ?P (impure ?s ?pf) |- _ ] =>
    dependent destruction ident1;
    match goal with
    | [ H1 : forall p : ?T, ForFree ?Shape ?Pos ?A ?P (?pf p), H0 : forall p, ForFree ?Shape ?Pos ?A ?Py (?pf p) -> _ = _,
        p : ?T |- _ ] =>
      specialize (H0 p (H1 p)) as ident2; clear H1; clear H0; simpl
    end
  end.

Tactic Notation "simplify'" ident(H) "as" ident(IH) := (simplifyInductionHypothesis H IH).

Ltac autoInductionHypothesis :=
  match goal with
  (*  | [ s : Zero__S |- _ ] => destruct s *)
  | [ H : ForFree ?Shape ?Pos ?A ?P (impure ?s ?pf) |- ?h ?s ?pf1 = ?h ?s ?pf2 ] =>
    f_equal; let x := fresh in
             extensionality x; simplify' H as Hnew; assumption
    (*   try apply newH) *)
  | [ H : ForFree ?Shape ?Pos ?A ?P (pure ?x) |- _ ] =>
    let newH := fresh in simplify' H as newH; rename newH into IH
  | [ H : forall p : ?T, ?f = ?g |- ?h ?s ?pf1 = ?h ?s ?pf2 ] =>
    f_equal; let x := fresh in extensionality x; apply H
  | [ H : forall p : ?T, ?f = ?g |- impure ?s ?pf1 = impure ?s ?pf2 ] =>
    f_equal; let x := fresh in extensionality x; apply H
  end.

Tactic Notation "autoIH" := (autoInductionHypothesis).

Tactic Notation "inductFree" ident(fx) "as" simple_intropattern(pat) := (induction fx as pat; simpl; try autoIH).

(* Define induction scheme for [Expr]. *)
Section Expr_ind.

  Variable Shape : Type.
  Variable Pos   : Shape -> Type.
  Variable P     : Expr Shape Pos -> Prop.

  Hypothesis valP : forall (fn : Free Shape Pos (Integer.Integer Shape Pos)), P (val fn).

  Hypothesis addP : forall (fx fy : Free Shape Pos (Expr Shape Pos)),
    ForFree Shape Pos (Expr Shape Pos) P fx ->
      ForFree Shape Pos (Expr Shape Pos) P fy ->
        P (add0 fx fy).

  Fixpoint Expr_Ind (expr : Expr Shape Pos) : P expr.
  Proof.
    destruct expr as [ fn | fx fy ].
    - apply valP.
    - apply addP.
      + apply ForFree_forall. intros e IHe.
        inductFree fx as [ x | s pf IHpf ].
        * inversion IHe; subst. apply Expr_Ind.
        * dependent destruction IHe; subst. destruct H as [ p ].
          apply IHpf with (p := p). apply H.
      + apply ForFree_forall. intros e IHe.
        inductFree fy as [ y | s pf IHpf ].
        * inversion IHe; subst. apply Expr_Ind.
        * dependent destruction IHe; subst. destruct H as [ p ].
          apply IHpf with (p := p). apply H.
  Defined.

End Expr_ind.

(* The following lemma and theorem are proven in the file `AppendAssocProofs.v`. *)
Lemma append_nil : quickCheck prop_append_nil. Proof. Admitted.
Theorem append_assoc : quickCheck prop_append_assoc. Proof. Admitted.

(* This property states, that the given Partial instance represents every [undefined] as an impure value. *)
Definition UndefinedIsImpure {Shape : Type} {Pos : Shape -> Type} (Partial : Partial Shape Pos): Prop :=
    forall (A : Type),
    exists (s : Shape) (pf : (Pos s) -> Free Shape Pos A),
  @undefined Shape Pos Partial A = impure s pf.

(* The property holds for the [Maybe] monad and the [Error] monad. *)
Example undefinedIsImpureMaybe : UndefinedIsImpure Maybe.Partial.
Proof.
  intro A.
  simpl. unfold Nothing. exists tt.
  exists (fun p : Maybe.Pos tt => match p return (Free unit Maybe.Pos A) with end).
  reflexivity.
Qed.

Example undefinedIsImpureError : UndefinedIsImpure Error.Partial.
Proof.
  intro A.
  simpl. unfold ThrowError. exists "undefined"%string.
  exists (fun p : Error.Pos "undefined"%string => match p return (Free string Error.Pos A) with end).
  reflexivity.
Qed.

(* This is a tactic, which discriminates assumptions where [impure] is equal to some [pure] value. *)
Ltac pureEqImpure :=
  match goal with
  | [ HUnd : @UndefinedIsImpure ?Shape ?Pos ?Partial |- _] =>
      match goal with
      | [ HEq : pure _ = @undefined Shape Pos Partial ?A |- _] =>
          specialize (HUnd (Stack Shape Pos));
          destruct HUnd as [ sImp HUnd ];
          destruct HUnd as [ pfImp HUnd ];
          rewrite HUnd in HEq;
          discriminate HEq
      | [ HEq : @undefined Shape Pos Partial ?A = pure _ |- _] =>
          specialize (HUnd (Stack Shape Pos));
          destruct HUnd as [ sImp HUnd ];
          destruct HUnd as [ pfImp HUnd ];
          rewrite HUnd in HEq;
          discriminate HEq
      end
  | [ H : impure _ _ = pure _ |- _ ] => discriminate H
  | [ H : pure _ = impure _ _ |- _ ] => discriminate H
  end.

(* This property states that the given expression is recursively pure.
   The integers in that expression however might still be impure. *)
Inductive RecPureExpr {Shape : Type} {Pos : Shape -> Type} : Free Shape Pos (Expr Shape Pos) -> Prop :=
  | recPureExpr_val : forall (fn : Free Shape Pos (Integer.Integer Shape Pos)),
      RecPureExpr (Val Shape Pos fn)
  | recPureExpr_add : forall (fx fy : Free Shape Pos (Expr Shape Pos)),
      RecPureExpr fx -> RecPureExpr fy -> RecPureExpr (Add0 Shape Pos fx fy).

(* This property states that the for a given code the list is recursively pure
   and all contained operations are pure.
   The integers in those operations however might still be impure. *)
Inductive RecPureCode {Shape : Type} {Pos : Shape -> Type} : Free Shape Pos (Code Shape Pos) -> Prop :=
  | recPureCode_nil : RecPureCode (Nil Shape Pos)
  | recPureCode_cons : forall (op : Op Shape Pos) (fcode : Free Shape Pos (Code Shape Pos)),
      RecPureCode fcode -> RecPureCode (Cons Shape Pos (pure op) fcode).

Inductive RecPureStack {Shape : Type} {Pos : Shape -> Type} : Free Shape Pos (Stack Shape Pos) -> Prop :=
  | recPureStack_nil : RecPureStack (Nil Shape Pos)
  | recPureStack_cons : forall (fv : Free Shape Pos (Integer Shape Pos))
                              (fstack : Free Shape Pos (Stack Shape Pos)),
      RecPureStack fstack -> RecPureStack (Cons Shape Pos fv fstack).

Section Proofs.

  Variable Shape   : Type.
  Variable Pos     : Shape -> Type.
  Variable Partial : Partial Shape Pos.

  (* If the code is pure and the first operation is pure if there is any, the
     effect of an impure stack will transfer to the result of an exec call with
     that code and that stack. *)
  Lemma exec_strict_on_stack_arg_nil :
    forall (sStack  : Shape)
           (pfStack : Pos sStack -> Free Shape Pos (Stack Shape Pos)),
        exec Shape Pos Partial (Nil Shape Pos) (impure sStack pfStack)
        = impure sStack (fun p => exec Shape Pos Partial (Nil Shape Pos) (pfStack p)).
  Proof.
    intros sStack pfStack.
    reflexivity.
  Qed.

  Lemma exec_strict_on_stack_arg_cons :
    forall (op : Op Shape Pos)
           (fcode : Free Shape Pos (Code Shape Pos))
           (sStack  : Shape)
           (pfStack : Pos sStack -> Free Shape Pos (Stack Shape Pos)),
        exec Shape Pos Partial (Cons Shape Pos (pure op) fcode) (impure sStack pfStack)
        = impure sStack (fun p => exec Shape Pos Partial (Cons Shape Pos (pure op) fcode) (pfStack p)).
  Proof.
    intros op fcode sStack pfStack.
    destruct op as [ fn | ].
    - reflexivity.
    - reflexivity.
  Qed.

  (* If [UndefinedIsImpure] holds and we know that [exec] applied to some [Code]
     [fcode1] returns a pure value, we know that [exec] applied to [fcode1]
     appended with some [Code] [fcode2] has the same result as applying [exec] to
     [fcode1] first and applying [exec] to [fcode2] second. *)
  Lemma exec_append :
    UndefinedIsImpure Partial ->
    forall (fcode1 fcode2 : Free Shape Pos (Code Shape Pos))
           (fstack        : Free Shape Pos (Stack Shape Pos)),
    (exists (stack' : Stack Shape Pos), exec Shape Pos Partial fcode1 fstack = pure stack') ->
        exec Shape Pos Partial (append Shape Pos fcode1 fcode2) fstack
        = exec Shape Pos Partial fcode2 (exec Shape Pos Partial fcode1 fstack).
  Proof.
    intros HUndefined fcode1 fcode2.
    (* Destruct the monadic layer of the first piece of code. *)
    destruct fcode1 as [ code1 | sCode1 pfCode1 ].
    - (* fcode1 = pure code1 *)
      (* Do an induction over the first piece of code. *)
      induction code1 as [ | [ [ fn | ] | sOp pfOp ] fcode1' IHfcode1'] using List_Ind.
      + (* fcode1 = pure [] *)
        (* This case is trivial. *)
        intros fstack H.
        destruct fstack as [ [ | fv fstack1 ] | sStack pfStack ]; try reflexivity.
        rewrite exec_strict_on_stack_arg_nil in H.
        destruct H as [ stack' H ]. discriminate H.
      + (* fcode1 = pure (pure (PUSH fn) : fcode1') *)
        intros fstack H.
        (* Destruct the remaining code [fcode1'] to see, wether it is pure or impure. *)
        destruct fcode1' as [ code1' | sCode1' pfCode1' ].
        * (* fcode1 = pure (pure (PUSH fn) : pure code1') *)
          (* In this case we can apply the induction hypothesis. *)
          destruct fstack as [ [ | fv fstack1 ] | sStack pfStack ].
          { autoIH. apply IH. apply H. }
          { autoIH. apply IH. apply H. }
          { specialize exec_strict_on_stack_arg_cons as L.
            unfold Cons in L. rewrite L in H.
            destruct H as [stack' H]. discriminate H. }
        * (* fcode1 = pure (pure (PUSH fn) : impure sCode1' pfCode1' *)
          (* In this case we have impure code and therefore [H] can't hold. *)
          destruct H as [ stack' Hstack' ].
          destruct fstack as [ [ | fv fstack1 ] | sStack pfStack ]; discriminate Hstack'.
      + (* fcode1 = pure (pure ADD : fcode1') *)
        intros fstack H. destruct H as [ stack' Hstack' ].
        (* Destruct the remaining code [fcode1'] to see, wether it is pure or impure. *)
        destruct fcode1' as [ code1' | sCode1' pfCode1' ].
        * (* fcode1 = pure (pure ADD : pure code1') *)
          (* As the addition reads its two inputs from the stack [fstack], we need to destruct it.
             All cases, where the stack does not contain at least two values, can't produce a pure result
             and are therefore a violation to [Hstack']. *)
          destruct fstack as [ [ | fv1 [ [ | fv2 fstack2 ] | sStack1 pfStack1 ] ] | sStack pfStack ];
            simpl in Hstack'; try pureEqImpure.
          (* In the only valid case we can apply the induction hypothesis. *)
          autoIH. apply IH. exists stack'. apply Hstack'.
        * (* fcode1 = pure (pure ADD : impure sCode1' pfCode1') *)
          (* This case is again a violation to [Hstack'] which we can proof by destructing [fstack]. *)
          destruct fstack as [ [ | fv1 [ [ | fv2 fstack2 ] | sStack1 pfStack1 ] ] | sStack pfStack ];
            simpl in Hstack'; pureEqImpure.
      + (* fcode1 = pure (impure sOp pfOp : fcode1') *)
        (* In this case the first operation is impure, therefore we have another violation to [H]. *)
        intros fstack H. destruct H as [ stack' Hstack' ]. discriminate Hstack'.
  - (* fcode1 = impure sCode1 pfCode1 *)
    (* In this case, where the whole [fcode1] is impure, we have another violation to [H]. *)
    intros fstack H. destruct H as [ stack' Hstack' ]. discriminate Hstack'.
  Qed.

  (* If we apply [append] on to pieces of recursively pure code the result is recursively pure code. *)
  Lemma append_pure :
    forall (fcode1 fcode2 : Free Shape Pos (Code Shape Pos)),
    RecPureCode fcode1 ->
    RecPureCode fcode2 ->
        RecPureCode (append Shape Pos fcode1 fcode2).
  Proof.
    intros fcode1 fcode2 HPure1 HPure2.
    (* The first piece of code is pure. *)
    destruct fcode1 as [ code1 | ]. 2: dependent destruction HPure1.
    (* Do an induction over the first piece of code. *)
    induction code1 as [ | fop fcode1' ] using List_Ind.
    - simpl. apply HPure2.
    - (* The first operation in a non empty [code1] is pure. *)
      destruct fop as [ op | ]. 2: do 2 dependent destruction HPure1.
      (* The rest list in a non empty [code1] is also pure. *)
      destruct fcode1' as [ code1' | ]. 2: do 2 dependent destruction HPure1.
      simpl. apply recPureCode_cons.
      autoIH. dependent destruction HPure1. apply (IH HPure1).
  Qed.

  (* The compilation of a recursively pure expression with [comp] produces recursively pure code. *)
  Lemma comp_pure :
    forall (fexpr : Free Shape Pos (Expr Shape Pos)),
    RecPureExpr fexpr ->
        RecPureCode (comp Shape Pos fexpr).
  Proof.
    intros fexpr HPure.
    (* The given expression is pure. *)
    destruct fexpr as [ expr | sExpr pfExpr ]. 2: dependent destruction HPure.
    (* Do an induction over this expression. *)
    induction expr as [ fn | fx fy IHfx IHfy ] using Expr_Ind.
    - (* In this case, we have a single value as expression. *)
      simpl. apply recPureCode_cons. apply recPureCode_nil.
    - (* In this case, we have an addition of two expressions [fx] and [fy]. *)
      dependent destruction HPure.
      (* The expression [fx] is pure. *)
      destruct fx as [ x | sX pfX ]. 2: dependent destruction HPure1.
      (* Use the lemma [append_pure] with the three recursively pure pieces of code: 
         - (comp_0 Shape Pos x)
         - (fy >>= (fun y : Expr Shape Pos => comp_0 Shape Pos y))
         - (Cons Shape Pos (ADD Shape Pos) (Nil Shape Pos)) *)
      simpl. apply append_pure. apply append_pure.
      (* Now we need to prove that those pieces of code were indeed recursively pure. *)
      + autoIH. apply (IH HPure1).
      + (* The expression [fy] is pure. *)
        destruct fy as [ y | sY pfY ]. 2: dependent destruction HPure2.
        autoIH. apply (IH HPure2).
      + apply recPureCode_cons. apply recPureCode_nil.
Qed.

  (* To prove the correctness of the compiler [comp] as stated in the QuickCheck property,
     we have to generalize it first by adding an additional recursivly pure stack and we
     need the preconditions, that [UndefinedIsImpure] holds and the given expression is
     recursively pure. *)
  Lemma comp_correct' :
    UndefinedIsImpure Partial ->
    forall (fexpr : Free Shape Pos (Expr Shape Pos)),
    RecPureExpr fexpr ->
    forall (fstack : Free Shape Pos (Stack Shape Pos)),
    RecPureStack fstack ->
        exec Shape Pos Partial (comp Shape Pos fexpr) fstack
        = Cons Shape Pos (eval Shape Pos fexpr) fstack.
  Proof.
    intros HUndefined fexpr HPureE.
    (* The given expression is pure. *)
    destruct fexpr as [ expr | sExpr pfExpr ]. 2: dependent destruction HPureE.
    (* We proof this lemma by doing an induction over this expression. *)
    induction expr as [ fn | fx fy IHfx IHfy ] using Expr_Ind.
    - (* The correctness is trivial for an expression that is a single value. *)
      intros fstack HPureS.
      destruct fstack as [ [ | fv fstack1 ] | sStack pfStack ]; try reflexivity.
      dependent destruction HPureS.
    - (* An expression that represents the addition of two expressions [fx] and [fy] gets
         compiled to more complex code. We start by destructing the pureness property for
         the addition, to get a pureness property for [fx] and a pureness property for [fy]. *)
      intros fstack HPureS.
      dependent destruction HPureE.
      (* Now we know, that both expressions are pure. *)
      destruct fx as [ x | sX pfX ]. 2: dependent destruction HPureE1.
      destruct fy as [ y | yX pfY ]. 2: dependent destruction HPureE2.
      simpl comp.
      (* We use the lemma [exec_append] to transform the execution of appended pieces of code
         to multiple [exec] calls, where the resulting stack of the [exec] call on one piece of
         code is handed over as the initial stack of the [exec] call on the next piece of code. *)
      do 2 rewrite (exec_append HUndefined).
      (* As [exec_append] has the precondition, that the execution of the first piece of code
         produces a (not necessarily recursively) pure stack, we gain three additional subgoals. *)
      + (* For the main goal, we can apply the induction hypotheses. *)
        simplify IHfy as IHy. simplify IHfx as IHx.
        simpl exec at 3. simpl in IHx. rewrite (IHx HPureE1 _ HPureS).
        simpl exec at 2. rewrite (IHy HPureE2 _ (recPureStack_cons _ _ HPureS)).
        reflexivity.
      (* The three remaining subgoals can be proven each by using an induction hypothesis. *)
      + exists (cons (eval Shape Pos (pure x)) fstack).
        clear IHfy. autoIH. apply (IH HPureE1 _ HPureS).
      + exists (cons (eval Shape Pos (pure y)) (exec Shape Pos Partial (comp Shape Pos (pure x)) fstack)).
        autoIH. rename IH into IHy.
        autoIH. rename IH into IHx.
        simpl in IHx. rewrite (IHx HPureE1 _ HPureS).
        apply (IHy HPureE2 _ (recPureStack_cons _ _ HPureS)).
      + exists (cons (eval Shape Pos (pure x)) fstack).
        clear IHfy. autoIH. apply (IH HPureE1 _ HPureS).
  Qed.

  (* The theorem derived by the correctness QuickCheck property for comp_correct can now be proven
     with the more general lemma above and under the same two assumptions, namely [UndefinedIsImpure]
     holds and the given expression is recursively pure. *)
  Theorem comp_correct :
    UndefinedIsImpure Partial ->
    forall (fexpr : Free Shape Pos (Expr Shape Pos)),
    RecPureExpr fexpr ->
        quickCheck (prop_comp_correct Shape Pos Partial fexpr).
  Proof.
    simpl.
    intros HUndefined fexpr HPure.
    apply (comp_correct' HUndefined fexpr HPure _ recPureStack_nil).
  Qed.

  (* To prove the equivalence property of the two compilers [comp] and [comp'] we first prove the
     derived property for [comp] and [compApp] which is used by [comp']. *)
  Lemma compApp_comp_append_eq :
    forall (fexpr : Free Shape Pos (Expr Shape Pos))
           (fcode : Free Shape Pos (Code Shape Pos)),
        compApp Shape Pos fexpr fcode
        = append Shape Pos (comp Shape Pos fexpr) fcode.
  Proof.
    intro fexpr.
    (* We start with an induction over the monadic expression. *)
    inductFree fexpr as [ expr | s pf IHpf ].
    - (* In the pure case, we do an induction over the given expression. *)
      induction expr as [ fn | fx fy IHfx IHfy ] using Expr_Ind.
      + (* For an expression that is only a single value, the property is trivial. *)
        reflexivity.
      + (* For an addition expression, we start with some simplification steps for the [append] function. *)
        intro fcode. simpl comp_0.
        do 2 (rewrite <- append_assoc).
        simpl append.
        (* We use [replace] here to make this main proof simple and produce additional simple subgoals. *)
        replace (append Shape Pos _ (Cons Shape Pos (ADD Shape Pos) fcode))
          with (compApp Shape Pos fy (Cons Shape Pos (ADD Shape Pos) fcode)).
        replace (append Shape Pos _ (compApp Shape Pos fy (Cons Shape Pos (ADD Shape Pos) fcode)))
          with (compApp Shape Pos fx (compApp Shape Pos fy (Cons Shape Pos (ADD Shape Pos) fcode))).
        reflexivity.
        (* Prove subgoals, that were introduced by the [replace] tactic, by induction. *)
        * inductFree fx as [ x | s pf IHpf ].
          { apply IH. }
          { f_equal. extensionality p. dependent destruction IHfx. specialize (IHpf p (H p)) as IH. apply IH. }
        * inductFree fy as [ y | s pf IHpf ].
          { apply IH. }
          { f_equal. extensionality p. dependent destruction IHfy. specialize (IHpf p (H p)) as IH. apply IH. }
    - (* In the impure case, we apply the induction hypothesis.*)
      intro fcode. f_equal. extensionality p. apply IHpf.
  Qed.

  (* With the equivalence lemma above the proof of the main equivalence theorem is simple. *)
  Theorem comp_comp'_eq : quickCheck (prop_comp_comp'_eq Shape Pos).
  Proof.
    simpl.
    intro fexpr.
    rewrite <- append_nil.
    rewrite <- compApp_comp_append_eq.
    reflexivity.
  Qed.

  (* The correctness of the compiler [comp'] is implied by the equivalence to
     the compiler [comp] and the correctness of [comp]. *)
  Lemma comp'_correct : 
    UndefinedIsImpure Partial ->
    forall (fexpr : Free Shape Pos (Expr Shape Pos)),
    RecPureExpr fexpr ->
        quickCheck (prop_comp'_correct Shape Pos Partial fexpr).
  Proof.
    simpl.
    intros HUndefined fexpr HPure.
    rewrite <- comp_comp'_eq.
    apply (comp_correct HUndefined fexpr HPure).
  Qed.

End Proofs.