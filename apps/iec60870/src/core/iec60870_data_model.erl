%%% @doc Data-model behaviour (docs/DESIGN.md section 6).
%%%
%%% The data model is the server's **current-value store**: it answers
%%% interrogation and it decides whether an `update/3' is a real change (and so
%%% worth a spontaneous ASDU). It is deliberately separate from the per-group
%%% event queue of docs/DESIGN.md section 5.
%%%
%%% The callbacks take an opaque `State' and thread a possibly-updated one back
%%% ({@link write/4}); an implementation need not be a process (the default
%%% {@link iec60870_dm_ets} keeps a `public' ETS table owned by whoever calls
%%% `init/1'). `iec60870_server_ctl' is the sole caller and serialises them.
%%%
%%% Counter support (`read_counter' / `freeze_counters') arrives with counter
%%% interrogation in phase 7.
-module(iec60870_data_model).

-export([is_significant_change/2]).

-export_type([state/0, coa/0, fold_group/0]).

-type state() :: term().
-type coa() :: 0..65535.
-type fold_group() :: station | 1..16.

-callback init(Args :: term()) -> {ok, state()}.

-callback terminate(state()) -> ok.

%% Current value at `(Coa, Ioa)', or `not_found'.
-callback read(state(), coa(), Ioa :: non_neg_integer()) ->
    {ok, iec60870_point:point()} | not_found.

%% Store a value; `Changed' is `false' when it is not a significant change over
%% what was already there (see {@link is_significant_change/2}).
-callback write(state(), coa(), Ioa :: non_neg_integer(), iec60870_point:point()) ->
    {ok, state(), Changed :: boolean()}.

%% Fold the interrogable points of one common address, the fold function seeing
%% each point's IOA. `station' visits every one; `1..16' visits only points
%% assigned to that interrogation group.
-callback fold(state(), coa(), fold_group(),
               fun((Ioa :: non_neg_integer(), iec60870_point:point(), Acc) -> Acc),
               Acc) -> Acc
    when Acc :: term().

%% Every common address the model currently holds points for.
-callback coas(state()) -> [coa()].

%%%===================================================================
%%% Shared change policy
%%%===================================================================

%% @doc Whether writing `New' over `Old' is a change worth a spontaneous
%% transmission. A new IOA always is; otherwise the value and the (order-
%% independent) quality must both be unchanged to suppress it. A bare timestamp
%% refresh is not a change.
-spec is_significant_change(iec60870_point:point() | not_found,
                            iec60870_point:point()) -> boolean().
is_significant_change(not_found, _New) ->
    true;
is_significant_change(Old, New) ->
    maps:get(value, Old) =/= maps:get(value, New)
        orelse lists:sort(maps:get(quality, Old, []))
               =/= lists:sort(maps:get(quality, New, [])).
