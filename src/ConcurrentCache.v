Require Import CoopConcur.
Require Import CoopConcurAuto.
Require Import Protocols.
Require Import Star.
Require Import DiskReaders.
Import List.
Import List.ListNotations.
Import Hlist.HlistNotations.

Require Import MemCache.
Require Import WriteBufferSet.

Section ConcurrentCache.

  Definition Sigma := defState [Cache; WriteBuffer] [Cache; WriteBuffer; DISK; Disk].

  Section Variables.

    Tactic Notation "var" constr(n) constr(f) :=
      let t := constr:(ltac:(hmember n (f Sigma))) in
      let t' := eval cbn in t in
          exact (t': var (f Sigma) _).

    Tactic Notation "mvar" constr(n) := var n mem_types.
    Tactic Notation "absvar" constr(n) := var n abstraction_types.

    (* memory variables *)
    Definition mCache := ltac:(mvar 0).
    Definition mWriteBuffer := ltac:(mvar 1).

    (* abstraction ("virtual") variables *)
    Definition vCache := ltac:(absvar 0).
    Definition vWriteBuffer := ltac:(absvar 1).
    (* the linearized disk, which evolves at each syscall *)
    Definition vDisk0 := ltac:(absvar 2).
    (* the disk from the perspective of the current syscall *)
    Definition vdisk := ltac:(absvar 3).

  End Variables.

  Definition no_wb_reader_conflict c wb :=
    forall a, cache_get c a = Invalid ->
         wb_get wb a = WbMissing.

  Definition cacheI : Invariant Sigma :=
    fun d m s =>
      get mCache m = get vCache s /\
      get mWriteBuffer m = get vWriteBuffer s /\
      cache_rep d (get vCache s) (get vDisk0 s) /\
      wb_rep (get vDisk0 s) (get vWriteBuffer s) (get vdisk s) /\
      no_wb_reader_conflict (get vCache s) (get vWriteBuffer s).

  (** a locking-like protocol, but true for any provable program
      due to the program semantics themselves *)
  Definition readers_locked tid (vd vd': DISK) :=
      (forall a v tid', vd a = Some (v, Some tid') ->
                   tid <> tid' ->
                   vd' a = Some (v, Some tid')).

  Lemma readers_locked_refl : forall tid vd,
      readers_locked tid vd vd.
  Proof.
    unfold readers_locked; eauto.
  Qed.

  Lemma readers_locked_trans : forall tid vd vd' vd'',
      readers_locked tid vd vd' ->
      readers_locked tid vd' vd'' ->
      readers_locked tid vd vd''.
  Proof.
    unfold readers_locked; eauto.
  Qed.

  (* not sure whether to say this about vDisk0, vDisk, or both *)
  Definition cacheR (tid:TID) : Relation Sigma :=
    fun s s' =>
      let vd := get vDisk0 s in
      let vd' := get vDisk0 s' in
      same_domain vd vd' /\
      readers_locked tid vd vd'.

  Hint Immediate same_domain_refl same_domain_trans.
  Hint Immediate readers_locked_refl readers_locked_trans.

  Theorem cacheR_trans_closed : forall tid s s',
      star (cacheR tid) s s' ->
      cacheR tid s s'.
  Proof.
    intro tid.
    apply trans_closed; unfold cacheR; intuition eauto.
  Qed.

  Definition delta : Protocol Sigma :=
    defProtocol cacheI cacheR cacheR_trans_closed.

  (* abstraction helpers *)

  Definition modify_cache (up: Cache -> Cache) rx : prog Sigma :=
    c <- Get mCache;
      _ <- Assgn mCache (up c);
      _ <- var_update vCache up;
      rx tt.

  Definition modify_wb (up: WriteBuffer -> WriteBuffer) rx : prog Sigma :=
    wb <- Get mWriteBuffer;
      _ <- Assgn mWriteBuffer (up wb);
      _ <- var_update vWriteBuffer up;
      rx tt.

  (** safe read: returns None upon cache miss  *)
  Definition cache_maybe_read a rx : prog Sigma :=
    c <- Get mWriteBuffer;
      match wb_val c a with
      | Some v => rx (Some v)
      | None =>
        c <- Get mCache;
          rx (cache_val c a)
      end.

  (** Prepare to fill address a, locking the address and marking it
  invalid in the cache to signal the lock to concurrent threads. *)
  Definition prepare_fill a rx : prog Sigma :=
    tid <- GetTID;
      _ <- StartRead_upd a;
      (* note that no updates to Disk are needed since the readers are
    hidden *)
      _ <- var_update vDisk0
        (fun vd => add_reader vd a tid);
      _ <- modify_cache (fun c => cache_add c a Invalid);
      rx tt.

  Definition cache_fill a rx : prog Sigma :=
    _ <- prepare_fill a;
      _ <- Yield a;
      v <- FinishRead_upd a;
      _ <- var_update vDisk0
        (fun vd => remove_reader vd a);
      _ <- modify_cache (fun c => cache_add c a (Clean v));
      rx v.

  (** buffer a new write: fails (returns false) if the write overlaps
  with the address being read filled *)
  Definition cache_try_write a v rx : prog Sigma :=
    c <- Get mCache;
      match cache_get c a with
      | Invalid => rx false
      | _ =>
        _ <- modify_wb (fun wb => wb_write wb a v);
          _ <- var_update vdisk
            (fun vd => upd vd a v);
          rx true
      end.

  Fixpoint cache_add_all (c: Cache) (entries: list (addr * valu)) : Cache :=
    match entries with
    | nil => c
    | (a, v) :: es => cache_add_all (cache_add c a (Dirty v)) es
    end.

  (** commit all the buffered writes into the global cache

    safety is provided by the invariant no_wb_reader_conflict enforced
    by cache_write's checks *)
  Definition cache_commit rx : prog Sigma :=
    c <- Get mCache;
      wb <- Get mWriteBuffer;
      _ <- modify_cache (fun c => cache_add_all c (wb_writes wb));
      _ <- var_update vDisk0 (fun d => upd_buffered_writes d (wb_writes wb));
      _ <- modify_wb (fun _ => emptyWriteBuffer);
      rx tt.

  (** abort all buffered writes, restoring vDisk0 *)
  Definition cache_abort rx : prog Sigma :=
    _ <- modify_wb (fun _ => emptyWriteBuffer);
      _ <- GhostUpdate (fun s =>
                         let vd' := hide_readers (get vDisk0 s) in
                         set vdisk vd' s);
      rx tt.

  Definition cache_read a rx : prog Sigma :=
    opt_v <- cache_maybe_read a;
      match opt_v with
      | Some v => rx (Some v)
      | None => _ <- cache_abort;
                 v <- cache_fill a;
                 rx None
      end.

  Definition cache_write a v rx : prog Sigma :=
    ok <- cache_try_write a v;
      if ok then
        rx true
      else
        _ <- cache_abort;
      _ <- Yield a;
      rx false.

  (** TODO: need to write a into cache from WriteBuffer, evict from
  cache (writing if necessary), and then note in place of the
  writebuffer that rollback is no longer possible *)
  Definition cache_writeback (a: addr) rx : prog Sigma :=
    wb <- Get mWriteBuffer;
      rx tt.

  (* start of automation *)

  Lemma unfold_invariant : forall d m s,
      invariant delta d m s ->
      ltac:(let t := eval simpl in (invariant delta d m s) in
                let t := eval unfold cacheI in t in
                    exact t).
  Proof.
    auto.
  Qed.

  Lemma unfold_protocol : forall tid s s',
      guar delta tid s s' ->
      ltac:(let t := eval simpl in (guar delta tid s s') in
                let t := eval unfold cacheR in t in
                    exact t).
  Proof.
    eauto.
  Qed.

  Ltac learn_protocol :=
    match goal with
    | [ H: invariant delta _ _ _ |- _ ] =>
      learn that (unfold_invariant H)
    | [ H: guar delta _ _ _ |- _ ] =>
      learn that (unfold_protocol H)
    end.

  Ltac prove_protocol :=
    match goal with
    | [ |- guar delta ?tid _ _ ] =>
      simpl; unfold cacheR
    | [ |- invariant delta _ _ _ ] =>
      simpl; unfold cacheI
    end.

  Ltac descend :=
    match goal with
    | [ |- _ /\ _ ] => split
    | [ |- exists (_:unit), _ ] => exists tt
    end.

  Ltac reduce_hlist :=
    match goal with
    | [ |- context[get _ (set _ _ _) ] ] =>
      progress repeat rewrite ?get_set, ?get_set_other by auto
    end.

  Lemma cache_val_mem {m: memory Sigma} {s: abstraction Sigma} :
      get mCache m = get vCache s ->
      cache_val (get mCache m) = cache_val (get vCache s).
  Proof.
    congruence.
  Qed.

  Lemma cache_get_mem {m: memory Sigma} {s: abstraction Sigma} :
      get mCache m = get vCache s ->
      cache_get (get mCache m) = cache_get (get vCache s).
  Proof.
    congruence.
  Qed.

  Ltac replace_mem_val :=
    match goal with
    | [ H: get mWriteBuffer ?m = get vWriteBuffer _,
           H': context[ get mWriteBuffer ?m ] |- _ ] =>
      lazymatch type of H' with
      | Learnt => fail
      | _ => rewrite H in H'
      end
    | [ H: get mWriteBuffer ?m = get vWriteBuffer _
        |- context[ get mWriteBuffer ?m ] ] =>
      rewrite H
    | [ H: get mCache ?m = get vCache _,
           H': context[ cache_val (get mCache ?m) ] |- _ ] =>
      rewrite (cache_val_mem H) in H'
    | [ H: get mCache ?m = get vCache _,
           H': context[ cache_get (get mCache ?m) ] |- _ ] =>
      rewrite (cache_get_mem H) in H'
    end.

  Ltac simp_hook := fail.

  Ltac simplify_step :=
    match goal with
    | [ |- forall _, _ ] => intros
    | _ => learn_protocol
    | _ => deex
    | _ => progress destruct_ands
    | _ => inv_opt
    | _ => progress subst
    | _ => replace_mem_val
    | _ => reduce_hlist
    | _ => simp_hook
    | _ => descend
    | _ => prove_protocol
    end.

  Ltac finish := time "finish"
                      lazymatch goal with
                      | [ |- valid _ _ _ _ ] => idtac
                      | _ => eauto;
                            try solve [simpl (mem_types _) in *;
                                       simpl (abstraction_types _) in *;
                                       congruence]
                      end.

  Ltac simplify :=
    repeat (time "simplify_step" simplify_step).

  (* hook up new finish and simplify to existing hoare tactic; this
    isn't clean, need better extensibility *)

  Ltac step_simplifier ::= simplify.
  Ltac step_finisher ::= finish.

  (* prove hoare specs *)

  Section SpecLemmas.

    Lemma disk_no_reader : forall d c vd0 wb vd a v,
      cache_rep d c vd0 ->
      wb_rep vd0 wb vd ->
      cache_get c a = Missing ->
      wb_get wb a = WbMissing ->
      vd a = Some v ->
      d a = Some (v, None).
    Proof.
      unfold const; intros.
      specialize (H a).
      specialize (H0 a).
      simpl_match.
      destruct matches in *;
        intuition auto;
        repeat deex;
        eauto || congruence.
    Qed.

    Lemma no_wb_reader_conflict_stable_invalidate : forall c wb a,
        no_wb_reader_conflict c wb ->
        wb_get wb a = WbMissing ->
        no_wb_reader_conflict (cache_add c a Invalid) wb.
    Proof.
      unfold no_wb_reader_conflict; intros.
      destruct (weq a a0); subst;
        autorewrite with cache in *;
        eauto.
    Qed.

    Lemma no_wb_reader_conflict_stable_write : forall c wb a v,
        cache_get c a <> Invalid ->
        no_wb_reader_conflict c wb ->
        no_wb_reader_conflict c (wb_write wb a v).
    Proof.
      unfold no_wb_reader_conflict; intros.
      destruct (weq a a0); subst;
        rewrite ?wb_get_write_eq, ?wb_get_write_neq
        in * by auto;
        eauto || congruence.
    Qed.

    Lemma same_domain_add_reader : forall d a tid,
        same_domain d (add_reader d a tid).
    Proof.
      unfold same_domain, subset, add_reader; split;
        intros;
        destruct (weq a a0); subst;
          destruct matches in *;
          autorewrite with upd in *;
          eauto.
    Qed.

    Lemma same_domain_remove_reader : forall d a,
        same_domain d (remove_reader d a).
    Proof.
      unfold same_domain, subset, remove_reader; split;
        intros;
        destruct (weq a a0); subst;
          destruct matches in *;
          autorewrite with upd in *;
          eauto.
    Qed.

    Lemma readers_locked_add_reader : forall tid tid' vd a v,
        vd a = Some (v, None) ->
        readers_locked tid vd (add_reader vd a tid').
    Proof.
      unfold readers_locked, add_reader; intros.
      destruct (weq a a0); subst;
        simpl_match;
        autorewrite with upd;
        congruence.
    Qed.

    Lemma readers_locked_remove_reading : forall tid vd a v,
        vd a = Some (v, Some tid) ->
        readers_locked tid vd (remove_reader vd a).
    Proof.
      unfold readers_locked, remove_reader; intros.
      destruct (weq a a0); subst;
        simpl_match;
        autorewrite with upd;
        eauto || congruence.
    Qed.

    Theorem wb_rep_stable_write : forall d wb vd a v0 v,
        wb_rep d wb vd ->
        (* a is in domain *)
        vd a = Some v0 ->
        wb_rep d (wb_write wb a v) (upd vd a v).
    Proof.
      unfold wb_rep; intros.
      specialize (H a0).
      destruct (weq a a0); subst;
        rewrite ?wb_get_write_eq, ?wb_get_write_neq by auto;
        autorewrite with upd;
        eauto.

      destruct matches in *|- ;
        intuition eauto.
    Qed.

  End SpecLemmas.

  Theorem modify_cache_ok : forall up,
      SPEC delta, tid |-
              {{ (_:unit),
               | PRE d m s_i s: get mCache m = get vCache s
               | POST d' m' s_i' s' r:
                   s' = set vCache (up (get vCache s)) s /\
                   m' = set mCache (up (get mCache m)) m /\
                   d' = d /\
                   s_i' = s_i
              }} modify_cache up.
  Proof.
    hoare.
  Qed.

  Hint Extern 1 {{ modify_cache _; _ }} => apply modify_cache_ok : prog.

  Theorem modify_wb_ok : forall up,
      SPEC delta, tid |-
              {{ (_:unit),
               | PRE d m s_i s: get mWriteBuffer m = get vWriteBuffer s
               | POST d' m' s_i' s' r:
                   s' = set vWriteBuffer (up (get vWriteBuffer s)) s /\
                   m' = set mWriteBuffer (up (get mWriteBuffer m)) m /\
                   d' = d /\
                   s_i' = s_i
              }} modify_wb up.
  Proof.
    hoare.
  Qed.

  Hint Extern 1 {{ modify_wb _; _ }} => apply modify_wb_ok : prog.

  Definition sumboolProof P Q (p: {P} + {Q}) : if p then P else Q.
  Proof.
    destruct p; auto.
  Defined.

  Ltac prove_nat_neq :=
    match goal with
    | |- ?n <> ?m =>
      exact (sumboolProof (PeanoNat.Nat.eq_dec n m))
    end.

  Hint Extern 2 (member_index _ <> member_index _) => simpl; prove_nat_neq.

  Hint Resolve wb_val_vd cache_val_vd cache_val_no_reader wb_val_none.

  Opaque mem_types abstraction_types.

  Lemma Some_inv : forall A (v v': A),
      v = v' ->
      Some v = Some v'.
  Proof.
    congruence.
  Qed.

  Hint Resolve Some_inv.

  Theorem cache_maybe_read_ok : forall a,
      SPEC delta, tid |-
              {{ v0,
               | PRE d m s_i s: invariant delta d m s /\
                               get vdisk s a = Some v0
               | POST d' m' s_i' s' r:
                   invariant delta d' m' s' /\
                   get vdisk s' = get vdisk s /\
                   s_i' = s_i /\
                   (r = Some v0 \/
                    r = None /\
                    cache_get (get vCache s') a = Missing)
              }} cache_maybe_read a.
  Proof.
    hoare.
    (* requires case analysis on cache_val at a *)
    admit.
  Admitted.

  Hint Extern 1 {{cache_maybe_read _; _}} => apply cache_maybe_read_ok : prog.

  Hint Resolve
       disk_no_reader
       no_wb_reader_conflict_stable_invalidate
       same_domain_add_reader
       readers_locked_add_reader.

  Hint Resolve wb_get_val_missing.

  Theorem wb_cache_val_none_vd0 : forall d vd0 vd c wb a v,
      cache_rep d c vd0 ->
      wb_rep vd0 wb vd ->
      vd a = Some v ->
      cache_get c a = Missing ->
      wb_get wb a = WbMissing ->
      vd0 a = Some (v, None).
  Proof.
    intros.
    pose proof (wb_val_none ltac:(eauto) ltac:(eauto) ltac:(eauto)).
    deex.
    pose proof (cache_val_no_reader ltac:(eauto) ltac:(eauto) ltac:(eauto)).
    congruence.
  Qed.

  Theorem prepare_fill_ok : forall a,
      SPEC delta, tid |-
              {{ v0,
               | PRE d m s_i s:
                   invariant delta d m s /\
                   cache_get (get vCache s) a = Missing /\
                   (* XXX: not sure exactly why this is a requirement,
                   but it comes from no_wb_reader_conflict *)
                   wb_get (get vWriteBuffer s) a = WbMissing /\
                   get vdisk s a = Some v0 /\
                   guar delta tid s_i s
               | POST d' m' s_i' s' _:
                   invariant delta d' m' s' /\
                   get vDisk0 s' a = Some (v0, Some tid) /\
                   guar delta tid s_i' s'
              }} prepare_fill a.
  Proof.
    hoare.
    eexists; simplify; finish.
    eauto using disk_no_reader.

    hoare;
      (* make sure that all these goals are still around until we
      specifically solve them *)
      let n := numgoals in guard n = 4;
      match goal with
      (* cache_rep stable when adding reader *)
      | [ |- cache_rep (upd _ _ _)
                      (cache_add _ _ _)
                      (add_reader _ _ _) ] => admit
      (* wb_rep insensitive to readers *)
      | [ |- wb_rep (add_reader _ _ _) _ _ ] => admit
      (* add_reader -> upd *)
      | [ |- add_reader _ ?a _ ?a = _ ] => admit
      | [ |- readers_locked _ _ _ ] =>
        (* TODO: debug eauto not being able to follow this chain of
        reasoning *)
        eapply readers_locked_trans; eauto;
          eapply readers_locked_add_reader;
          eapply wb_cache_val_none_vd0; eauto
      end.
  Admitted.

  Hint Extern 1 {{ prepare_fill _; _ }} => apply prepare_fill_ok : prog.

  Lemma others_readers_locked_reading : forall tid vd vd' a v,
      others readers_locked tid vd vd' ->
      vd a = Some (v, Some tid) ->
      vd' a = Some (v, Some tid).
  Proof.
    unfold others, readers_locked; intros; deex.
    eauto.
  Qed.

  Lemma others_rely_readers_locked : forall tid s s',
      others (guar delta) tid s s' ->
      others readers_locked tid (get vDisk0 s) (get vDisk0 s').
  Proof.
    simpl; unfold cacheR, others; intros; deex; eauto.
  Qed.

  Lemma rely_read_lock : forall tid (s s': abstraction Sigma) a v,
      get vDisk0 s a = Some (v, Some tid) ->
      rely delta tid s s' ->
      get vDisk0 s' a = Some (v, Some tid).
  Proof.
    unfold rely; intros.
    induction H0; eauto.
    eauto using others_readers_locked_reading,
    others_rely_readers_locked.
  Qed.

  Ltac simp_hook ::=
       match goal with
       | [ Hrely: rely delta ?tid ?s _,
              H: get vDisk0 ?s _ = Some (_, Some ?tid) |- _ ] =>
         learn that (rely_read_lock H Hrely)
       end.

  Hint Resolve
       same_domain_remove_reader
       readers_locked_remove_reading.

  Lemma cache_rep_disk_val : forall d c vd v rdr a,
      cache_rep d c vd ->
      vd a = Some (v, rdr) ->
      (exists v', d a = Some (v', rdr)).
  Proof.
    intros.
    specialize (H a).
    destruct matches in *; intuition auto; repeat deex;
      try match goal with
          | [ H: ?v = Some (_, ?rdr), H': ?v = Some (_, ?rdr') |- _ ] =>
            assert (rdr = rdr') by congruence
          end; subst;
        eauto.
    congruence.
  Qed.

  Theorem cache_fill_ok : forall a,
      SPEC delta, tid |-
              {{ v0,
               | PRE d m s_i s:
                   invariant delta d m s /\
                   cache_get (get vCache s) a = Missing /\
                   (* XXX: not sure exactly why this is a requirement,
                   but it comes from no_wb_reader_conflict *)
                   wb_get (get vWriteBuffer s) a = WbMissing /\
                   get vdisk s a = Some v0 /\
                   guar delta tid s_i s
               | POST d' m' s_i' s' _:
                   invariant delta d' m' s' /\
                   (* no promise about actually filling the cache -
                   shouldn't affect anybody *)
                   rely delta tid s s' /\
                   guar delta tid s_i' s'
              }} cache_fill a.
  Proof.
    hoare.
    eexists; simplify; finish.
    hoare.
    assert (exists v, d1 a = Some (v, Some tid)).
    eauto using cache_rep_disk_val.
    deex.
    eexists; simplify; finish.

    hoare;
      let n := numgoals in guard n = 4;
      match goal with
      (* cache_rep stable when adding reader *)
      | [ |- cache_rep (upd _ _ _)
                      (cache_add _ _ _)
                      (remove_reader _ _) ] => admit
      (* wb_rep insensitive to readers *)
      | [ |- wb_rep (remove_reader _ _) _ _ ] => admit
      (* clean addresses irrelevant *)
      | [ |- no_wb_reader_conflict (cache_add _ _ _) _ ] => admit
      (* XXX: not provable. Problematic step introduced by
            prepare_fill, which should precisely specify everything it
            did to s so we can prove together with FinishRead the
            effect is the same as a rely *)
      | [ |- rely delta _ _ _ ] => admit
      end.
  Admitted.

  Hint Extern 1 {{cache_fill _; _}} => apply cache_fill_ok.

  Hint Resolve upd_eq.
  Hint Resolve wb_rep_stable_write.

  Lemma cache_not_invalid_1 : forall c a v,
      cache_get c a = Clean v ->
      cache_get c a <> Invalid.
  Proof. congruence. Qed.

  Lemma cache_not_invalid_2 : forall c a v,
      cache_get c a = Dirty v ->
      cache_get c a <> Invalid.
  Proof. congruence. Qed.

  Lemma cache_not_invalid_3 : forall c a,
      cache_get c a = Missing ->
      cache_get c a <> Invalid.
  Proof. congruence. Qed.

  Hint Resolve no_wb_reader_conflict_stable_write.
  Hint Resolve
       cache_not_invalid_1
       cache_not_invalid_2
       cache_not_invalid_3.


  Theorem cache_try_write_ok : forall a v,
      SPEC delta, tid |-
              {{ v0,
               | PRE d m s_i s:
                   invariant delta d m s /\
                   get vdisk s a = Some v0 /\
                   guar delta tid s_i s
               | POST d' m' s_i' s' r:
                   invariant delta d' m' s' /\
                   (r = true -> get vdisk s' = upd (get vdisk s) a v) /\
                   get vDisk0 s' = get vDisk0 s /\
                   guar delta tid s s' /\
                   guar delta tid s_i' s'
              }} cache_try_write a v.
  Proof.
    hoare.
  Qed.

  Hint Resolve wb_rep_empty.

  Theorem cache_commit_ok :
      SPEC delta, tid |-
              {{ (_:unit),
               | PRE d m s_i s:
                   invariant delta d m s
               | POST d' m' s_i' s' r:
                   invariant delta d' m' s' /\
                   hide_readers (get vDisk0 s') = get vdisk s /\
                   get vdisk s' = get vdisk s /\
                   guar delta tid s s' /\
                   s_i' = s_i
              }} cache_commit.
  Proof.
    hoare.
  Admitted.

  Lemma wb_rep_id : forall vd,
      wb_rep vd emptyWriteBuffer (hide_readers vd).
  Proof.
    unfold wb_rep, hide_readers; intros.
    rewrite wb_get_empty.
    destruct matches.
  Qed.

  Lemma no_wb_reader_conflict_empty : forall c,
      no_wb_reader_conflict c emptyWriteBuffer.
  Proof.
    unfold no_wb_reader_conflict; intros;
      rewrite wb_get_empty;
      auto.
  Qed.

  Hint Resolve wb_rep_id no_wb_reader_conflict_empty.

  Theorem cache_abort_ok :
    SPEC delta, tid |-
  {{ (_:unit),
   | PRE d m s_i s:
       invariant delta d m s
   | POST d' m' s_i' s' _:
       invariant delta d' m' s' /\
       get vdisk s' = hide_readers (get vDisk0 s) /\
       get vDisk0 s' = get vDisk0 s /\
       get vCache s' = get vCache s /\
       get vWriteBuffer s' = emptyWriteBuffer /\
       guar delta tid s s' /\
       s_i' = s_i
  }} cache_abort.
  Proof.
    hoare.
  Qed.

  Hint Extern 1 {{cache_abort; _}} => apply cache_abort_ok : prog.

  Lemma hide_readers_eq : forall (d: DISK) a v,
      d a = Some v ->
      hide_readers d a = Some (fst v).
  Proof.
    unfold hide_readers; intros; simpl_match.
    destruct v; auto.
  Qed.

  Lemma hide_readers_eq' : forall (d: DISK) a v,
      hide_readers d a = Some v ->
      (exists v0, d a = Some v0).
  Proof.
    unfold hide_readers; intros;
      destruct (d a).
    eauto.
    congruence.
  Qed.

  Lemma same_domain_hide_readers : forall d d',
      same_domain (hide_readers d) (hide_readers d') ->
      same_domain d d'.
  Proof.
    unfold same_domain, subset; intuition eauto.
    specialize (H0 _ _ (hide_readers_eq _ H)); deex.
    eapply hide_readers_eq'; eauto.

    specialize (H1 _ _ (hide_readers_eq _ H)); deex.
    eapply hide_readers_eq'; eauto.
  Qed.

  Hint Resolve wb_rep_same_domain.

  Lemma same_domain_same_vdisk : forall vd0 wb vd vd0' wb' vd',
      wb_rep vd0 wb vd ->
      wb_rep vd0' wb' vd' ->
      vd = vd' ->
      same_domain vd0 vd0'.
  Proof.
    intros.
    subst vd'.
    apply same_domain_hide_readers.
    transitivity vd; eauto.
    symmetry.
    eauto.
  Qed.

  Hint Resolve same_domain_same_vdisk.

  Theorem cache_read_ok : forall a,
      SPEC delta, tid |-
              {{ v,
               | PRE d m s_i s:
                   invariant delta d m s /\
                   get vdisk s a = Some v /\
                   guar delta tid s_i s
               | POST d' m' s_i' s' r:
                   invariant delta d' m' s' /\
                   (r = None /\
                    get vdisk s' = hide_readers (get vDisk0 s) \/
                    r = Some v /\
                    get vdisk s' = get vdisk s) /\
                   guar delta tid s_i' s'
              }} cache_read a.
  Proof.
    hoare.
    eexists; simplify; finish.
    hoare.
    intuition (auto; try congruence).

    transitivity (get vDisk0 s); eauto.

    admit. (* probably need this from some other spec; knowing vdisk
    didn't change is likely insufficient *)

    intuition (try congruence).
    (* TODO: need to produce value in disk using same_domain or
    something *)
    eexists; simplify; finish.
    replace (get vWriteBuffer s1) with emptyWriteBuffer by auto.
    apply wb_get_empty.
    admit. (* needed to find get vdisk s1 a first *)

    transitivity (get vDisk0 s); eauto.
    transitivity (get vDisk0 s0); eauto.

    admit. (* same as above *)

    step.
    left; intuition auto.
    admit. (* not sure how to prove this, given so many opaque
    transitions; probably some spec is too weak *)
  Admitted.

End ConcurrentCache.
