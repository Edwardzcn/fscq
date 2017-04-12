Require Import CCL.
Require Import FSProtocol.
Require Import ConcurrentFS.

Import BFile.

Section ConcurrentCopy.

  Variable P:FsParams.

  Definition bind T T' (p: cprog (SyscallResult T')) (p': T' -> cprog (SyscallResult T)) :
    cprog (SyscallResult T) :=
    r <- p;
      match r with
      | Done v => p' v
      | SyscallFailed => Ret SyscallFailed
      | TryAgain => Ret TryAgain (* will not happen *)
      end.

  Definition copy inum dnum dstname :=
    bind (file_get_attr P inum)
         (fun '(attr, _) =>
            bind (create P dnum dstname)
                 (fun '(r, _) =>
                    match r with
                    | Errno.OK inum' =>
                      bind (file_set_attr P inum' attr)
                           (fun '(r, _) =>
                              match r with
                              | Errno.OK _ => Ret (Done (Some inum'))
                              | Errno.Err _ => Ret (Done None)
                              end)
                    | Errno.Err _ => Ret (Done None)
                    end)).

  Hint Extern 1 {{ file_get_attr _ _; _ }} => apply file_get_attr_ok : prog.
  Hint Extern 1 {{ file_set_attr _ _ _; _ }} => apply file_set_attr_ok : prog.
  Hint Extern 1 {{ create _ _ _; _ }} => apply create_ok : prog.

  Ltac finish := repeat match goal with
                        | [ |- _ /\ _ ] => split; trivial
                        | _ => descend
                        end;
                 simpl in *; subst;
                 (intuition (try eassumption; eauto)); try congruence.

  Hint Resolve DirTreeNames.find_subtree_tree_names_distinct.

  Lemma update_graft_to_single_graft:
    forall (dnum : nat) (dstname : string) (homedir : dirtree)
      (dpath : list string) (dents : list (string * dirtree))
      (f' f0 : dirtree),
      find_subtree dpath homedir = Some (TreeDir dnum dents) ->
      DirTreeNames.tree_names_distinct homedir ->
      DirTreeNames.tree_names_distinct (tree_graft dnum dents dpath dstname f0 homedir) ->
      update_subtree (dpath ++ dstname :: nil) f'
                     (tree_graft dnum dents dpath dstname f0 homedir) =
      tree_graft dnum dents dpath dstname f' homedir.
  Proof.
    unfold tree_graft; intros.
    simpl.
    erewrite DirTreeNames.update_subtree_app; swap 1 3; swap 2 3.
    erewrite find_update_subtree; eauto.
    rewrite update_update_subtree_same.
    simpl.
    f_equal.
    f_equal.
    assert (DirTreeNames.tree_names_distinct (TreeDir dnum dents)) by eauto.
    clear H H0 H1.
    induction dents; simpl; intuition.
    destruct_goal_matches.
    destruct_goal_matches; simpl; repeat simpl_match.
    f_equal.
    erewrite DirTreeNames.update_subtree_helper_already_found; eauto.
    f_equal; eauto.
    eauto.
  Qed.

  Theorem copy_ok : forall inum dnum dstname tid,
      cprog_spec (fs_guarantee P) tid
                 (fun '(tree, homedirs, homedir, fpath, dpath, f, dents) sigma =>
                    {| precondition :=
                         fs_inv(P, sigma, tree, homedirs) /\
                         local_l tid (Sigma.l sigma) = Unacquired /\
                         homedir_disjoint homedirs tid /\
                         find_subtree (homedirs tid) tree = Some homedir /\
                         find_subtree fpath homedir = Some (TreeFile inum f) /\
                         find_subtree dpath homedir = Some (TreeDir dnum dents);
                       postcondition :=
                         fun sigma' r =>
                           exists tree',
                             fs_inv(P, sigma', tree', homedirs) /\
                             local_l tid (Sigma.l sigma') = Unacquired /\
                             match r with
                             | Done r =>
                               match r with
                               | Some inum' =>
                                 let f' := mk_dirfile nil (DFAttr f) in
                                 let homedir' :=
                                     tree_graft dnum dents dpath dstname (TreeFile inum' f') homedir in
                                 find_subtree (homedirs tid) tree' = Some homedir'
                               | None => True
                               end
                             | TryAgain => False
                             | SyscallFailed => True
                             end |})
                 (copy inum dnum dstname).
  Proof.
    unfold copy, bind.
    step; finish.
    destruct r; destruct_goal_matches; try (step; finish).

    destruct r; destruct_goal_matches; try (step; finish).
    eapply find_subtree_tree_graft; eauto.

    destruct r; destruct_goal_matches; try (step; finish).
    replace (find_subtree (homedirs tid) tree'1).
    f_equal.
    apply update_graft_to_single_graft; auto.
    eapply DirTreeNames.find_subtree_tree_names_distinct; eauto.
    eapply fs_invariant_tree_names_distinct; eauto.

    eapply DirTreeNames.find_subtree_tree_names_distinct; eauto.
    eapply fs_invariant_tree_names_distinct; eauto.

    Grab Existential Variables.
    all: auto.
  Qed.

End ConcurrentCopy.