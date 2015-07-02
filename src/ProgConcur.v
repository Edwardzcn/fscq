Require Import Mem.
Require Import Prog.
Require Import Word.
Require Import Hoare.
Require Import Pred.
Require Import RG.
Require Import Arith.
Require Import SepAuto.
Require Import List.

Import ListNotations.

Set Implicit Arguments.


Section STAR.

  Variable state : Type.
  Variable prog : Type.
  Variable step : state -> prog -> state -> prog -> Prop.

  Inductive star : state -> prog -> state -> prog -> Prop :=
  | star_refl : forall s p,
    star s p s p
  | star_step : forall s1 s2 s3 p1 p2 p3,
    step s1 p1 s2 p2 ->
    star s2 p2 s3 p3 ->
    star s1 p1 s3 p3.

  Lemma star_trans : forall s0 p0 s1 p1 s2 p2,
    star s0 p0 s1 p1 ->
    star s1 p1 s2 p2 ->
    star s0 p0 s2 p2.
  Proof.
    induction 1; eauto.
    intros.
    eapply star_step; eauto.
  Qed.

End STAR.

Lemma star_impl :
  forall state prog s0 p0 s1 p1 (step1 step2 : state -> prog -> state -> prog -> Prop),
  (forall s p s' p', step1 s p s' p' -> step2 s p s' p') ->
  star step1 s0 p0 s1 p1 ->
  star step2 s0 p0 s1 p1.
Proof.
  intros.
  induction H0.
  - constructor.
  - econstructor; eauto.
Qed.


Section ExecConcur.

  Inductive threadstate :=
  | TNone
  | TRunning (p : prog nat)
  | TFinished (r : nat)
  | TFailed.

  Definition threadstates := forall (tid : nat), threadstate.
  Definition results := forall (tid : nat), nat.

  Definition upd_prog (ap : threadstates) (tid : nat) (p : threadstate) :=
    fun tid' => if eq_nat_dec tid' tid then p else ap tid'.

  Lemma upd_prog_eq : forall ap tid p, upd_prog ap tid p tid = p.
  Proof.
    unfold upd_prog; intros; destruct (eq_nat_dec tid tid); congruence.
  Qed.

  Lemma upd_prog_ne : forall ap tid p tid', tid <> tid' -> upd_prog ap tid p tid' = ap tid'.
  Proof.
    unfold upd_prog; intros; destruct (eq_nat_dec tid' tid); congruence.
  Qed.

  Inductive cstep : nat -> mem -> threadstates -> mem -> threadstates -> Prop :=
  | cstep_step : forall tid ts m (p : prog nat) m' p',
    ts tid = TRunning p ->
    step m p m' p' ->
    cstep tid m ts m' (upd_prog ts tid (TRunning p'))
  | cstep_fail : forall tid ts m (p : prog nat),
    ts tid = TRunning p ->
    (~exists m' p', step m p m' p') -> (~exists r, p = Done r) ->
    cstep tid m ts m (upd_prog ts tid TFailed)
  | cstep_done : forall tid ts m (r : nat),
    ts tid = TRunning (Done r) ->
    cstep tid m ts m (upd_prog ts tid (TFinished r)).

  (**
   * The first argument of [cstep] is the PID that caused the step.
   * If we want to use [star], we should probably use [cstep_any].
   *)

  Definition cstep_any m ts m' ts' := exists tid, cstep tid m ts m' ts'.
  Definition cstep_except tid m ts m' ts' := exists tid', tid' <> tid /\ cstep tid' m ts m' ts'.

  Definition ccorr2 (pre : forall (done : donecond nat),
                           forall (rely : @action addr (@weq addrlen) valuset),
                           forall (guarantee : @action addr (@weq addrlen) valuset),
                           @pred addr (@weq addrlen) valuset)
                    (p : prog nat) : Prop :=
    forall tid done rely guarantee m ts,
    ts tid = TRunning p ->
    pre done rely guarantee m ->
    (forall m' ts', star cstep_any m ts m' ts' ->
     forall tid'' m'' ts'', tid'' <> tid ->
     cstep tid'' m' ts' m'' ts'' -> rely m' m'') ->
    forall m' ts', star cstep_any m ts m' ts' ->
    forall m'' ts'', cstep tid m' ts' m'' ts'' ->
    (guarantee m' m'' /\ ts'' tid <> TFailed /\ (forall r, ts'' tid = TFinished r -> done r m'')).

  Inductive coutcome :=
  | CFailed
  | CFinished (m : @mem addr (@weq addrlen) valuset) (rs : results).

  Inductive cexec : mem -> threadstates -> coutcome -> Prop :=
  | CStep : forall tid ts m m' (p : prog nat) p' out,
    ts tid = TRunning p ->
    step m p m' p' ->
    cexec m' (upd_prog ts tid (TRunning p')) out ->
    cexec m ts out
  | CFail : forall tid ts m (p : prog nat),
    ts tid = TRunning p ->
    (~exists m' p', step m p m' p') -> (~exists r, p = Done r) ->
    cexec m ts CFailed
  | CDone : forall ts m (rs : results),
    (forall tid r, ts tid = TRunning (Done r) -> rs tid = r) ->
    cexec m ts (CFinished m rs).

End ExecConcur.


Section ExecConcur2.

  Inductive c2prog : Type -> Type :=
  | C2Prog : forall (T : Type) (p : prog T), c2prog T
  | C2Par : forall (T1 T2 : Type) (cp1 : c2prog T1) (cp2 : c2prog T2), c2prog (T1 * T2)%type
  | C2Fail : forall (T : Type), c2prog T
  | C2Done : forall (T : Type) (r : T), c2prog T.

  Inductive c2step : forall T, @mem addr (@weq addrlen) valuset -> c2prog T ->
                               @mem addr (@weq addrlen) valuset -> c2prog T -> Prop :=
  | c2step_step : forall T (p p' : prog T) m m',
    step m p m' p' ->
    @c2step T m (C2Prog p) m' (C2Prog p')

  | c2step_fail : forall T (p : prog T) m,
    (~exists m' p', step m p m' p') -> (~exists r, p = Done r) ->
    @c2step T m (C2Prog p) m (C2Fail T)

  | c2step_done : forall T (r : T) m,
    @c2step T m (C2Prog (Done r)) m (C2Done r)

  | c2step_par_ok_l : forall T1 T2 (p1 p1' : c2prog T1) (p2 : c2prog T2) m m',
    @c2step T1 m p1 m' p1' ->
    @c2step (T1 * T2)%type m (C2Par p1 p2) m' (C2Par p1' p2)
  | c2step_par_ok_r : forall T1 T2 (p1 : c2prog T1) (p2 p2' : c2prog T2) m m',
    @c2step T2 m p2 m' p2' ->
    @c2step (T1 * T2)%type m (C2Par p1 p2) m' (C2Par p1 p2')

  | c2step_par_fail_l : forall T1 T2 (p2 : c2prog T2) m,
    @c2step (T1 * T2)%type m (C2Par (C2Fail T1) p2) m (C2Fail (T1 * T2)%type)
  | c2step_par_fail_r : forall T1 T2 (p1 : c2prog T1) m,
    @c2step (T1 * T2)%type m (C2Par p1 (C2Fail T2)) m (C2Fail (T1 * T2)%type)

  | c2step_par_done : forall T1 T2 (r1 : T1) (r2 : T2) m,
    @c2step (T1 * T2)%type m (C2Par (C2Done r1) (C2Done r2)) m (C2Done (r1, r2)).

  Inductive c2outcome (T : Type) :=
  | C2Failed
  | C2Finished (m : @mem addr (@weq addrlen) valuset) (r : T).

  Inductive c2exec (T : Type) : mem -> c2prog T -> c2outcome T -> Prop :=
  | C2XStep : forall p p' m m' out,
    @c2step T m p m' p' ->
    c2exec m' p' out ->
    c2exec m p out
  | C2XFail : forall p m m',
    @c2step T m p m' (C2Fail T) ->
    c2exec m p (C2Failed T)
  | C2XDone : forall m r,
    c2exec m (C2Done r) (C2Finished m r).

End ExecConcur2.


Notation "{C pre C} p" := (ccorr2 pre%pred p) (at level 0, p at level 60, format
  "'[' '{C' '//' '['   pre ']' '//' 'C}'  p ']'").

Ltac inv_cstep :=
  match goal with
  | [ H: cstep _ _ _ _ _ |- _ ] => inversion H; clear H; subst
  end.

Ltac inv_step :=
  match goal with
  | [ H: step _ _ _ _ |- _ ] => inversion H; clear H; subst
  end.

Ltac inv_ts :=
  match goal with
  | [ H: TRunning _ = TRunning _ |- _ ] => inversion H; clear H; subst
  end.

Lemma star_cstep_tid : forall m ts m' ts' tid,
  star cstep_any m ts m' ts' ->
  (star (cstep_except tid) m ts m' ts') \/
  (exists m0 ts0 m1 ts1,
   star (cstep_except tid) m ts m0 ts0 /\
   cstep tid m0 ts0 m1 ts1 /\
   star cstep_any m1 ts1 m' ts').
Proof.
  induction 1.
  - left. constructor.
  - unfold cstep_any in H. destruct H as [tid' H].
    destruct (eq_nat_dec tid' tid); subst.
    + right. exists s1. exists p1. do 2 eexists.
      split; [ constructor | ].
      split; [ eauto | ].
      eauto.
    + intuition.
      * left. econstructor.
        unfold cstep_except; eauto.
        eauto.
      * repeat deex.
        right.
        do 4 eexists.
        intuition eauto.
        econstructor.
        unfold cstep_except; eauto.
        eauto.
Qed.

Lemma star_cstep_except_ts : forall m ts m' ts' tid,
  star (cstep_except tid) m ts m' ts' ->
  ts tid = ts' tid.
Proof.
  induction 1; eauto.
  rewrite <- IHstar.
  inversion H. destruct H1.
  inversion H2; rewrite upd_prog_ne in * by auto; congruence.
Qed.

Lemma cstep_except_cstep_any : forall m ts m' ts' tid,
  cstep_except tid m ts m' ts' ->
  cstep_any m ts m' ts'.
Proof.
  firstorder.
Qed.

Theorem write_cok : forall a vnew rx,
  {C
    fun done rely guarantee =>
    exists F v0 vrest,
    F * a |-> (v0, vrest) *
    [[ forall F0 F1 v, rely =a=> (F0 * a |-> v ~> F1 * a |-> v) ]] *
    [[ forall F x y, (F * a |-> x ~> F * a |-> y) =a=> guarantee ]] *
    [[ {C
         fun done_rx rely_rx guarantee_rx =>
         exists F', F' * a |-> (vnew, [v0] ++ vrest) *
         [[ done_rx = done ]] *
         [[ rely =a=> rely_rx ]] *
         [[ guarantee_rx =a=> guarantee ]]
       C} rx tt ]]
  C} Write a vnew rx.
Proof.
  unfold ccorr2; intros.
  destruct_lift H0.
  apply star_cstep_tid with (tid := tid) in H2. destruct H2.
  - (* No steps by [tid] up to this point. *)
    assert ((exists F', F' * a |-> (v1, vrest))%pred m) by ( pred_apply; cancel ).
    clear H0.

    assert ((exists F', F' * a |-> (v1, vrest))%pred m').
    {
      clear H6 H.
      induction H2; [ pred_apply; cancel | ].
      unfold cstep_except in *; deex.
      eapply IHstar; eauto; intros.
      eapply H1; [ | | eauto ]; eauto.
      econstructor; eauto. unfold cstep_any in *; intros. eauto.
      eapply H8 in H1; [ | econstructor | eauto | eauto ].
      destruct H1.
      pred_apply; cancel.
    }
    clear H4.
    destruct_lift H0.

    assert (ts tid = ts' tid) by ( eapply star_cstep_except_ts; eauto ).
    rewrite H4 in H; clear H4.

    inv_cstep.
    + (* cstep_step *)
      rewrite H in *. inv_ts.
      inv_step.
      intuition.
      * eapply H7.
        unfold act_bow. intuition.
        ** pred_apply; cancel.
        ** apply sep_star_comm. eapply ptsto_upd. pred_apply; cancel.
      * rewrite upd_prog_eq in *; congruence.
      * rewrite upd_prog_eq in *; congruence.
    + (* cstep_fail *)
      rewrite H in *. inv_ts.
      exfalso. apply H5. do 2 eexists.
      constructor.
      apply sep_star_comm in H0. apply ptsto_valid in H0. eauto.
    + (* cstep_done *)
      congruence.

  - (* [tid] made a step. *)
    destruct H2. destruct H2. destruct H2. destruct H2. destruct H2. destruct H4.
    assert (ts tid = x0 tid) by ( eapply star_cstep_except_ts; eauto ).
    rewrite H9 in H; clear H9.

    assert ((exists F', F' * a |-> (v1, vrest))%pred m) by ( pred_apply; cancel ).
    clear H0.

    assert ((exists F', F' * a |-> (v1, vrest))%pred x).
    {
      clear H6 H.
      induction H2; [ pred_apply; cancel | ].
      unfold cstep_except in *; deex.
      eapply IHstar; eauto; intros.
      eapply H1; [ | | eauto ]; eauto.
      econstructor; eauto. unfold cstep_any in *; intros. eauto.
      eapply H8 in H1; [ | econstructor | eauto | eauto ].
      destruct H1.
      pred_apply; cancel.
    }
    clear H9.
    destruct_lift H0.

    inversion H4.
    + (* cstep_step *)
      rewrite H in *. inv_ts.
      inv_step.
      apply ptsto_valid' in H0 as H0'. rewrite H0' in H16. inversion H16; subst; clear H16.
      eapply H6 with (ts := upd_prog x0 tid (TRunning (rx tt))); eauto.
      { rewrite upd_prog_eq; eauto. }
      {
        eapply pimpl_trans; [ cancel | | ].
        2: eapply ptsto_upd; pred_apply; cancel.
        cancel.
      }
      {
        intros.
        eapply H8.
        eapply H1; eauto.

        eapply star_trans.
        eapply star_impl. intros; eapply cstep_except_cstep_any; eauto.
        eauto.
        econstructor.
        unfold cstep_any; eauto.
        eauto.
      }
    + (* cstep_fail *)
      rewrite H in *. inv_ts.
      exfalso. apply H10. do 2 eexists.
      constructor.
      apply sep_star_comm in H0. apply ptsto_valid in H0. eauto.
    + (* cstep_done *)
      congruence.

  Grab Existential Variables.
  all: eauto.
Qed.

Theorem pimpl_cok : forall pre pre' (p : prog nat),
  {C pre' C} p ->
  (forall done rely guarantee, pre done rely guarantee =p=> pre' done rely guarantee) ->
  {C pre C} p.
Proof.
  unfold ccorr2; intros.
  eapply H; eauto.
  eapply H0.
  eauto.
Qed.

Definition write2 a b va vb (rx : prog nat) :=
  Write a va;;
  Write b vb;;
  rx.

Theorem write2_cok : forall a b vanew vbnew rx,
  {C
    fun done rely guarantee =>
    exists F va0 varest vb0 vbrest,
    F * a |-> (va0, varest) * b |-> (vb0, vbrest) *
    [[ forall F0 F1 va vb, rely =a=> (F0 * a |-> va * b |-> vb ~>
                                      F1 * a |-> va * b |-> vb) ]] *
    [[ forall F va va' vb vb', (F * a |-> va  * b |-> vb ~>
                                F * a |-> va' * b |-> vb') =a=> guarantee ]] *
    [[ {C
         fun done_rx rely_rx guarantee_rx =>
         exists F', F' * a |-> (vanew, [va0] ++ varest) * b |-> (vbnew, [vb0] ++ vbrest) *
         [[ done_rx = done ]] *
         [[ rely =a=> rely_rx ]] *
         [[ guarantee_rx =a=> guarantee ]]
       C} rx ]]
  C} write2 a b vanew vbnew rx.
Proof.
  unfold write2; intros.

  eapply pimpl_cok. apply write_cok.
  intros. cancel.

  eapply act_impl_trans; [ eapply H3 | ].
  (* XXX need some kind of [cancel] for actions.. *)
  admit.

  eapply act_impl_trans; [ | eapply H2 ].
  (* XXX need some kind of [cancel] for actions.. *)
  admit.

  eapply pimpl_cok. apply write_cok.
  intros; cancel.

  (* XXX hmm, the [write_cok] spec is too weak: it changes [F] in the precondition
   * with [F'] in the postcondition, and thus loses all information about blocks
   * other than the one being written to.  but really we should be using [rely].
   * how to elegantly specify this in separation logic?
   *)
  admit.

  (* XXX H5 seems backwards... *)
  admit.

  (* XXX H4 seems backwards... *)
  admit.

  eapply pimpl_cok. eauto.
  intros; cancel.

  (* XXX some other issue with losing information in [write_cok]'s [F] vs [F'].. *)
  admit.

  eapply act_impl_trans; eassumption.
  eapply act_impl_trans; eassumption.
Admitted.
