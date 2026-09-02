%%% @doc Default data model: one `public' ETS table, keyed `{COA, IOA}' ->
%%% {@link iec60870_point:point()} (docs/DESIGN.md section 6).
%%%
%%% Not a process. `init/1' creates the table owned by its caller
%%% (`iec60870_server_ctl'); reads and the interrogation fold hit ETS directly,
%%% writes are serialised because that one caller is a `gen_server'. If the
%%% owner restarts the table (and its point values) is rebuilt from `Args' —
%%% acceptable for phase 3; a dedicated owner process can be split out later.
%%%
%%% `Args' is a map. `points' preloads the table:
%%% <ul>
%%%   <li>`[{{Coa, Ioa}, Spec}, ...]' — inline, `Spec' as in
%%%       {@link iec60870_point:spec_to_point/1};</li>
%%%   <li>`{file, Path}' or `Path' (a string) — `file:consult/1' a term file of
%%%       the same entries (one per line, or a single list).</li>
%%% </ul>
-module(iec60870_dm_ets).
-behaviour(iec60870_data_model).

-export([init/1, terminate/1, read/3, write/4, fold/5, coas/1,
         fold_counters/5, freeze_counters/4]).

-type state() :: #{tab := ets:table()}.
-export_type([state/0]).

%%%===================================================================
%%% iec60870_data_model
%%%===================================================================

-spec init(map()) -> {ok, state()}.
init(Args) when is_map(Args) ->
    Tab = ets:new(?MODULE, [public, set,
                            {read_concurrency, true}, {write_concurrency, true}]),
    ok = preload(Tab, maps:get(points, Args, [])),
    {ok, #{tab => Tab}}.

-spec terminate(state()) -> ok.
terminate(#{tab := Tab}) ->
    _ = (catch ets:delete(Tab)),
    ok.

-spec read(state(), iec60870_data_model:coa(), non_neg_integer()) ->
    {ok, iec60870_point:point()} | not_found.
read(#{tab := Tab}, Coa, Ioa) ->
    case ets:lookup(Tab, {Coa, Ioa}) of
        [{_, Point}] -> {ok, Point};
        [] -> not_found
    end.

-spec write(state(), iec60870_data_model:coa(), non_neg_integer(),
            iec60870_point:point()) -> {ok, state(), boolean()}.
write(#{tab := Tab} = State, Coa, Ioa, Point) ->
    Old = case ets:lookup(Tab, {Coa, Ioa}) of
              [{_, P}] -> P;
              [] -> not_found
          end,
    Changed = iec60870_data_model:is_significant_change(Old, Point),
    true = ets:insert(Tab, {{Coa, Ioa}, Point}),
    {ok, State, Changed}.

-spec fold(state(), iec60870_data_model:coa(), iec60870_data_model:fold_group(),
           fun((non_neg_integer(), iec60870_point:point(), Acc) -> Acc), Acc) -> Acc.
fold(#{tab := Tab}, Coa, Group, Fun, Acc0) ->
    ets:foldl(
      fun({{C, Ioa}, Point}, Acc) when C =:= Coa ->
              case in_group(Group, Point) of
                  true -> Fun(Ioa, Point, Acc);
                  false -> Acc
              end;
         (_Entry, Acc) ->
              Acc
      end, Acc0, Tab).

-spec coas(state()) -> [iec60870_data_model:coa()].
coas(#{tab := Tab}) ->
    lists:usort(ets:select(Tab, [{{{'$1', '_'}, '_'}, [], ['$1']}])).

-spec fold_counters(state(), iec60870_data_model:coa(), iec60870_data_model:counter_group(),
                    fun((non_neg_integer(), iec60870_point:point(), Acc) -> Acc), Acc) -> Acc.
fold_counters(#{tab := Tab}, Coa, Group, Fun, Acc0) ->
    ets:foldl(
      fun({{C, Ioa}, Point}, Acc) when C =:= Coa ->
              case in_counter_group(Group, Point) of
                  true -> Fun(Ioa, Point, Acc);
                  false -> Acc
              end;
         (_Entry, Acc) ->
              Acc
      end, Acc0, Tab).

-spec freeze_counters(state(), iec60870_data_model:coa(), iec60870_data_model:counter_group(),
                      iec60870_data_model:freeze()) -> {ok, state()}.
freeze_counters(#{tab := Tab} = State, Coa, Group, Freeze)
  when Freeze =:= freeze_reset; Freeze =:= reset ->
    Keys = ets:foldl(
             fun({{C, _Ioa} = Key, Point}, Acc) when C =:= Coa ->
                     case in_counter_group(Group, Point) of
                         true -> [Key | Acc];
                         false -> Acc
                     end;
                (_Entry, Acc) ->
                     Acc
             end, [], Tab),
    lists:foreach(
      fun(Key) ->
              [{_, Point}] = ets:lookup(Tab, Key),
              true = ets:insert(Tab, {Key, reset_counter(Point)})
      end, Keys),
    {ok, State};
freeze_counters(State, _Coa, _Group, _Freeze) ->
    %% `read' / `freeze_no_reset': the stored value is left as-is —
    %% `fold_counters/5' reads it back unchanged.
    {ok, State}.

%%%===================================================================
%%% Internal
%%%===================================================================

in_group(station, #{type := Type}) ->
    iec60870_point:interrogable(Type);
in_group(N, #{type := Type, group := Group}) ->
    Group =:= N andalso iec60870_point:interrogable(Type).

in_counter_group(station, #{type := Type}) ->
    iec60870_point:is_counter(Type);
in_counter_group(N, #{type := Type, group := Group}) ->
    Group =:= N andalso iec60870_point:is_counter(Type).

reset_counter(#{qualifier := Ql} = Point) ->
    Seq = maps:get(sequence, Ql, 0),
    Point#{value => 0, qualifier => Ql#{sequence => (Seq + 1) rem 32}}.

preload(_Tab, []) ->
    ok;
preload(Tab, {file, Path}) ->
    {ok, Terms} = file:consult(Path),
    Entries = case Terms of
                  [L] when is_list(L) -> L;
                  _ -> Terms
              end,
    preload(Tab, Entries);
preload(Tab, [{{_Coa, _Ioa}, _Spec} | _] = Entries) ->
    lists:foreach(
      fun({{Coa, Ioa}, Spec}) ->
              true = ets:insert(Tab, {{Coa, Ioa}, iec60870_point:spec_to_point(Spec)})
      end, Entries),
    ok;
preload(Tab, Path) when is_list(Path) ->
    preload(Tab, {file, Path}).
