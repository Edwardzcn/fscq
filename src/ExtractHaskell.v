Require Import ExtrHaskellPrelude.
Require Import ExtrHaskellMap.
Require Import AsyncFS.
Require Import StringUtils.
Require ConcurrentFS.
Require ConcurCompile.
Require TranslateTest.

Extraction Language Haskell.

(* Optimize away some noop-like wrappers. *)
Extraction Inline Prog.pair_args_helper.

(* Uncomment the next line to enable eventlog-based profiling *)
(* Extract Inlined Constant Prog.progseq => "Profile.progseq __FILE__ __LINE__". *)

(* Variables are just integers in the interpreter *)
Extract Inlined Constant Prog.vartype => "Prelude.Integer".

(* Hook up our untrusted replacement policy. *)
Extract Inlined Constant Cache.eviction_state  => "Evict.EvictionState".
Extract Inlined Constant Cache.eviction_init   => "Evict.eviction_init".
Extract Inlined Constant Cache.eviction_update => "Evict.eviction_update".
Extract Inlined Constant Cache.eviction_choose => "Evict.eviction_choose".

Extract Inlined Constant Log.should_flushall => "Prelude.False".

Extract Inlined Constant StringUtils.String_as_OT.string_compare =>
  "(\x y -> if x Prelude.== y then Prelude.EQ else
            if x Prelude.< y then Prelude.LT else Prelude.GT)".

Extract Inlined Constant DirName.ascii2byte => "Word.ascii2byte".
Extract Inlined Constant DirName.wbitset => "Word.wbitset".

Extraction Inline Logic.eq_rect_r Logic.eq_rect.

Cd "../codegen".
Recursive Extraction Library ConcurrentFS.
Recursive Extraction Library AsyncFS.
Recursive Extraction Library ConcurCompile.
Recursive Extraction Library TranslateTest.
