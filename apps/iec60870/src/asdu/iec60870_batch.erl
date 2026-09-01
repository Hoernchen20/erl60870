%%% @doc Pack many information objects into as few ASDUs as the wire allows
%%% (docs/DESIGN.md section 8).
%%%
%%% Objects are grouped by an already-decided header `{Type, COA, COT}'. Within
%%% a group this module:
%%%
%%% <ul>
%%%   <li>drops duplicate IOAs (last write wins) and sorts ascending;</li>
%%%   <li>emits a `SQ=1' ASDU for every maximal run of consecutive IOAs of
%%%       length &gt;= 2 (chunked so the APDU stays within
%%%       {@link iec60870_asdu:opts()} / the 249-octet ASDU limit and the
%%%       127-object VSQ limit);</li>
%%%   <li>packs everything else into `SQ=0' ASDUs.</li>
%%% </ul>
%%%
%%% Pure and transport-free; shared by the interrogation dump and the
%%% spontaneous `update/3' path.
-module(iec60870_batch).

-include_lib("iec60870/include/iec60870_asdu.hrl").

-export([pack/2]).

-export_type([header/0]).

-type header() :: {iec60870_asdu:type_name(), 0..65535, iec60870_cot:cot()}.

-define(MAX_OCTETS, ?IEC60870_ASDU_MAX_OCTETS).

%% @doc Turn header-tagged object lists into ready-to-encode ASDUs. Groups are
%% processed in the order given; within a group the sequence ASDUs come first,
%% then the `SQ=0' remainder.
-spec pack([{header(), [#object{}]}], iec60870_asdu:opts()) -> [#asdu{}].
pack(Groups, Opts) ->
    lists:append([pack_group(H, Objs, Opts) || {H, Objs} <- Groups, Objs =/= []]).

pack_group({Type, _, _} = Header, Objs, Opts) ->
    Sorted = dedup_sort(Objs),
    Cap1 = cap_sq1(Type, Opts),
    Cap0 = cap_sq0(Type, Opts),
    {SeqAsdus, Singles} = classify(runs(Sorted), Cap1, Header, [], []),
    SingleAsdus = [mk(Header, false, C) || C <- chunks(lists:reverse(Singles), Cap0)],
    SeqAsdus ++ SingleAsdus.

%% Walk the consecutive-IOA runs: each run is chunked to `Cap1'; a chunk of two
%% or more objects becomes an `SQ=1' ASDU, a lone object joins the singles pool.
classify([], _Cap1, _Header, AsduAcc, Singles) ->
    {lists:reverse(AsduAcc), Singles};
classify([Run | Rest], Cap1, Header, AsduAcc, Singles) ->
    {AsduAcc1, Singles1} =
        lists:foldl(
          fun(Chunk, {As, Ss}) ->
                  case Chunk of
                      [Single] -> {As, [Single | Ss]};
                      _ -> {[mk(Header, true, Chunk) | As], Ss}
                  end
          end, {AsduAcc, Singles}, chunks(Run, Cap1)),
    classify(Rest, Cap1, Header, AsduAcc1, Singles1).

mk({Type, Coa, Cot}, SQ, Objs) ->
    #asdu{type = Type, cot = Cot, coa = Coa, sequence = SQ, objects = Objs}.

%%%===================================================================
%%% Object list shaping
%%%===================================================================

dedup_sort(Objs) ->
    Map = lists:foldl(fun(#object{ioa = Ioa} = O, Acc) -> Acc#{Ioa => O} end,
                      #{}, Objs),
    [O || {_Ioa, O} <- lists:sort(maps:to_list(Map))].

%% Maximal runs of consecutive IOAs, order preserved.
runs([]) -> [];
runs([O | Rest]) -> runs(Rest, [O], []).

runs([], Cur, Acc) ->
    lists:reverse([lists:reverse(Cur) | Acc]);
runs([#object{ioa = Ioa} = O | Rest], [#object{ioa = Prev} | _] = Cur, Acc) ->
    case Ioa =:= Prev + 1 of
        true -> runs(Rest, [O | Cur], Acc);
        false -> runs(Rest, [O], [lists:reverse(Cur) | Acc])
    end.

%% Split a list into sublists of at most `Cap' elements (`Cap >= 1').
chunks([], _Cap) -> [];
chunks(L, Cap) when length(L) =< Cap -> [L];
chunks(L, Cap) ->
    {Head, Tail} = lists:split(Cap, L),
    [Head | chunks(Tail, Cap)].

%%%===================================================================
%%% Capacities
%%%===================================================================

cap_sq1(Type, Opts) ->
    Avail = ?MAX_OCTETS - fixed(Opts) - ioa_size(Opts),
    clamp(Avail div iec60870_type:payload_size(Type)).

cap_sq0(Type, Opts) ->
    Avail = ?MAX_OCTETS - fixed(Opts),
    clamp(Avail div (ioa_size(Opts) + iec60870_type:payload_size(Type))).

%% type id + VSQ + COT + COA octets.
fixed(Opts) ->
    2 + maps:get(cot_size, Opts, 2) + maps:get(coa_size, Opts, 2).

ioa_size(Opts) ->
    maps:get(ioa_size, Opts, 3).

clamp(N) when N < 1 -> 1;
clamp(N) when N > 127 -> 127;
clamp(N) -> N.
