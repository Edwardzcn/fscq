Require Import FunctionalExtensionality.

Require Import CCL.
Require Import Hashmap.

Require Import FSProtocol.
Require Import OptimisticFS.
Require Import OptimisticFSSpecs.
Require Import ConcurCompile.
Require Import Errno.

Import FSLayout BFile.

Import OptimisticCache.

Inductive SyscallResult {T} :=
| Done (v:T)
| TryAgain (e:OptimisticException)
| SyscallFailed.

Arguments SyscallResult T : clear implicits.

Set Default Proof Using "All".

Section ConcurrentFS.

  Variable P:FsParams.
  Definition G := fs_guarantee P.

  Definition OptimisticProg T :=
    memstate ->
    LocalLock -> Cache ->
    cprog (Result (memstate * T) * Cache).

  Definition readCacheMem : cprog (Cache * memstate) :=
    Read2 Cache (ccache P) memstate (fsmem P).

  Definition reportBailout T (r: Result T) : cprog unit :=
    match r with
    | Success Modified _ =>
       Debug "readonly bailout" 0
    | _ => Ret tt
    end.

  (* Execute p assuming it is read-only. This program could distinguish between
  failures that require filling the cache [Failure (CacheMiss a)] and failures
  that require upgrading to a write lock [Failure WriteRequired], but currently
  does not do so. This would be useful to help the interpreter schedule reads
  (by waiting on address a before re-scheduling, for example). *)
  Definition readonly_syscall T (p: OptimisticProg T) : cprog (SyscallResult T) :=
    do '(c, mscs) <- readCacheMem;
      (* for read-only syscalls, the returned cache is always the same
       as the input *)
      do '(r, _) <- p mscs Unacquired c;
      _ <- reportBailout r;
      (* while slightly more awkward to write, this exposes the structure
      without having to destruct r or f, helping factor out the common parts of
      the proof *)
      Ret (match r with
           | Success f (ms', r) =>
             match f with
             | NoChange => Done r
             | Modified => TryAgain WriteRequired
             end
           | Failure e =>
             match e with
             | Unsupported => SyscallFailed
             | _ => TryAgain e
             end
           end).

  Definition guard {T} (r:SyscallResult T)
    : {(exists v, r = Done v) \/ r = SyscallFailed}
      + {exists e, r = TryAgain e}.
  Proof.
    destruct r; eauto.
  Defined.

  Definition startLocked :=
    _ <- GetWriteLock;
      do '(c, mscs) <- Read2 Cache (ccache P) memstate (fsmem P);
      Ret (c, mscs).

  (* finish up a rolled back system call by updating the cache and unlocking *)
  Definition finishRollback (c: Cache) :=
    _ <- Assgn1 (ccache P) c;
      Unlock.

  Definition yieldOnMiss (start:nat) (e:OptimisticException) : cprog unit :=
    match e with
    | CacheMiss a =>
      end_t <- Rdtsc;
      _ <- Debug "write cache miss" (end_t - start);
      YieldTillReady a
    | _ => Ret tt
    end.

  Definition EnsureFilled (c:Cache) (a:option nat) : cprog Cache :=
    match a with
    | Some a => do '(_, cs) <- CacheRead (caches c c) a Locked; Ret (cache cs)
    | None => Ret c
    end.

  Definition write_syscall T (a:option nat) (p: OptimisticProg T) (update: T -> dirtree -> dirtree) :
    cprog (SyscallResult T) :=
    retry guard
          (start <- Rdtsc;
             do '(c, mscs) <- startLocked;
             c <- EnsureFilled c a;
             do '(r, c) <- p mscs Locked c;
             match r with
             | Success _ (ms', r) =>
               _ <- Assgn2_abs (Make_assgn2
                                 (ccache P) c
                                 (fsmem P) ms'
                                 (fstree P) (fun (_:TID) => update r));
                 _ <- Unlock;
                 end_t <- Rdtsc;
                 _ <- Debug "write finish" (end_t - start);
                 Ret (Done r)
             | Failure e =>
               _ <- finishRollback c;
                 _ <- yieldOnMiss start e;
                 Ret (match e with
                      | CacheMiss a =>
                        TryAgain e
                      | WriteRequired => (* unreachable - have write lock *)
                        SyscallFailed
                      | Unsupported =>
                        SyscallFailed
                      end)
             end).

  (* to finish up read-only syscalls if they want to update the memory, we have
  to run them under write_syscall *)
  Definition retry_readonly_syscall T (p: OptimisticProg T) :=
    start <- Rdtsc;
    r <- readonly_syscall p;
      match r with
      | Done v => Ret (Done v)
      | TryAgain e => end_t <- Rdtsc;
                     _ <- Debug "read-only write" (end_t - start);
                     write_syscall (match e with
                                    | CacheMiss a => Some a
                                    | _ => None
                                    end) p (fun _ tree => tree)
      | SyscallFailed => Ret SyscallFailed
      end.

  Definition precondition_stable A T (fsspec: FsSpec A T) homes tid :=
    forall a tree tree', fs_pre (fsspec a) (homes tid) tree ->
                    homedir_rely tid homes tree tree' ->
                    fs_pre (fsspec a) (homes tid) tree'.

  Hint Resolve fs_rep_hashmap_incr.

  Definition readCacheMem_ok : forall tid,
      cprog_spec G tid
                 (fun '(tree, homedirs) sigma =>
                    {| precondition :=
                         fs_inv(P, sigma, tree, homedirs) /\
                         local_l tid (Sigma.l sigma) = Unacquired;
                       postcondition :=
                         fun sigma' '(c, mscs) =>
                           exists tree',
                             fs_inv(P, sigma', tree', homedirs) /\
                             hashmap_le (Sigma.hm sigma) (Sigma.hm sigma') /\
                             Rely G tid sigma sigma' /\
                             homedir_rely tid homedirs tree tree' /\
                             (* mscs and c come from fs_invariant on sigma *)
                             (exists d vd, cache_rep d c vd /\
                                      fs_rep P vd (Sigma.hm sigma') mscs tree) /\
                             local_l tid (Sigma.l sigma') = local_l tid (Sigma.l sigma); |})
                 readCacheMem.
  Proof using Type.
    unfold readCacheMem; intros.
    step; simpl in *; safe_intuition.
    match goal with
    | [ H: fs_invariant _ _ _ _ _ _ _ _ |- _ ] =>
      pose proof (fs_invariant_unfold_exists_disk H); repeat deex
    end.
    descend; simpl in *; intuition eauto.

    match goal with
    | [ H: local_l _ (Sigma.l _) = Unacquired |- _ ] =>
      rewrite H; simpl
    end.
    step.
    intuition trivial.
    edestruct fs_rely_invariant; eauto.
    descend; intuition eauto.
    eapply fs_homedir_rely; eauto.
    congruence.
  Qed.

  Hint Extern 1 {{ readCacheMem; _ }} => apply readCacheMem_ok : prog.

  Ltac finish := repeat match goal with
                        | [ |- _ /\ _ ] => split; trivial
                        | _ => descend
                        end;
                 simpl in *; subst;
                 (intuition (try eassumption; eauto)); try congruence.

  Lemma cache_rep_disk_eq : forall d d' c vd,
      d = d' ->
      cache_rep d' c vd -> cache_rep d c vd.
  Proof.
    intros; subst; auto.
  Qed.

  Hint Resolve cache_rep_disk_eq.

  Lemma fs_rep_same_disk_incr_hashmap : forall l d_i d d' hm hm' tree homedirs h,
      d' = d ->
      hashmap_le hm hm' ->
      fs_invariant P l d_i d hm tree homedirs h ->
      fs_invariant P l d_i d' hm' tree homedirs h.
  Proof.
    unfold fs_invariant; intros.
    SepAuto.pred_apply; SepAuto.cancel; eauto.
  Qed.

  Lemma fs_invariant_root_inode : forall l d_i d hm tree homedirs h,
      fs_invariant P l d_i d hm tree homedirs h ->
      root_inode_rep P tree.
  Proof.
    unfold fs_invariant; intros.
    SepAuto.destruct_lifts; auto.
  Qed.

  Hint Resolve fs_invariant_root_inode.

  Theorem reportBailout_ok : forall tid T (r: Result T),
      cprog_spec G tid
                 (fun (_:unit) sigma =>
                    {| precondition := True;
                       postcondition :=
                         fun sigma' u => sigma' = sigma /\ u = tt; |})
                 (reportBailout r).
  Proof.
    unfold reportBailout; intros.
    destruct r; try solve [ step; finish ].
    destruct f; try solve [ step; finish ].
  Qed.

  Hint Extern 1 {{ reportBailout _; _ }} => apply reportBailout_ok : prog.

  Theorem readonly_syscall_ok : forall T (p: OptimisticProg T) A
                                  (fsspec: FsSpec A T) tid,
      (forall mscs c, cprog_spec G tid
                            (fs_spec P fsspec tid mscs Unacquired c)
                            (p mscs Unacquired c)) ->
      cprog_spec G tid
                 (fun '(tree, homedirs, a) sigma =>
                    {| precondition :=
                         fs_inv(P, sigma, tree, homedirs) /\
                         local_l tid (Sigma.l sigma) = Unacquired /\
                         fs_pre (fsspec a) (homedirs tid) tree /\
                         precondition_stable fsspec homedirs tid;
                       postcondition :=
                         fun sigma' r =>
                           exists tree',
                             fs_inv(P, sigma', tree', homedirs) /\
                             Rely G tid sigma sigma' /\
                             homedir_rely tid homedirs tree tree' /\
                             local_l tid (Sigma.l sigma') = Unacquired /\
                             match r with
                             | Done v => fs_post (fsspec a) v
                             | TryAgain _ => True
                             | SyscallFailed => True
                             end |})
                 (readonly_syscall p).
  Proof using Type.
    unfold readonly_syscall; intros.
    step; simpl in *; safe_intuition.
    finish.

    monad_simpl.
    eapply cprog_ok_weaken;
      [ eapply H | ]; simplify; finish.

    (* skip over reportBailout *)
    step; simpl in *; intuition.

    step.
    unfold translated_postcondition in *; simplify.
    intuition.
    descend; intuition (norm_eq; eauto).
    eauto using fs_rep_same_disk_incr_hashmap.

    etransitivity; eauto.
    eapply fs_rely_same_fstree; norm_eq; eauto.
    eauto using fs_rep_same_disk_incr_hashmap.

    destruct_goal_matches; intuition auto.
  Qed.

  Lemma fs_invariant_free : forall d_i d hm tree homedirs h,
      fs_invariant P Free d_i d hm tree homedirs h ->
      d_i = d.
  Proof.
    unfold fs_invariant; intros.
    SepAuto.destruct_lifts; intuition.
  Qed.

  Lemma fs_invariant_free_to_owned : forall tid d_i d hm tree homedirs h,
      fs_invariant P Free d_i d hm tree homedirs h ->
      fs_invariant P (Owned tid) d d hm tree homedirs h.
  Proof.
    intros.
    unfold fs_invariant in *.
    SepAuto.destruct_lifts; intuition subst.
    SepAuto.pred_apply; SepAuto.cancel; eauto.
    SepAuto.pred_apply; SepAuto.cancel; eauto.
  Qed.

  Hint Resolve fs_invariant_free_to_owned.

  Lemma if_eq_tid : forall tid T (x y:T),
      (if tid_eq_dec tid tid then x else y) = x.
  Proof.
    intros.
    destruct (tid_eq_dec tid tid); congruence.
  Qed.

  Definition startLocked_ok : forall tid,
      cprog_spec G tid
                 (fun '(tree, homedirs) sigma =>
                    {| precondition :=
                         fs_inv(P, sigma, tree, homedirs) /\
                         local_l tid (Sigma.l sigma) = Unacquired;
                       postcondition :=
                         fun sigma' '(c, mscs) =>
                           exists vd' tree',
                             (fstree P |-> abs tree' * fshomedirs P |-> abs homedirs *
                              ccache P |-> val c * fsmem P |-> val mscs)%pred (Sigma.mem sigma') /\
                             cache_rep (Sigma.disk sigma') c vd' /\
                             fs_rep P vd' (Sigma.hm sigma') mscs tree' /\
                             root_inode_rep P tree' /\
                             hashmap_le (Sigma.hm sigma) (Sigma.hm sigma') /\
                             Rely G tid sigma sigma' /\
                             homedir_rely tid homedirs tree tree' /\
                             local_l tid (Sigma.l sigma') = Locked /\
                             Sigma.init_disk sigma' = Sigma.disk sigma' ; |})
                 startLocked.
  Proof using Type.
    unfold startLocked; intros.
    step; finish.

    step; simplify.
    edestruct fs_rely_invariant; eauto.
    assert (Sigma.init_disk sigma' = Sigma.disk sigma').
    replace (Sigma.l sigma') in *.
    eapply fs_invariant_free; eauto.

    destruct sigma'; simpl in *; subst.
    match goal with
    | [ H: fs_invariant _ _ _ _ _ _ _ _ |- _ ] =>
      pose proof (fs_invariant_unfold_same_disk H); intuition; repeat deex
    end; descend; simpl in *; intuition eauto.

    step; rewrite ?if_eq_tid in *; simplify.
    intuition trivial.
    descend; simpl in *; intuition eauto.
    etransitivity; eauto.
    eapply fs_rely_same_fstree; simpl; eauto.
    eapply fs_homedir_rely; eauto.
  Qed.

  Hint Extern 1 {{ startLocked; _ }} => apply startLocked_ok : prog.

  Lemma free_l_not_locked : forall tid l l',
      local_l tid l = Locked ->
      l = l' ->
      l' = Free ->
      False.
  Proof.
    intros; subst; simpl in *.
    congruence.
  Qed.

  Hint Resolve local_locked free_l_not_locked.

  Definition finishRollback_ok : forall tid c,
      cprog_spec G tid
                 (fun '(c0, mscs, vd, tree, homedirs) sigma =>
                    {| precondition :=
                         (fstree P |-> abs tree * fshomedirs P |-> abs homedirs *
                          ccache P |-> val c0 * fsmem P |-> val (mscs:memstate))%pred (Sigma.mem sigma) /\
                         (* existing cache applies to d_i *)
                         cache_rep (Sigma.init_disk sigma) c0 vd /\
                         (* new cache is for the new disk, at the same virtual disk *)
                         cache_rep (Sigma.disk sigma) c vd /\
                         fs_rep P vd (Sigma.hm sigma) mscs tree /\
                         root_inode_rep P tree /\
                         local_l tid (Sigma.l sigma) = Locked;
                       postcondition :=
                         fun sigma' _ =>
                           fs_inv (P, sigma', tree, homedirs) /\
                           hashmap_le (Sigma.hm sigma) (Sigma.hm sigma') /\
                           local_l tid (Sigma.l sigma') = Unacquired; |})
                 (finishRollback c).
  Proof using Type.
    unfold finishRollback; intros.
    step; finish.
    SepAuto.pred_apply; SepAuto.cancel.
    unfold G, fs_guarantee.
    descend; intuition eauto.
    unfold fs_invariant; SepAuto.pred_apply; SepAuto.cancel; eauto; try congruence.
    exfalso; eauto.

    unfold fs_invariant; SepAuto.pred_apply; SepAuto.cancel; eauto; try congruence.
    exfalso; eauto.
    reflexivity.

    step; finish; norm_eq; eauto.

    unfold G, fs_guarantee.
    descend; intuition eauto.
    unfold fs_invariant; SepAuto.pred_apply; SepAuto.cancel; eauto; try congruence.
    exfalso; eauto.
    unfold fs_invariant; SepAuto.pred_apply; SepAuto.cancel; eauto; try congruence.
    reflexivity.

    step; finish.
    unfold fs_invariant; SepAuto.pred_apply; SepAuto.cancel; eauto; try congruence.

    norm_eq; reflexivity.
  Qed.

  Hint Extern 1 {{ finishRollback _; _ }} => apply finishRollback_ok : prog.

  Theorem yieldOnMiss_ok : forall tid s e,
      cprog_spec G tid
                 (fun (_:unit) sigma =>
                    {| precondition := True;
                       postcondition :=
                         fun sigma' r => sigma' = sigma /\ r = tt; |})
                 (yieldOnMiss s e).
  Proof.
    unfold yieldOnMiss; intros.
    destruct e; repeat (step; finish).
  Qed.

  Hint Extern 1 {{ yieldOnMiss _ _; _ }} => apply yieldOnMiss_ok : prog.

  Definition same_fs_update tid homedirs tree T (update update': T -> dirtree -> dirtree) :=
    forall r tree', homedir_rely tid homedirs tree tree' ->
               DirTreeNames.tree_names_distinct tree' ->
               DirTreeInodes.tree_inodes_distinct tree' ->
               update r tree' = update' r tree'.

  Lemma fs_rep_tree_names_distinct : forall vd hm mscs tree,
      fs_rep P vd hm mscs tree ->
      DirTreeNames.tree_names_distinct tree.
  Proof.
    unfold fs_rep; unfold exis; intros;
      repeat deex.
    eapply DirTreeNames.rep_tree_names_distinct with (F:=emp).
    apply pimpl_star_emp; eauto.
  Qed.

  Lemma fs_invariant_tree_names_distinct : forall l d_i d hm tree homedirs h,
      fs_invariant P l d_i d hm tree homedirs h ->
      DirTreeNames.tree_names_distinct tree.
  Proof.
    unfold fs_invariant; intuition.
    SepAuto.destruct_lifts.
    eapply fs_rep_tree_names_distinct; eauto.
  Qed.

  Lemma fs_rep_tree_inodes_distinct : forall vd hm mscs tree,
      fs_rep P vd hm mscs tree ->
      DirTreeInodes.tree_inodes_distinct tree.
  Proof.
    unfold fs_rep; unfold exis; intros;
      repeat deex.
    eapply DirTreeInodes.rep_tree_inodes_distinct with (F:=emp).
    apply pimpl_star_emp; eauto.
  Qed.

  Hint Resolve fs_rep_tree_names_distinct fs_rep_tree_inodes_distinct.

  Definition allowed_fs_update tid homedirs tree T (post: T -> Prop) (update: T -> dirtree -> dirtree) :=
    forall r tree',
      homedir_rely tid homedirs tree tree' ->
      post r ->
      DirTreeNames.tree_names_distinct tree' ->
      DirTreeInodes.tree_inodes_distinct tree' ->
      homedir_guarantee tid homedirs tree' (update r tree').

  Lemma allowed_fs_update_apply : forall tid homedirs tree T (post: T -> Prop) update r tree',
      allowed_fs_update tid homedirs tree post update ->
      homedir_rely tid homedirs tree tree' ->
      post r ->
      DirTreeNames.tree_names_distinct tree' ->
      DirTreeInodes.tree_inodes_distinct tree' ->
      homedir_guarantee tid homedirs tree' (update r tree').
  Proof.
    unfold allowed_fs_update; eauto.
  Qed.

  Lemma is_allowed_fs_update : forall tid homedirs tree T (post: T -> Prop) update,
      (forall r tree',
          homedir_rely tid homedirs tree tree' ->
          post r ->
          DirTreeNames.tree_names_distinct tree' ->
          DirTreeInodes.tree_inodes_distinct tree' ->
          homedir_guarantee tid homedirs tree' (update r tree')) ->
      allowed_fs_update tid homedirs tree post update.
  Proof.
    unfold allowed_fs_update; eauto.
  Qed.

  Opaque allowed_fs_update.

  Theorem write_syscall_ok' : forall m_a T (p: OptimisticProg T) A
                                (fsspec: FsSpec A T) update tid,
      (forall mscs c, cprog_spec G tid
                            (fs_spec P fsspec tid mscs Locked c)
                            (p mscs Locked c)) ->
      cprog_spec G tid
                 (fun '(tree, homedirs, a) sigma =>
                    {| precondition :=
                         fs_inv(P, sigma, tree, homedirs) /\
                         local_l tid (Sigma.l sigma) = Unacquired /\
                         fs_pre (fsspec a) (homedirs tid) tree /\
                         precondition_stable fsspec homedirs tid /\
                         same_fs_update tid homedirs tree update (fs_dirup (fsspec a)) /\
                         allowed_fs_update tid homedirs tree (fs_post (fsspec a)) update;
                       postcondition :=
                         fun sigma' r =>
                           exists tree' tree'',
                             fs_inv(P, sigma', tree'', homedirs) /\
                             homedir_rely tid homedirs tree tree' /\
                             local_l tid (Sigma.l sigma') = Unacquired /\
                             match r with
                             | Done v => fs_post (fsspec a) v /\
                                        tree'' = fs_dirup (fsspec a) v tree' /\
                                        Sigma.init_disk sigma' = Sigma.disk sigma'
                             | TryAgain _ => tree'' = tree' /\
                                          Sigma.init_disk sigma' = Sigma.disk sigma'
                             | SyscallFailed => tree'' = tree'
                             end |})
                 (write_syscall m_a p update).
  Proof using Type.
    unfold write_syscall; intros.
    apply retry_spec' with SyscallFailed.
    induction n; simpl; intros.
    - step; simpl.
      descend; intuition eauto.
      reflexivity.
    - step.
      step.
      descend; simpl in *; intuition eauto.

      monad_simpl.
      eapply cprog_ok_weaken;
        [ eapply H | ]; simplify; finish.

      (* destruct return value of optimistic program *)
      destruct a1.
      + (* returned successfully *)
        rename r into start.
        destruct v as [ms' r].

        (* Assgn2_abs *)
        step; simpl.
        unfold translated_postcondition in *; simpl in *; intuition eauto.
        descend; simpl in *; intuition (norm_eq; eauto).
        SepAuto.pred_apply; SepAuto.cancel.

        unfold G, fs_guarantee.
        descend; intuition eauto.
        unfold fs_invariant; SepAuto.pred_apply; SepAuto.norm;
          [ SepAuto.cancel | intuition eauto ].
        norm_eq; exfalso; eauto.
        unfold fs_invariant; SepAuto.pred_apply; SepAuto.norm;
          [ SepAuto.cancel | intuition eauto ].
        match goal with
        | [ H: same_fs_update _ _ _ _ _ |- _ ] =>
          erewrite H; eauto
        end.
        norm_eq.
        exfalso; eauto.
        match goal with
        | [ H: same_fs_update _ _ _ _ _ |- _ ] =>
          erewrite H; eauto
        end.
        congruence.
        eapply allowed_fs_update_apply; eauto.

        (* unlock *)
        step.
        descend; simpl in *; intuition eauto.
        norm_eq.
        eauto.
        unfold G, fs_guarantee.
        exists (fs_dirup (fsspec a0) r tree'), (fs_dirup (fsspec a0) r tree').
        match goal with
        | [ H: same_fs_update _ _ _ _ _ |- _ ] =>
          erewrite H in *; eauto
        end.
        descend; intuition eauto.
        unfold fs_invariant; SepAuto.pred_apply; SepAuto.norm;
          [ SepAuto.cancel | intuition eauto ].
        norm_eq; exfalso; eauto.
        congruence.
        unfold fs_invariant; SepAuto.pred_apply; SepAuto.norm;
          [ SepAuto.cancel | intuition eauto ].
        congruence.
        congruence.
        reflexivity.

        step; finish.
        step; finish.
        step; finish.

        (* next iteration of loop *)
        destruct (guard r1); simpl.
        * (* succeeded, return *)
          step; finish.
          match goal with
          | [ H: same_fs_update _ _ _ _ _ |- _ ] =>
            erewrite H in *; eauto
          end.
          unfold fs_invariant; SepAuto.pred_apply; SepAuto.norm;
            [ SepAuto.cancel | intuition eauto ].
          congruence.
        * (* need to try again *)
          step; discriminate.
      + (* optimistic system call returned an error *)
        (* update cache *)
        step; simplify.

        descend; unfold translated_postcondition in *;
          simpl in *; intuition (norm_eq; eauto).

        (* skip over yieldOnMiss *)
        step; finish.

        (* now we return an appropriate value *)
        step; simplify; finish.

        (* need to loop around depending on guard r (in particular, will stop on
        SyscallFailed) *)
        destruct (guard r0) eqn:? .
        step; finish.
        destruct e; auto.
        intuition; repeat deex; try discriminate.

        step; finish.
        (* error must be a cache miss if we're trying again *)
        destruct e; try discriminate.
        unfold same_fs_update; intros.
        match goal with
        | [ H: same_fs_update _ _ _ _ _ |- _ ] =>
          erewrite H in *; eauto
        end.
        etransitivity; eauto.
        eapply is_allowed_fs_update; intros; eauto.
        eapply allowed_fs_update_apply; eauto.
        etransitivity; eauto.

        step; simplify.
        intuition trivial.
        destruct r0; intuition; subst.
        exists tree'0, (fs_dirup (fsspec a0) v tree'0).
        descend; simpl in *; intuition eauto.
        etransitivity; eauto.

        exists tree'0.
        descend; simpl in *; intuition eauto.
        etransitivity; eauto.

        exists tree'0.
        descend; simpl in *; intuition eauto.
        etransitivity; eauto.
  Qed.

  (* remove TryAgain from postcondition due to infinite retry *)
  Theorem write_syscall_ok : forall m_a T (p: OptimisticProg T) A
                               (fsspec: FsSpec A T) update tid,
      (forall mscs c, cprog_spec G tid
                            (fs_spec P fsspec tid mscs Locked c)
                            (p mscs Locked c)) ->
      cprog_spec G tid
                 (fun '(tree, homedirs, a) sigma =>
                    {| precondition :=
                         fs_inv(P, sigma, tree, homedirs) /\
                         local_l tid (Sigma.l sigma) = Unacquired /\
                         fs_pre (fsspec a) (homedirs tid) tree /\
                         precondition_stable fsspec homedirs tid /\
                         same_fs_update tid homedirs tree update (fs_dirup (fsspec a)) /\
                         allowed_fs_update tid homedirs tree (fs_post (fsspec a)) update;
                       postcondition :=
                         fun sigma' r =>
                           exists tree' tree'',
                             fs_inv(P, sigma', tree'', homedirs) /\
                             homedir_rely tid homedirs tree tree' /\
                             local_l tid (Sigma.l sigma') = Unacquired /\
                             match r with
                             | Done v => fs_post (fsspec a) v /\
                                        tree'' = fs_dirup (fsspec a) v tree' /\
                                        Sigma.init_disk sigma' = Sigma.disk sigma'
                             | TryAgain _ => False
                             | SyscallFailed => tree'' = tree'
                             end |})
                 (write_syscall m_a p update).
  Proof using Type.
    intros.
    apply write_syscall_ok' with (update:=update) in H.
    apply retry_upgrade_spec in H.
    unfold cprog_spec; intros.
    eapply cprog_ok_weaken; [ eauto | ].
    simplify; descend; simpl in *; intuition eauto.
    step.
    intuition trivial.
    descend; intuition eauto.
    destruct r; (intuition eauto); discriminate.
  Qed.

  Theorem retry_readonly_syscall_ok : forall T (p: OptimisticProg T) A
                               (fsspec: FsSpec A T) tid,
      (forall mscs c l, cprog_spec G tid
                              (fs_spec P fsspec tid mscs l c)
                              (p mscs l c)) ->
      cprog_spec G tid
                 (fun '(tree, homedirs, a) sigma =>
                    {| precondition :=
                         fs_inv(P, sigma, tree, homedirs) /\
                         local_l tid (Sigma.l sigma) = Unacquired /\
                         fs_pre (fsspec a) (homedirs tid) tree /\
                         (forall r tree, fs_dirup (fsspec a) r tree = tree) /\
                         precondition_stable fsspec homedirs tid;
                       postcondition :=
                         fun sigma' r =>
                           exists tree',
                             fs_inv(P, sigma', tree', homedirs) /\
                             homedir_rely tid homedirs tree tree' /\
                             local_l tid (Sigma.l sigma') = Unacquired /\
                             match r with
                             | Done v => fs_post (fsspec a) v
                             | TryAgain _ => False
                             | SyscallFailed => True
                             end |})
                 (retry_readonly_syscall p).
  Proof using Type.
    unfold retry_readonly_syscall; intros.
    step.
    rename r into start.

    unfold cprog_spec; intros.
    eapply cprog_ok_weaken;
      [ monad_simpl; eapply readonly_syscall_ok; eauto | ];
      simplify; finish.

    destruct r.
    - step; finish.
    - repeat (step; finish).
      rename r into end_t.
      eapply cprog_ok_weaken;
      [ monad_simpl; eapply write_syscall_ok; eauto | ];
      simplify; finish.
      eapply is_allowed_fs_update; intros; reflexivity.

      step; finish.
      destruct r; intuition subst.
      match goal with
      | [ H: context[fs_dirup (fsspec _)] |- _ ] =>
        rewrite H
      end.
      etransitivity; eauto.
      etransitivity; eauto.

      destruct_goal_matches; intuition eauto.
    - step; finish.
  Qed.

  (* translate all system calls for extraction *)
  (* TODO: add real directory updates to modifying system calls (ie, those that
  use [write_syscall]'s) *)

  Definition file_get_attr inum :=
    retry_readonly_syscall (fun mscs => file_get_attr G (fsxp P) inum mscs).

  Lemma find_subtree_app' : forall prefix path tree subtree o_dir,
      find_subtree prefix tree = Some subtree ->
      find_subtree path subtree = o_dir ->
      find_subtree (prefix ++ path) tree = o_dir.
  Proof.
    intros.
    erewrite find_subtree_app; eauto.
  Qed.

  Hint Resolve find_subtree_app'.

  Theorem cprog_spec_compiled_prog : forall tid A T (spec: Spec A T) (p: cprog T)
                                       (cp: Compiled G p),
      cprog_spec G tid spec p ->
      cprog_spec G tid spec (compiled_prog cp).
  Proof.
    intros.
    eapply spec_respects_exec_equiv; eauto.
    symmetry.
    apply ConcurCompile.compiled_exec_equiv.
  Qed.

  Hint Resolve cprog_spec_compiled_prog.

  Theorem file_get_attr_ok : forall tid inum,
      cprog_spec G tid
                 (fun '(tree, homedirs, homedir, pathname, f) sigma =>
                    {| precondition :=
                         fs_inv(P, sigma, tree, homedirs) /\
                         local_l tid (Sigma.l sigma) = Unacquired /\
                         find_subtree (homedirs tid) tree = Some (homedir) /\
                         find_subtree pathname homedir = Some (TreeFile inum f);
                       postcondition :=
                         fun sigma' r =>
                           exists tree',
                             fs_inv(P, sigma', tree', homedirs) /\
                             find_subtree (homedirs tid) tree' = Some homedir /\
                             local_l tid (Sigma.l sigma') = Unacquired /\
                             match r with
                             | Done (attr, _) => attr = DFAttr f
                             | TryAgain _ => False
                             | SyscallFailed => True
                             end |})
                 (file_get_attr inum).
  Proof.
    unfold file_get_attr; intros.
    unfold ConcurCompile.file_get_attr.
    unfold cprog_spec; intros;
      eapply cprog_ok_weaken;
      [ monad_simpl; eapply retry_readonly_syscall_ok;
        eauto using opt_file_get_attr_ok | ];
      simplify; finish.

    unfold precondition_stable; simplify; simpl.
    eapply homedir_rely_preserves_subtrees; eauto.

    step; finish.
  Qed.

  Lemma homedir_guarantee_alter : forall tid homedirs tree inum path up f,
      find_subtree (homedirs tid ++ path) tree = Some f ->
      dirtree_inum f = inum ->
      homedir_disjoint homedirs tid ->
      DirTreeInodes.tree_inodes_distinct tree ->
      DirTreeNames.tree_names_distinct tree ->
      homedir_guarantee tid homedirs tree
                        (alter_inum inum up tree).
  Proof.
    intros.
    erewrite DirTreeInodes.alter_inum_to_alter_path; eauto.
    eapply alter_homedir_guarantee; eauto.
  Qed.

  Definition dirtree_alter_file inum (up:dirfile -> dirfile)
    : dirtree -> dirtree :=
    alter_inum inum (fun subtree =>
                       match subtree with
                       | TreeFile inum' f =>
                         TreeFile inum' (up f)
                       | TreeDir _ _ => subtree
                       end).

  Definition file_set_attr inum attr :=
    write_syscall None
                  (fun mscs => OptFS.file_set_attr (fsxp P) inum attr mscs)
                  (fun '(b, _) tree =>
                     match b with
                     | OK _ => dirtree_alter_file
                                inum (fun f => mk_dirfile (DFData f) attr)
                                tree
                     | Err _ => tree
                     end).


  Hint Resolve homedir_rely_preserves_homedir.

  Theorem file_set_attr_ok : forall tid inum attr,
      cprog_spec G tid
                 (fun '(tree, homedirs, homedir, pathname, f) sigma =>
                    {| precondition :=
                         fs_inv(P, sigma, tree, homedirs) /\
                         local_l tid (Sigma.l sigma) = Unacquired /\
                         homedir_disjoint homedirs tid /\
                         find_subtree (homedirs tid) tree = Some homedir /\
                         find_subtree pathname homedir = Some (TreeFile inum f);
                       postcondition :=
                         fun sigma' r =>
                           exists tree',
                             fs_inv(P, sigma', tree', homedirs) /\
                             local_l tid (Sigma.l sigma') = Unacquired /\
                             match r with
                             | Done (r, _) =>
                               match r with
                               | OK _ =>
                                 let f' := mk_dirfile (DFData f) attr in
                                 let homedir' := update_subtree pathname (TreeFile inum f') homedir in
                                 find_subtree (homedirs tid) tree' = Some homedir'
                               | Err _ => find_subtree (homedirs tid) tree' = Some homedir
                               end
                             | TryAgain _ => False
                             | SyscallFailed => find_subtree (homedirs tid) tree' = Some homedir
                             end |})
                 (file_set_attr inum attr).
  Proof.
    unfold file_set_attr; intros.
    unfold cprog_spec; intros;
      eapply cprog_ok_weaken;
      [ monad_simpl; eapply write_syscall_ok;
        eauto using opt_file_set_attr_ok | ];
      simplify; finish.
    unfold precondition_stable; simplify; simpl.
    intuition eauto.
    eapply homedir_rely_preserves_subtrees; eauto.

    unfold same_fs_update; intros.
    destruct_goal_matches.
    unfold dirtree_alter_file.
    eapply homedir_rely_preserves_subtrees in H4; eauto.
    erewrite DirTreeInodes.alter_inum_to_alter_path; eauto.
    erewrite DirTreeNames.alter_to_update; eauto; simpl; auto.

    eapply is_allowed_fs_update; intros.
    destruct_goal_matches.
    eapply homedir_rely_preserves_subtrees in H4; eauto.
    unfold dirtree_alter_file.
    eapply homedir_guarantee_alter; eauto.

    step; finish.
    destruct r; intuition (subst; eauto).
    destruct_goal_matches; eauto.
    eapply homedir_rely_preserves_homedir in H6; eauto.
    erewrite find_subtree_update_subtree_child; eauto.
  Qed.

  Definition create dnum name :=
    write_syscall None
                  (fun mscs => OptFS.create (fsxp P) dnum name mscs)
                  (fun '(r, _) tree =>
                     match r with
                     | OK inum =>
                       let f := TreeFile inum dirfile0 in
                       tree_graft_alter dnum name f tree
                     | _ => tree
                     end).

  Theorem create_ok : forall tid dnum name,
      cprog_spec G tid
                 (fun '(tree, homedirs, homedir, pathname, tree_elem) sigma =>
                    {| precondition :=
                         fs_inv(P, sigma, tree, homedirs) /\
                         local_l tid (Sigma.l sigma) = Unacquired /\
                         homedir_disjoint homedirs tid /\
                         find_subtree (homedirs tid) tree = Some homedir /\
                         find_subtree pathname homedir = Some (TreeDir dnum tree_elem);
                       postcondition :=
                         fun sigma' r =>
                           exists tree',
                             fs_inv(P, sigma', tree', homedirs) /\
                             local_l tid (Sigma.l sigma') = Unacquired /\
                             match r with
                             | Done (r, _) =>
                               match r with
                               | OK inum =>
                                 let f := TreeFile inum dirfile0 in
                                 let homedir' := tree_graft dnum tree_elem pathname name f homedir in
                                 find_subtree (homedirs tid) tree' = Some homedir'
                               | _ => find_subtree (homedirs tid) tree' = Some homedir
                               end
                             | TryAgain _ => False
                             | SyscallFailed => find_subtree (homedirs tid) tree' = Some homedir
                             end |})
                 (create dnum name).
  Proof.
    unfold create; intros.
    unfold cprog_spec; intros;
      eapply cprog_ok_weaken;
      [ monad_simpl; eapply write_syscall_ok;
        eauto using opt_create_ok | ];
      simplify; finish.
    unfold precondition_stable; simplify; simpl.
    intuition eauto.
    eapply homedir_rely_preserves_subtrees; eauto.

    unfold same_fs_update; intros.
    destruct_goal_matches.
    eapply homedir_rely_preserves_subtrees in H4; eauto.
    erewrite DirTreeInodes.tree_graft_alter_to_tree_graft by eauto;
      reflexivity.

    eapply is_allowed_fs_update; intros.
    destruct_goal_matches.
    eapply homedir_rely_preserves_subtrees in H4; eauto.
    unfold tree_graft_alter.
    eapply homedir_guarantee_alter; eauto.

    step; finish.
    destruct r; intuition (subst; eauto).
    destruct_goal_matches; eauto.

    eapply homedir_rely_preserves_homedir in H6; eauto.
    unfold tree_graft.
    erewrite find_subtree_update_subtree_child; eauto.
  Qed.

  Definition file_truncate inum sz :=
    write_syscall None
                  (fun mscs => OptFS.file_truncate (fsxp P) inum sz mscs)
                  (fun '(r, _) tree =>
                     match r with
                     | OK _ => dirtree_alter_file
                                inum (fun f => mk_dirfile (ListUtils.setlen (DFData f) sz (Word.natToWord _ 0, nil)) (DFAttr f))
                                tree
                     | Err _ => tree
                     end).

  Theorem file_truncate_ok : forall tid inum sz,
      cprog_spec G tid
                 (fun '(tree, homedirs, homedir, pathname, f) sigma =>
                    {| precondition :=
                         fs_inv(P, sigma, tree, homedirs) /\
                         local_l tid (Sigma.l sigma) = Unacquired /\
                         homedir_disjoint homedirs tid /\
                         find_subtree (homedirs tid) tree = Some homedir /\
                         find_subtree pathname homedir = Some (TreeFile inum f);
                       postcondition :=
                         fun sigma' r =>
                           exists tree',
                             fs_inv(P, sigma', tree', homedirs) /\
                             local_l tid (Sigma.l sigma') = Unacquired /\
                             match r with
                             | Done (r, _) =>
                               match r with
                               | OK _ =>
                                 let f' := mk_dirfile (ListUtils.setlen (DFData f) sz (Word.natToWord _ 0, nil)) (DFAttr f) in
                                 let homedir' := update_subtree pathname (TreeFile inum f') homedir in
                                 find_subtree (homedirs tid) tree' = Some homedir'
                               | Err _ => find_subtree (homedirs tid) tree' = Some homedir
                               end
                             | TryAgain _ => False
                             | SyscallFailed => find_subtree (homedirs tid) tree' = Some homedir
                             end |})
                 (file_truncate inum sz).
  Proof.
    unfold file_truncate; intros.
    unfold cprog_spec; intros;
      eapply cprog_ok_weaken;
      [ monad_simpl; eapply write_syscall_ok;
        eauto using opt_file_truncate_ok | ];
      simplify; finish.
    unfold precondition_stable; simplify; simpl.
    intuition eauto.
    eapply homedir_rely_preserves_subtrees; eauto.

    unfold same_fs_update; intros.
    destruct_goal_matches.
    eapply homedir_rely_preserves_subtrees in H4; eauto.
    unfold dirtree_alter_file.
    erewrite DirTreeInodes.alter_inum_to_alter_path; eauto.
    erewrite DirTreeNames.alter_to_update; eauto; simpl; auto.

    eapply is_allowed_fs_update; intros.
    destruct_goal_matches.
    eapply homedir_rely_preserves_subtrees in H4; eauto.
    unfold dirtree_alter_file.
    eapply homedir_guarantee_alter; eauto.

    step; finish.
    destruct r; intuition (subst; eauto).
    destruct_goal_matches.
    erewrite find_subtree_update_subtree_child; eauto.
  Qed.

  Definition lookup names :=
    retry_readonly_syscall (fun mscs => lookup G (fsxp P) (FSLayout.FSXPRootInum (fsxp P)) names mscs).

  Theorem lookup_ok : forall tid pathname,
      cprog_spec G tid
                 (fun '(tree, homedirs, homedir, path) sigma =>
                    {| precondition :=
                         fs_inv(P, sigma, tree, homedirs) /\
                         local_l tid (Sigma.l sigma) = Unacquired /\
                         pathname = (homedirs tid ++ path)%list /\
                         find_subtree (homedirs tid) tree = Some (homedir) /\
                         dirtree_inum tree = FSLayout.FSXPRootInum (fsxp P) /\
                         dirtree_isdir tree = true;
                       postcondition :=
                         fun sigma' r =>
                           exists tree',
                             fs_inv(P, sigma', tree', homedirs) /\
                             find_subtree (homedirs tid) tree' = Some homedir /\
                             local_l tid (Sigma.l sigma') = Unacquired /\
                             match r with
                             | Done (r, _) => match r with
                                             | OK v => find_name pathname tree = Some v
                                             | Err _ => find_name pathname tree = None
                                             end
                             | TryAgain _ => False
                             | SyscallFailed => True
                             end |})
                 (lookup pathname).
  Proof.
    unfold lookup; intros.
    unfold ConcurCompile.lookup.
    unfold cprog_spec; intros;
      eapply cprog_ok_weaken;
      [ monad_simpl; eapply retry_readonly_syscall_ok;
        eauto using opt_lookup_ok | ];
      simplify; finish.

    unfold precondition_stable; simplify; simpl in *.
    intuition eauto; repeat deex.
    match goal with
    | [ H: (?l ++ _)%list = (?l ++ _)%list |- _ ] =>
      apply List.app_inv_head in H; subst
    end.
    unfold find_name.
    case_eq (find_subtree (homedirs tid) tree0); intros.
    erewrite ?find_subtree_app by eauto; auto.
    pose proof (homedir_rely_preserves_homedir_missing H2 ltac:(eauto)).
    erewrite ?find_subtree_app_none by eauto; auto.

    step; finish.
  Qed.

  Definition proj_comp G T {p: LocalLock -> Cache -> cprog T}
             (cp: forall ls c, Compiled G (p ls c)) :
    LocalLock -> Cache -> cprog T := fun ls c => compiled_prog (cp ls c).

  Definition read_fblock inum off :=
    retry_readonly_syscall (fun mscs => OptFS.read_fblock (fsxp P) inum off mscs).

  Theorem read_fblock_ok : forall inum off tid,
      cprog_spec G tid
                 (fun '(tree, homedirs, homedir, pathname, f, Fd, vs) sigma =>
                    {| precondition :=
                         fs_inv(P, sigma, tree, homedirs) /\
                         local_l tid (Sigma.l sigma) = Unacquired /\
                         find_subtree (homedirs tid) tree = Some (homedir) /\
                         find_subtree pathname homedir = Some (TreeFile inum f) /\
                         (Fd * off |-> vs)%pred (GenSepN.list2nmem (DFData f));
                       postcondition :=
                         fun sigma' r =>
                           exists tree',
                             fs_inv(P, sigma', tree', homedirs) /\
                             find_subtree (homedirs tid) tree' = Some homedir /\
                             local_l tid (Sigma.l sigma') = Unacquired /\
                             match r with
                             | Done (r, _) => r = fst vs
                             | TryAgain _ => False
                             | SyscallFailed => True
                             end |})
                 (read_fblock inum off).
  Proof.
    unfold read_fblock; intros.
    unfold ConcurCompile.read_fblock.
    unfold cprog_spec; intros;
      eapply cprog_ok_weaken;
      [ monad_simpl; eapply retry_readonly_syscall_ok;
        eauto using opt_read_fblock_ok | ];
      simplify; finish.

    unfold precondition_stable; simplify; simpl.
    intuition.
    eapply homedir_rely_preserves_subtrees; eauto.

    step; finish.
  Qed.

  Definition update_fblock_d inum off b :=
    write_syscall None
                  (fun mscs => OptFS.update_fblock_d (fsxp P) inum off b mscs)
                  (fun _ tree =>
                     dirtree_alter_file
                       inum (fun f =>
                               let vs := ListUtils.selN (DFData f) off (Word.natToWord _ 0, nil) in
                               mk_dirfile (ListUtils.updN (DFData f) off (b, AsyncDisk.vsmerge vs)) (DFAttr f))
                       tree).

  Theorem update_fblock_d_ok : forall tid inum off b,
      cprog_spec G tid
                 (fun '(tree, homedirs, homedir, pathname, f, Fd, vs) sigma =>
                    {| precondition :=
                         fs_inv(P, sigma, tree, homedirs) /\
                         local_l tid (Sigma.l sigma) = Unacquired /\
                         homedir_disjoint homedirs tid /\
                         find_subtree (homedirs tid) tree = Some homedir /\
                         find_subtree pathname homedir = Some (TreeFile inum f) /\
                         (Fd * off |-> vs)%pred (GenSepN.list2nmem (DFData f));
                       postcondition :=
                         fun sigma' r =>
                           exists tree',
                             fs_inv(P, sigma', tree', homedirs) /\
                             local_l tid (Sigma.l sigma') = Unacquired /\
                             match r with
                             | Done _ =>
                               exists f',
                               let homedir' := update_subtree pathname (TreeFile inum f') homedir in
                               find_subtree (homedirs tid) tree' = Some homedir' /\
                               DFAttr f' = DFAttr f /\
                               (Fd * off |-> (b, AsyncDisk.vsmerge vs))%pred (GenSepN.list2nmem (DFData f'))
                             | TryAgain _ => False
                             | SyscallFailed => find_subtree (homedirs tid) tree' = Some homedir
                             end |})
                 (update_fblock_d inum off b).
  Proof.
    unfold update_fblock_d; intros.
    unfold cprog_spec; intros;
      eapply cprog_ok_weaken;
      [ monad_simpl; eapply write_syscall_ok;
        eauto using opt_update_fblock_d_ok | ];
      simplify; finish.
    unfold precondition_stable; simplify; simpl.
    intuition eauto.
    eapply homedir_rely_preserves_subtrees; eauto.

    unfold same_fs_update; intros.
    unfold dirtree_alter_file.
    eapply homedir_rely_preserves_subtrees in H5; eauto.
    erewrite DirTreeInodes.alter_inum_to_alter_path; eauto.
    erewrite DirTreeNames.alter_to_update; eauto; simpl; auto.
    erewrite <- GenSepN.list2nmem_sel; eauto.

    eapply is_allowed_fs_update; intros.
    eapply homedir_rely_preserves_subtrees in H5; eauto.
    unfold dirtree_alter_file.
    eapply homedir_guarantee_alter; eauto.

    step; finish.
    destruct r; intuition (subst; eauto).
    erewrite find_subtree_update_subtree_child; eauto.
    descend; intuition eauto; simpl.
    eapply GenSepN.list2nmem_updN; eauto.
  Qed.

  Definition delete dnum name :=
    write_syscall None
                  (fun mscs => OptFS.delete (fsxp P) dnum name mscs)
                  (fun '(r, _) tree =>
                     match r with
                     | OK _ => alter_inum
                                dnum (fun d => delete_from_dir name d)
                                tree
                     | Err _ => tree
                     end).

  Theorem delete_ok : forall tid dnum name,
      cprog_spec G tid
                 (fun '(tree, homedirs, homedir, pathname, tree_elem) sigma =>
                    {| precondition :=
                         fs_inv(P, sigma, tree, homedirs) /\
                         local_l tid (Sigma.l sigma) = Unacquired /\
                         homedir_disjoint homedirs tid /\
                         find_subtree (homedirs tid) tree = Some homedir /\
                         find_subtree pathname homedir = Some (TreeDir dnum tree_elem);
                       postcondition :=
                         fun sigma' r =>
                           exists tree',
                             fs_inv(P, sigma', tree', homedirs) /\
                             local_l tid (Sigma.l sigma') = Unacquired /\
                             match r with
                             | Done (r, _) =>
                               match r with
                               | OK _ =>
                                 let homedir' := update_subtree pathname
                                                                (delete_from_dir name (TreeDir dnum tree_elem)) homedir in
                                 find_subtree (homedirs tid) tree' = Some homedir'
                               | Err _ => find_subtree (homedirs tid) tree' = Some homedir
                               end
                             | TryAgain _ => False
                             | SyscallFailed => find_subtree (homedirs tid) tree' = Some homedir
                             end |})
                 (delete dnum name).
  Proof.
    unfold delete; intros.
    unfold cprog_spec; intros;
      eapply cprog_ok_weaken;
      [ monad_simpl; eapply write_syscall_ok;
        eauto using opt_delete_ok | ];
      simplify; finish.
    unfold precondition_stable; simplify; simpl.
    intuition eauto.
    eapply homedir_rely_preserves_subtrees; eauto.

    unfold same_fs_update; intros.
    destruct_goal_matches.
    eapply homedir_rely_preserves_subtrees in H4; eauto.
    erewrite DirTreeInodes.alter_inum_to_alter_path; eauto.
    erewrite DirTreeNames.alter_to_update; eauto; simpl; auto.

    eapply is_allowed_fs_update; intros.
    destruct_goal_matches.
    eapply homedir_rely_preserves_subtrees in H4; eauto.
    eapply homedir_guarantee_alter; eauto.

    step; finish.
    destruct r; intuition eauto.
    destruct_goal_matches; subst; eauto.
    eapply homedir_rely_preserves_homedir in H6; eauto.
    erewrite find_subtree_update_subtree_child; eauto.
    subst; eauto.
  Qed.

  Definition rename dnum srcpath srcname dstpath dstname :=
    write_syscall None
                  (fun mscs => OptFS.rename (fsxp P) dnum srcpath srcname dstpath dstname mscs)
                  (fun '(r, _) tree =>
                     match r with
                     | OK _ => alter_inum
                                dnum (fun d => match d with
                                            | TreeDir _ tree_elem =>
                                              match find_subtree srcpath (TreeDir dnum tree_elem) with
                                              | Some (TreeDir srcnum srcents) =>
                                                match find_dirlist srcname srcents with
                                                | Some subtree =>
                                                  let pruned := tree_prune srcnum srcents srcpath srcname (TreeDir dnum tree_elem) in
                                                  match find_subtree dstpath pruned with
                                                  | Some (TreeDir dstnum dstents) =>
                                                    let renamed := tree_graft dstnum dstents dstpath dstname subtree pruned in
                                                    renamed
                                                  | _ => d
                                                  end
                                                | _ => d
                                                end
                                              | _ => d
                                              end
                                            | _ => d
                                            end) tree
                     | Err _ => tree
                     end).

  Theorem rename_ok : forall tid dnum srcpath srcname dstpath dstname,
      cprog_spec G tid
                 (fun '(tree, homedirs, homedir, cwd, tree_elem) sigma =>
                    {| precondition :=
                         fs_inv(P, sigma, tree, homedirs) /\
                         local_l tid (Sigma.l sigma) = Unacquired /\
                         homedir_disjoint homedirs tid /\
                         find_subtree (homedirs tid) tree = Some homedir /\
                         find_subtree cwd homedir = Some (TreeDir dnum tree_elem);
                       postcondition :=
                         fun sigma' r =>
                           exists tree',
                             fs_inv(P, sigma', tree', homedirs) /\
                             local_l tid (Sigma.l sigma') = Unacquired /\
                             match r with
                             | Done (r, _) =>
                               match r with
                               | OK _ =>
                                 exists srcnum srcents subtree dstnum dstents,
                                 find_subtree srcpath (TreeDir dnum tree_elem) =
                                 Some (TreeDir srcnum srcents) /\
                                 let pruned := tree_prune srcnum srcents srcpath srcname (TreeDir dnum tree_elem) in
                                 find_subtree dstpath pruned = Some (TreeDir dstnum dstents) /\
                                 let renamed := tree_graft dstnum dstents dstpath dstname subtree pruned in
                                 let homedir' := update_subtree cwd renamed homedir in
                                 find_subtree (homedirs tid) tree' = Some homedir'
                               | Err _ => find_subtree (homedirs tid) tree' = Some homedir
                               end
                             | TryAgain _ => False
                             | SyscallFailed => find_subtree (homedirs tid) tree' = Some homedir
                             end |})
                 (rename dnum srcpath srcname dstpath dstname).
  Proof using Type.
    unfold rename; intros.
    unfold cprog_spec; intros;
      eapply cprog_ok_weaken;
      [ monad_simpl; eapply write_syscall_ok;
        eauto using opt_rename_ok | ];
      simplify; finish.
    unfold precondition_stable; simplify; simpl.
    intuition eauto.
    eapply homedir_rely_preserves_subtrees; eauto.

    unfold same_fs_update; intros.
    destruct r; simpl.
    eapply homedir_rely_preserves_subtrees in H4; eauto.
    erewrite DirTreeInodes.alter_inum_to_alter_path; eauto.
    erewrite DirTreeNames.alter_to_update; eauto; simpl; auto.
    destruct_goal_matches; eauto using DirTreeInodes.update_subtree_same.

    eapply is_allowed_fs_update; intros.
    destruct_goal_matches.
    eapply homedir_rely_preserves_subtrees in H4; eauto.
    eapply homedir_guarantee_alter; eauto.

    step; finish.
    destruct r; intuition eauto.
    destruct_goal_matches; simplify; repeat simpl_match.
    descend; intuition eauto.
    eapply homedir_rely_preserves_homedir in H6; eauto.

    erewrite find_subtree_update_subtree_child; eauto.
    subst; eauto.
  Qed.

  (* wrap unverified syscalls *)

  Definition statfs :=
    retry_readonly_syscall (fun mscs => OptFS.statfs (fsxp P) mscs).

  Definition mkdir dnum name :=
    write_syscall None
                  (fun mscs => OptFS.mkdir (fsxp P) dnum name mscs)
                  (fun _ tree => tree).

  Definition file_get_sz inum :=
    retry_readonly_syscall (fun mscs => OptFS.file_get_sz (fsxp P) inum mscs).

  Definition file_set_sz inum sz :=
    write_syscall None
                  (fun mscs => OptFS.file_set_sz (fsxp P) inum sz mscs)
                  (fun _ tree => tree).

  Definition readdir dnum :=
    retry_readonly_syscall (fun mscs => OptFS.readdir (fsxp P) dnum mscs).

  Definition tree_sync :=
    write_syscall None
                  (fun mscs => OptFS.tree_sync (fsxp P) mscs)
                  (fun _ tree => tree).

  Definition file_sync inum :=
    write_syscall None
                  (fun mscs => OptFS.file_sync (fsxp P) inum mscs)
                  (fun _ tree => tree).

  Definition update_fblock inum off b :=
    write_syscall None
                  (fun mscs => OptFS.update_fblock (fsxp P) inum off b mscs)
                  (fun _ tree => tree).

  Definition mksock dnum name :=
    write_syscall None
                  (fun mscs => OptFS.mksock (fsxp P) dnum name mscs)
                  (fun _ tree => tree).

  Definition umount :=
    write_syscall None
                  (fun mscs => OptFS.umount (fsxp P) mscs)
                  (fun _ tree => tree).

End ConcurrentFS.

(* special identifier used for ghost variables, which are never allocated *)
Definition absId : ident := 1000.

Definition init (fsxp: fs_xparams) (mscs: memstate) : cprog FsParams :=
  cacheId <- Alloc empty_cache;
    memstateId <- Alloc mscs;
    Ret {|
        ccache:=cacheId;
        fsmem:=memstateId;
        fsxp:=fsxp;

        fstree:=absId;
        fshomedirs:=absId; |}.

(* Local Variables: *)
(* company-coq-local-symbols: (("Sigma" . ?Σ) ("sigma" . ?σ) ("sigma'" . (?σ (Br . Bl) ?'))) *)
(* End: *)
