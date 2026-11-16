-module(iec60870_data_model).
-moduledoc """
Data-model behaviour (`docs/DESIGN.md` section 6).

The data model is the server's **current-value store**: it answers
interrogation and it decides whether an `update/3` is a real change (and so
worth a spontaneous ASDU). It is deliberately separate from the per-group
event queue of `docs/DESIGN.md` section 5.

The callbacks take an opaque `State` and thread a possibly-updated one back
(`c:write/4`); an implementation need not be a process (the default
`m:iec60870_dm_ets` keeps a `public` ETS table owned by whoever calls
`c:init/1`). `m:iec60870_server_ctl` is the sole caller and serialises them.

Counter interrogation (`docs/DESIGN.md` section 7) mirrors general
interrogation with its own fold and an explicit freeze/reset step
(`c:fold_counters/5` / `c:freeze_counters/4`); counters are excluded from
`c:fold/5` (see `iec60870_point:is_counter/1`) so the two families never see
each other's points.
""".

-export([is_significant_change/2]).

-export_type([state/0, coa/0, fold_group/0, counter_group/0, freeze/0]).

-type state() :: term().
-type coa() :: 0..65535.
-type fold_group() :: station | 1..16.
-type counter_group() :: station | 1..4.
-type freeze() :: read | freeze_no_reset | freeze_reset | reset.

-callback init(Args :: term()) -> {ok, state()}.

-callback terminate(state()) -> ok.

-doc "Current value at `(Coa, Ioa)`, or `not_found`.".
-callback read(state(), coa(), Ioa :: non_neg_integer()) ->
    {ok, iec60870_point:point()} | not_found.

-doc """
Store a value; `Changed` is `false` when it is not a significant change over
what was already there (see `is_significant_change/2`).
""".
-callback write(state(), coa(), Ioa :: non_neg_integer(), iec60870_point:point()) ->
    {ok, state(), Changed :: boolean()}.

-doc """
Fold the interrogable points of one common address, the fold function seeing
each point's IOA. `station` visits every one; `1..16` visits only points
assigned to that interrogation group.
""".
-callback fold(state(), coa(), fold_group(),
               fun((Ioa :: non_neg_integer(), iec60870_point:point(), Acc) -> Acc),
               Acc) -> Acc
    when Acc :: term().

-doc "Every common address the model currently holds points for.".
-callback coas(state()) -> [coa()].

-doc """
Fold the counter points of one common address, analogous to `c:fold/5` but
scoped to `m_it_na_1` / `m_it_tb_1` points (`iec60870_point:is_counter/1`)
and to the four counter interrogation groups rather than 1..16.
""".
-callback fold_counters(state(), coa(), counter_group(),
                        fun((Ioa :: non_neg_integer(), iec60870_point:point(), Acc) -> Acc),
                        Acc) -> Acc
    when Acc :: term().

-doc """
Apply a counter interrogation command's freeze qualifier to every counter
of `(Coa, Group)` before the caller reads them back via `c:fold_counters/5`:
`read` / `freeze_no_reset` leave the stored value untouched (freezing it
for read-out is implicit — `c:fold_counters/5` always reads the current
value); `freeze_reset` / `reset` zero it.
""".
-callback freeze_counters(state(), coa(), counter_group(), freeze()) -> {ok, state()}.

-doc """
Remove the point at `(Coa, Ioa)` (missing points are fine): it no longer
answers interrogation or read commands, and a later write of it counts as new.
Optional — without it `iec60870_server:remove/2` is ignored with a warning.
""".
-callback delete(state(), coa(), Ioa :: non_neg_integer()) -> {ok, state()}.

-optional_callbacks([delete/3]).

%%%===================================================================
%%% Shared change policy
%%%===================================================================

-doc """
Whether writing `New` over `Old` is a change worth a spontaneous
transmission. A new IOA always is; otherwise the value and the
(order-independent) quality must both be unchanged to suppress it. A bare
timestamp refresh is not a change.
""".
-spec is_significant_change(iec60870_point:point() | not_found,
                            iec60870_point:point()) -> boolean().
is_significant_change(not_found, _New) ->
    true;
is_significant_change(Old, New) ->
    maps:get(value, Old) =/= maps:get(value, New)
        orelse lists:sort(maps:get(quality, Old, []))
               =/= lists:sort(maps:get(quality, New, [])).
