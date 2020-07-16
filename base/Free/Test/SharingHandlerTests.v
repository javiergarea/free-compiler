From Base Require Import Free.

From Base Require Import Free.Instance.Comb.
From Base Require Import Free.Instance.Identity.
From Base Require Import Free.Instance.Maybe.
From Base Require Import Free.Instance.ND.
From Base Require Import Free.Instance.Share.
From Base Require Import Free.Instance.Trace.

From Base Require Import Free.Malias.

From Base Require Import Prelude.Bool.
From Base Require Import Prelude.Integer.

From Base Require Import Free.Util.Search.

Require Import Lists.List.
Import List.ListNotations.

(* Synonym for cbneed for better readability. *)
Definition share {A : Type} 
                 {Shape : Type} 
                 {Pos : Shape -> Type}
                 `{i : Injectable Share.Shape Share.Pos Shape Pos} 
                 (x : Free Shape Pos A) 
:= @cbneed A Shape Pos i x.

(* Synonyms for programs containing non-determinism. *)
Definition NDShape := (Comb.Shape Share.Shape (Comb.Shape ND.Shape Identity.Shape)). 
Definition NDPos := (Comb.Pos Share.Pos (Comb.Pos ND.Pos Identity.Pos)).
Definition NDProg (A : Type) := Free NDShape NDPos A.

(* Synonyms for programs containing tracing. *)
Definition TraceShape := (Comb.Shape Share.Shape (Comb.Shape Trace.Shape Identity.Shape)). 
Definition TracePos := (Comb.Pos Share.Pos (Comb.Pos Trace.Pos Identity.Pos)).
Definition TraceProg (A : Type) := Free TraceShape TracePos A.

(* Shortcut to evaluate a non-deterministic program to a result list.
   list. *)
Definition evalND {A : Type} (p : NDProg A) 
:= collectVals (run (runChoice (runNDSharing (0,0) p))).

(* Shortcut to evaluate a traced program to a result and a list of logged 
   messages. *)
Definition evalTracing {A : Type} (p : TraceProg A) 
:= collectMessages (run (runTracing (runTraceSharing (0,0) p))).

(* Non-deterministic integer. *)
Definition coin : NDProg (Integer NDShape NDPos)
:= pure 0%Z ? pure 1%Z.

(* Non-deterministic boolean value. *)
Definition coinB : NDProg (Bool NDShape NDPos)
 := True_ _ _ ? False_ _ _.

(* Traced integer. *)
Definition traceOne : TraceProg (Integer TraceShape TracePos) 
:= trace "One" (pure 1%Z).

(* Traced boolean values. *)
Definition traceTrue : TraceProg (Bool TraceShape TracePos)
:= trace "True" (True_ _ _).
Definition traceFalse : TraceProg (Bool TraceShape TracePos)
:= trace "False" (False_ _ _).

(* ---------------------- Test cases without sharing ----------------------- *)

(* This function applies the given binary function to the given argument
   twice and does not share the argument. *)
Definition double {Shape : Type}
                  {Pos : Shape -> Type}
                  {A : Type}
                  `{Injectable Share.Shape Share.Pos Shape Pos}
                  (f : forall (Shape : Type) (Pos : Shape -> Type),
                       Free Shape Pos A ->
                       Free Shape Pos A -> 
                       Free Shape Pos A)
                  (fx : Free Shape Pos A)
 : Free Shape Pos A
:= f Shape Pos fx fx.

(* 
0?1 + 0?1
= 0+0 ? 0+1 ? 1+0 ? 1+1
= 0 ? 1 ? 1 ? 2
*)
Example exAddNoSharingND : evalND (double addInteger coin) = [0%Z;1%Z;1%Z;2%Z].
Proof. constructor. Qed.

(*
trace "One" 1 + trace "One" 1
=> The message should be logged twice and the result should be 2.
*)
Example exAddNoSharingTrace 
: evalTracing (double addInteger traceOne) 
  = (2%Z,["One"%string;"One"%string]).
Proof. constructor. Qed.

(*
(true ? false) or (true ? false)
= (true or (true ? false)) ? (false or (true ? false))
= true ? (true ? false)
= true ? true ? false
*)
Example exOrNDNoSharing 
 : evalND (double orBool coinB) = [true;true;false].
Proof. constructor. Qed.

(*
(trace "True" true) or (trace "True" true)
=> The second argument is not evaluated, so the result should be true and the 
   message should be logged only once.
*)
Example exOrTrueTracingNoSharing 
 : evalTracing (orBool TraceShape TracePos traceTrue traceTrue) 
   = (true,["True"%string]).
Proof. constructor. Qed.

(*
(trace "False" false) or (trace "False" false)
=> Both arguments are evaluated, so the result should be false and the message
   should be logged twice.
*)
Example exOrFalseTracingNoSharing 
 : evalTracing (orBool TraceShape TracePos traceFalse traceFalse) 
   = (false,["False"%string;"False"%string]).
Proof. constructor. Qed.

(*
(trace "False" false) or (trace "True" false)
=> Both arguments are evaluated, so the result should be true and both messages
   should be logged.
*)
Example exOrMixedTracingNoSharing
 : evalTracing (orBool TraceShape TracePos traceFalse traceTrue) 
   = (true,["False"%string;"True"%string]).
Proof. constructor. Qed.


(* --------------------- Test cases for simple sharing --------------------- *)

(* let sx = fx in f sx sx *)
Definition doubleShared {Shape : Type}
                        {Pos : Shape -> Type}
                        {A : Type}
                        `{Injectable Share.Shape Share.Pos Shape Pos}
                        (f : forall (Shape : Type) (Pos : Shape -> Type),
                             Free Shape Pos A ->
                             Free Shape Pos A -> 
                             Free Shape Pos A)
                        (fx : Free Shape Pos A)
 : Free Shape Pos A
:= share fx >>= fun sx => f Shape Pos sx sx.

(*
let sx = 0 ? 1 
in sx + sx 
= 0+0 ? 1+1
= 0 ? 2
*)
Example exAddSharingND : evalND (doubleShared addInteger coin) = [0%Z;2%Z].
Proof. constructor. Qed.

(*
let sx = trace "One" 1
in sx + sx
=> The message should be logged once and the result should be 2.
*)
Example exAddSharingTrace 
 : evalTracing (doubleShared addInteger traceOne) = (2%Z,["One"%string]).
Proof. constructor. Qed.

(*
let sx = true ? false
in sx or sx
= (true or true) ? (false or false)
= true ? false
*)
Example exOrNDSharing
 : evalND (doubleShared orBool coinB) = [true;false].
Proof. constructor. Qed.

(*
let sx = trace "True" true
in sx or sx 
=> The second argument is not evaluated, so sharing makes no difference here.
   The message should be logged once and the result should be true.
*)
Example exOrTrueTraceSharing
 : evalTracing (doubleShared orBool traceTrue) = (true,["True"%string]).
Proof. constructor. Qed.

(*
let sx = trace "False" true
in sx or sx
=> Both arguments are evaluated, but sx is shared, so the message should
only be logged once and the result should be false.
*)
Example exOrFalseTraceSharing
 : evalTracing (doubleShared orBool traceFalse) = (false,["False"%string]).
Proof. constructor. Qed.

(* traceFalse is shared, but does not occur more than once. 
   Therefore, sharing should make no difference here. *)
Example exOrMixedTraceSharing
 : evalTracing (share traceFalse >>= fun sx => 
                orBool TraceShape TracePos sx traceTrue)
   = (true,["False"%string;"True"%string]).
Proof. constructor. Qed.

(* --------------------- Test cases for nested sharing --------------------- *)

(* let sx = fx 
       sy = f sx sx
   in f sy sy *)
Definition doubleSharedNested {Shape : Type}
                              {Pos : Shape -> Type}
                              {A : Type}
                              `{Injectable Share.Shape Share.Pos Shape Pos}
                             (f : forall (Shape : Type) (Pos : Shape -> Type),
                                  Free Shape Pos A ->
                                  Free Shape Pos A -> 
                                  Free Shape Pos A)
                                  (fx : Free Shape Pos A)
 : Free Shape Pos A
:= share (share fx >>= fun sx => f Shape Pos sx sx) >>= fun sy =>
   f Shape Pos sy sy.

(* 
let sx = 0 ? 1 
    sy = sx + sx 
in sy + sy 
= (0+0)+(0+0) ? (1+1)+(1+1) 
= 0 ? 4 
*)
Example exAddNestedSharingND : evalND (doubleSharedNested addInteger coin) 
                            = [0%Z;4%Z].
Proof. constructor. Qed.

(* 
let sx = trace "One" 1
    sy = sx + sx 
in sy + sy 
=> The message should only be logged once and the result should be 4. 
*)
Example exAddNestedSharingTrace 
 : evalTracing (doubleSharedNested addInteger traceOne) 
   = (4%Z,["One"%string]).
Proof. constructor. Qed.

(*
let sx = true ? false
    sy = sx or sx
in sy or sy
= true ? false
*)
Example exOrNestedSharingND
 : evalND (doubleSharedNested orBool coinB)
   = [true;false].
Proof. constructor. Qed.

(*
let sx = trace "True" true
    sy = sx or sx
in sy or sy
=> The message should only be logged once due to non-strictness
   and the result should be true.
*)
Example exOrNestedTrueTracing 
 : evalTracing (doubleSharedNested orBool traceTrue)
   = (true,["True"%string]).
Proof. constructor. Qed.

(*
let sx = trace "True" true
    sy = sx or sx
in sy or sy
=> The message should only be logged once due to sharing
   and the result should be false.
*)
Example exOrNestedFalseTracing
 : evalTracing (doubleSharedNested orBool traceFalse)
   = (false, ["False"%string]).
Proof. constructor. Qed.

(* let sx = fx  
       sy = f sx sx
       sz = fy
   in f sy sz *)
Definition doubleSharedClash {Shape : Type}
                             {Pos : Shape -> Type}
                             {A : Type}
                             `{Injectable Share.Shape Share.Pos Shape Pos}
                             (f : forall (Shape : Type) (Pos : Shape -> Type),
                                  Free Shape Pos A ->
                                  Free Shape Pos A -> 
                                  Free Shape Pos A)
                             (fx : Free Shape Pos A)
                             (fy : Free Shape Pos A)
 : Free Shape Pos A
:= share (share fx >>= fun sx => f Shape Pos sx sx) >>= fun sy =>
   share fy >>=  fun sz => f Shape Pos sy sz.

(* 
let sx = 0 ? 1
    sy = sx + sx
    sz = 0 ? 1
in sy + sz
= ((0 + 0) ? (1 + 1)) + (0 ? 1)
= (0 ? 1) + (0 ? 1)
= 0+0 ? 0+1 ? 1+0 ? 1+1
= 0 ? 1 ? 2 ? 3
*)
Example exAddClashSharingND
 : evalND (doubleSharedClash addInteger coin coin) = [0%Z;1%Z;2%Z;3%Z].
Proof. constructor. Qed.

(*
let sx = trace "One" 1
    sy = sx + sx
    sz = trace "One" 1
in sy + sz
=> The message should be logged twice and the result should be 3.
*)
Example exAddClashSharingTracing
 : evalTracing (doubleSharedClash addInteger traceOne traceOne) 
   = (3%Z,["One"%string;"One"%string]).
Proof. constructor. Qed.

(*
let sx = true ? false
    sy = sx or sx
    sz = true ? false
in sy or sz
= ((true or true) or (true ? false)) ? ((false or false) or (true ? false))
= true ? (true ? false)
= true ? true ? false
*)
Example exOrClashSharingND
 : evalND (doubleSharedClash orBool coinB coinB)
   = [true;true;false].
Proof. constructor. Qed.

(*
let sx = trace "True" true
    sy = sx or sx
    sz = trace "True" true
in sy or sz
=> The message should only be logged once due to non-strictness and the 
   result should be true.
*)
Example exOrClashTrueTracing
 : evalTracing (doubleSharedClash orBool traceTrue traceTrue)
   = (true,["True"%string]).
Proof. constructor. Qed.

(*
let sx = trace "False" false
    sy = sx or sx
    sz = trace "False" false
in sy or sz
=> sx is shared, so evaluating sy should only log one message.
   Evaluating sz should log the message once more, so it should
   be logged twice in total and the result should be false.
*)
Example exOrClashFalseTracing
 : evalTracing (doubleSharedClash orBool traceFalse traceFalse)
   = (false,["False"%string;"False"%string]).
Proof. constructor. Qed.

(*
let sx = val
    sy = f sx fx
    sz = f sy fy
in f sx (f (sy (f sz val))) 
*)
Definition doubleSharedRec {Shape : Type}
                           {Pos : Shape -> Type}
                           {A : Type}
                           `{Injectable Share.Shape Share.Pos Shape Pos}
                           (f : forall (Shape : Type) (Pos : Shape -> Type),
                                Free Shape Pos A ->
                                Free Shape Pos A -> 
                                Free Shape Pos A)
                           (fx : Free Shape Pos A)
                           (fy : Free Shape Pos A)
                           (val : A)
 : Free Shape Pos A
:= share (pure val) >>= fun sx =>
   f Shape Pos sx (share (f Shape Pos sx fx) >>= fun sy => 
      f Shape Pos sy (share (f Shape Pos sy fy) >>= fun sz =>
        f Shape Pos sz (pure val)
      )
   ).

(*
let sx = 1
    sy = sx + (0 ? 1)
    sz = sy + (0 ? 1)
in sx + (sy + (sz + 1))
= (1 + (1+0 + ((1+0 + (0 ? 1)) + 1))) ? (1 + (1+1 + ((1+1 + (0 ? 1)) + 1)))
= (1 + (1+0 + ((1+0 + 0) + 1)))
  ? (1 + (1+0 + ((1+0 + 1) + 1)))
  ? (1 + (1+1 + ((1+1 + 0) + 1)))
  ? (1 + (1+1 + ((1+1 + 1) + 1)))
= 4 ? 5 ? 6 ? 7
*)
Example exAddRecSharingND : evalND (doubleSharedRec addInteger coin coin 1%Z) 
                         = [4%Z;5%Z;6%Z;7%Z].
Proof. constructor. Qed.

(*
let sx = 1
    sy = sx + trace "One" 1
    sz = sy + trace "One" 1
in sx + (sy + (sz + 1))
=> The message should be logged once for sy and once for sz, so it should be 
   logged twice in total. 
   sx has the value 1, sy has the value 2 and sz has the value 3, so the 
   final value should be 1 + 2 + 3 + 1 = 7.
*)
Example exAddRecSharingTracing
 : evalTracing (doubleSharedRec addInteger traceOne traceOne 1%Z) 
   = (7%Z,["One"%string;"One"%string]).
Proof. constructor. Qed.

(*
let sx = true
    sy = sx or (true ? false)
    sz = sy or (true ? false)
in sx or (sy or (sz or true))
= true (due to non-strictness)
*)
Example exOrRecSharingNDTrue
 : evalND (doubleSharedRec orBool coinB coinB true)
   = [true].
Proof. constructor. Qed.

(*
let sx = false
    sy = sx or (true ? false)
    sz = sy or (true ? false)
in sx or (sy or (sz or false))
= false or ((false or true) or ((true or (true ? false)) or false)) ?
  false or ((false or false) or ((false or (true ? false)) or false))
= (false or true) or ((true or (true ? false)) or false) ?
  (false or false) or ((false or (true ? false)) or false)
= true ? 
  (false or (true ? false)) or false
= true ? 
  (true ? false) or false
= true ?
  true or false ?
  false or false
= true ? true ? false
*)
Example exOrRecSharingNDFalse
 : evalND (doubleSharedRec orBool coinB coinB false)
   = [true;true;false].
Proof. constructor. Qed.

(* 
let sx = false
    sy = sx or (trace "True" true)
    sz = sy or (trace "True" true)
in sx or (sy or (sz or false))
=> sy has the value true, so sz is not evaluated. The message should only 
   be logged once and the result should be true.
*)
Example exOrRecTrueTracing
 : evalTracing (doubleSharedRec orBool traceTrue traceTrue false)
   = (true,["True"%string]).
Proof. constructor. Qed.

(*
let sx = false
    sy = sx or (trace "False" false)
    sz = sy or (trace "False" false)
in sx or (sy or (sz or false))
=> sy is shared, so its message should only be logged once. Additionally,
   the message is logged once more when sz is evaluated. The result should
   be false.
*)
Example exOrRecFalseTracing
 : evalTracing (doubleSharedRec orBool traceFalse traceFalse false)
   = (false,["False"%string;"False"%string]).
Proof. constructor. Qed.
