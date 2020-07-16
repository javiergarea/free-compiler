(** * Definition of the tracing effect in terms of the free monad. *)

From Base Require Import Free.
From Base Require Import Free.Instance.Comb.
From Base Require Import Free.Instance.Share.
From Base Require Import Free.Util.Sharing.
From Base Require Import Free.Util.Void.
Require Export Coq.Strings.String.

Module Trace.

  (* Container instance for a functor [Log]. *)
  Definition Shape : Type := option ID * string.
  Definition Pos : Shape -> Type := fun _ => unit.

  (* Type synonym and smart constructors for the tracing effect. *)
  Module Import Monad.
    Definition Trace (A : Type) : Type := Free Shape Pos A.
    Definition Nil {A : Type} 
                   (Shape' : Type) 
                   (Pos' : Shape' -> Type)
                   `{Injectable Shape Pos Shape' Pos'} 
                   (x : A) 
      : Free Shape' Pos' A := pure x.
    Definition LCons {A : Type} 
                     (Shape' : Type) 
                     (Pos' : Shape' -> Type)
                     `{Injectable Shape Pos Shape' Pos'} 
                     (mid : option ID) 
                     (msg : string) 
                     (x : Free Shape' Pos' A)
      : Free Shape' Pos' A :=
      impure (injS (mid, msg)) (fun tt => x).

  End Monad.
  (* Handlers for tracing and sharing combined with tracing. *)
  Module Import Handler.
    (* Helper definitions and handler for the tracing effect. *)
    Definition STrace (Shape' : Type) := Comb.Shape Shape Shape'.
    Definition PTrace {Shape' : Type} (Pos' : Shape' -> Type) 
      := Comb.Pos Trace.Pos Pos'.

    Fixpoint runTracing {A : Type} 
                        {Shape' : Type} 
                        {Pos' : Shape' -> Type} 
                        (fm : Free (STrace Shape') (PTrace Pos') A) 
     : Free Shape' Pos' (A * list (option ID * string))
    := match fm with 
       | pure x => pure (x,nil)
       | impure (inl s) pf => 
         runTracing (pf tt) >>= fun pair => match pair with
                                            | (x,msgs) => pure (x,cons s msgs) 
                                            end
       | impure (inr s) pf => impure s (fun p => runTracing (pf p))
       end.

    (* Helper definitions and handler for sharing combined with tracing. *)
    Definition STrcShare (Shape' : Type) 
    := Comb.Shape Share.Shape (STrace Shape').
    Definition PTrcShare {Shape' : Type} (Pos' : Shape' -> Type)
    := Comb.Pos Share.Pos (PTrace Pos').

    Fixpoint runTraceSharing {A : Type}
                             {Shape' : Type}
                             {Pos' : Shape' -> Type} 
                             (n : nat * nat)
                             (fs : Free (STrcShare Shape') (PTrcShare Pos') A)
     : Free (STrace Shape') (PTrace Pos') A 
    := let fix nameMessages (next : nat) 
                            (scope : nat * nat)
                            (scopes : list (nat * nat))
                            (fs : Free (STrcShare Shape') (PTrcShare Pos') A)
        : Free (STrace Shape') (PTrace Pos') A 
       := match fs with (* inside scope handler *)
          | pure x => pure x
          | impure (inl (Share.sbsharing n')) pf =>
            nameMessages 1 n' (cons n' scopes) (pf tt)
          | impure (inl (Share.sesharing n')) pf =>
            match scopes with
            | cons _ (cons j js) as ks => nameMessages next j ks (pf tt)
            | _                        => runTraceSharing scope (pf tt)
            end
          | impure (inl Share.sget) pf           =>
            nameMessages next scope scopes (pf n)
          | impure (inl (Share.sput n')) pf      =>
            nameMessages next n' scopes (pf tt)
          | impure (inr (inl (_,msg))) pf        =>
            let x := nameMessages (next + 1) scope scopes (pf tt) in
            LCons (STrace Shape') (PTrace Pos') (Some (tripl scope next)) msg x
          | impure (inr (inr s)) pf              =>
            impure (inr s) (fun p => nameMessages next scope scopes (pf p)) 
          end
       in match fs with (* outside scope handler *)
          | pure x => pure x
          | impure (inl (Share.sbsharing n'))  pf =>
            nameMessages 1 n' (cons n' nil) (pf tt)
          | impure (inl (Share.sesharing n'))  pf =>
            runTraceSharing n' (pf tt) (* error *)
          | impure (inl Share.sget) pf            =>
            runTraceSharing n (pf n)
          | impure (inl (Share.sput n')) pf       =>
            runTraceSharing n' (pf tt)
          | impure (inr s) pf                     =>
            impure s (fun p => runTraceSharing n (pf p))
          end.
       End Handler.

  (* Traceable instance for the Trace effect. *)
  Instance Trace (Shape' : Type) (Pos' : Shape' -> Type)
                 `{I: Injectable Shape Pos Shape' Pos'}
   : Traceable Shape' Pos' := {
     trace A msg p := @LCons A Shape' Pos' I None msg p
  }.
  (* There is no Partial instance. *)
End Trace.

(* The type, smart constructors, tracing function and handlers should be
   visible to other modules but to use the shape or position function the
   identifier must be fully qualified, i.e. [Trace.Shape]. *)
Export Trace.Handler.
Export Trace.Monad.
