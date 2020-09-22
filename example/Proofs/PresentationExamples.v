From Base Require Import Free Handlers.
From Base Require Import Free.Instance.Trace.
From Base Require Import Free.Instance.Maybe.
From Base Require Import Free.Instance.Comb.
From Base Require Import Prelude.
From Generated Require Import Data.List.

(* [undefined] *)
Definition ex_1 (Shape : Type) (Pos : Shape -> Type)
                (P : Partial Shape Pos)
  : Free Shape Pos (List Shape Pos (Unit Shape Pos))
 := Cons Shape Pos undefined (Nil Shape Pos).

Definition ex_2 (Shape : Type) (Pos : Shape -> Type)
                (P : Partial Shape Pos)
  : Free Shape Pos (List Shape Pos (Unit Shape Pos))
 := undefined.

Definition SMaybe := Comb.Shape Maybe.Shape Identity.Shape.
Definition PMaybe := Comb.Pos Maybe.Pos Identity.Pos.

(* [undefined] != undefined in a partial setting. *)
Lemma ex_1_neq_ex_2 : 
  ex_1 SMaybe PMaybe (Maybe.Partial SMaybe PMaybe) 
  <> 
  ex_2 SMaybe PMaybe (Maybe.Partial SMaybe PMaybe).
Proof. discriminate. Qed.

(* For completeness' sake: length [undefined] != length undefined. *)
Lemma length_ex_1_neq_length_ex2 : 
  length SMaybe PMaybe (ex_1 SMaybe PMaybe (Maybe.Partial SMaybe PMaybe))
  <>
  length SMaybe PMaybe (ex_2 SMaybe PMaybe (Maybe.Partial SMaybe PMaybe)).
Proof. discriminate. Qed.

(* handle [undefined] = handle undefined in the same setting
   using the appropriate handler. *)
Lemma handle_ex_1_eq_handle_ex_2 :
  @handle SMaybe PMaybe _ (HandlerMaybe _)
    (ex_1 SMaybe PMaybe (Maybe.Partial SMaybe PMaybe))
  = 
  @handle SMaybe PMaybe _ (HandlerMaybe _) 
    (ex_2 SMaybe PMaybe (Maybe.Partial SMaybe PMaybe)).
Proof.
(* Equation is reduced to None = None *)
simpl. reflexivity. Qed.

(* But handle (length [undefined]) != handle (length undefined) using
   the same setting and handler. *)
Lemma length_handle_ex_1_new_length_handle_ex2 :
  @handle SMaybe PMaybe _ (HandlerMaybe _)
    (length SMaybe PMaybe (ex_1 SMaybe PMaybe (Maybe.Partial SMaybe PMaybe)))
  <>
  @handle SMaybe PMaybe _ (HandlerMaybe _)
    (length SMaybe PMaybe (ex_2 SMaybe PMaybe (Maybe.Partial SMaybe PMaybe))).
(* Equation is reduced to Some 1 <> None. *)
Proof. simpl. discriminate. Qed.