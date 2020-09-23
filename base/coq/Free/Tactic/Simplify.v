From Base Require Import Free.ForFree.
From Base Require Import Free.Monad.

Require Import Coq.Program.Equality.

Ltac simplifyInductionHypothesis ident1 ident2 :=
  match type of ident1 with
  | ForFree ?Shape ?Pos ?A ?P (pure _) =>
    inversion ident1 as [ Heq ident2 |]; clear ident1; subst
  | ForFree ?Shape ?Pos ?A ?P (impure ?s ?pf) =>
    dependent destruction ident1;
    match goal with
    | [ H1 : forall p, ForFree ?Shape ?Pos ?A ?P (?pf p), H0 : forall p, ForFree ?Shape ?Pos ?A _ (?pf p) -> _ = _ |- _ ] =>
      injection (H0 p (H1 p)) as IH; clear H1; clear H0
    end
  end.

Tactic Notation "simplify" ident(H) "as" ident(IH) := (simplifyInductionHypothesis H IH).
