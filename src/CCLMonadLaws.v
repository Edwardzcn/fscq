Require Import CCLProg.

Import CCLTactics.

Section MonadLaws.

  Variable G:Protocol.

  Definition exec_equiv T (p p': cprog T) :=
    forall tid st out, exec G tid st p out <-> exec G tid st p' out.

  Hint Constructors exec.
  Hint Resolve ExecRet.

  Theorem monad_right_id : forall T (p: cprog T),
      exec_equiv (Bind p Ret) p.
  Proof.
    split; intros.
    - inv_bind; eauto.
      inv_ret; eauto.
    - destruct out, st; eauto.
  Qed.

  Theorem monad_left_id : forall T T' (p: T -> cprog T') v,
      exec_equiv (Bind (Ret v) p) (p v).
  Proof.
    split; intros.
    - inv_bind.
      inv_ret; eauto.
      inv_ret.
    - destruct out, st; eauto.
  Qed.

  Theorem monad_debug_left_id : forall T' (p: _ -> cprog T') s n,
      exec_equiv (Bind (Debug s n) p) (p tt).
  Proof.
    split; intros.
    - inv_bind.
      inv_debug; eauto.
      inv_debug.
    - eapply ExecBindFinish; eauto.
      eapply ExecStepDec; eauto.
  Qed.

  Theorem monad_assoc : forall T T' T''
                          (p1: cprog T)
                          (p2: T -> cprog T')
                          (p3: T' -> cprog T''),
      exec_equiv (Bind (Bind p1 p2) p3) (Bind p1 (fun x => Bind (p2 x) p3)).
  Proof.
    split; intros;
      repeat (inv_bind; eauto).
  Qed.

  Theorem cprog_ok_respects_exec_equiv : forall T (p p': cprog T) tid pre,
      exec_equiv p p' ->
      cprog_ok G tid pre p' ->
      cprog_ok G tid pre p.
  Proof.
    unfold cprog_ok, exec_equiv; intros.
    eapply H0; eauto.
    apply H; eauto.
  Qed.

End MonadLaws.

Require Import RelationClasses.

Instance exec_equiv_Equiv G T : Equivalence (@exec_equiv G T).
Proof.
  unfold exec_equiv.
  constructor; hnf; intros;
    repeat match goal with
           | [ H: forall (_:?A), _,
                 H': ?A |- _ ] =>
             specialize (H H')
           end;
    intuition eauto.
Defined.

Lemma exec_equiv_bind : forall (G: Protocol)
                          T T' (p1 p1': cprog T') (p2 p2': T' -> cprog T),
    exec_equiv G p1 p1' ->
    (forall v, exec_equiv G (p2 v) (p2' v)) ->
    exec_equiv G (Bind p1 p2) (Bind p1' p2').
Proof.
  intros.
  split; intros.
  inv_bind.
  eapply H in H6.
  eapply ExecBindFinish; eauto.
  eapply H0 in H9; eauto.

  eapply H in H5.
  eapply ExecBindFail; eauto.

  inv_bind.
  eapply H in H6.
  eapply ExecBindFinish; eauto.
  eapply H0 in H9; eauto.

  eapply H in H5.
  eapply ExecBindFail; eauto.
Qed.

Lemma exec_equiv_bind1 : forall (G: Protocol)
                           T T' (p p': cprog T) (rx: T -> cprog T'),
    exec_equiv G p p' ->
    exec_equiv G (Bind p rx) (Bind p' rx).
Proof.
  intros.
  apply exec_equiv_bind; auto.
  reflexivity.
Qed.

Lemma exec_equiv_bind2 : forall (G: Protocol)
                           T T' (p: cprog T) (rx1 rx2: T -> cprog T'),
    (forall v, exec_equiv G (rx1 v) (rx2 v)) ->
    exec_equiv G (Bind p rx1) (Bind p rx2).
Proof.
  intros.
  apply exec_equiv_bind; auto.
  reflexivity.
Qed.
