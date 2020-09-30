From Base Require Import Free Prelude Test.QuickCheck.
From Generated Require Import Proofs.AppendAssoc.

Require Import Coq.Logic.FunctionalExtensionality.

(* This lemma can be generated from a QuickCheck property. *)
Lemma append_nil : quickCheck (fun Shape Pos I => @prop_append_nil Shape Pos I Cbn).
Proof.
  intros Shape Pos I a SA NF fxs.
  induction fxs using FreeList_ind with (P := fun xs => append1 Shape Pos a (pure nil) Cbn xs = pure xs); simpl.
  - reflexivity.
  - simpl; repeat apply f_equal. apply IHfxs1.
  - apply IHfxs.
  - repeat apply f_equal. extensionality p. apply H.
Qed.

(* This lemma must be written manually since it involves a helper function that is
   generated during compilation and is not visible to the original Haskell module. *)
Lemma append1_assoc :
  forall (Shape : Type)
         (Pos : Shape -> Type)
        `{Injectable Share.Shape Share.Pos Shape Pos}
         {a : Type}
         `{ShareableArgs Shape Pos a}
         (xs : List Shape Pos a)
         (fys fzs : Free Shape Pos (List Shape Pos a)),
      append1 Shape Pos a (append Shape Pos Cbn fys fzs) Cbn xs
      = append Shape Pos Cbn (append1 Shape Pos a fys Cbn xs) fzs.
Proof.
  intros Shape Pos I a SA xs fys fzs.
  induction xs using List_Ind.
  - reflexivity.
  - induction fxs using Free_Ind.
    + simpl. simplify H as IH. rewrite IH. reflexivity.
    + (*Inductive case: [fxs = impure s pf] with induction hypothesis [H] *)
      simpl. do 3 apply f_equal. extensionality p.
      simplify H as IH. apply IH.
Qed.

(* Now we can prove the actual property. *)
Theorem append_assocs: quickCheck (fun Shape Pos I => @prop_append_assoc Shape Pos I Cbn).
Proof.
  intros Shape Pos I a SA NF fxs fys fzs.
  induction fxs as [ | s pf IH ] using Free_Ind.
  - simpl. apply append1_assoc.
  - (*Inductive case: [fxs = impure s pf] with induction hypothesis [IH] *)
    simpl. apply f_equal. extensionality p.
    apply IH.
Qed.
