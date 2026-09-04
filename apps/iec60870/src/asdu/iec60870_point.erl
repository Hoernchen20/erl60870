-module(iec60870_point).
-moduledoc """
The public **point map** / internal `#object{}` bridge.

The public API (`docs/DESIGN.md` section 8) describes a monitored information
point as a map:

```erlang
#{type  => m_me_nc_1,
  value => 3.14,
  quality => [],              %% [] | [invalid | not_topical | blocked |
                              %%       substituted | overflow]
  ts    => 1_725_000_000_000, %% ms since the Unix epoch; omit / undefined
                              %% for the no-timestamp variant
  group => 3}                 %% interrogation group 1..16, or undefined
```

For a counter (`m_it_na_1` / `m_it_tb_1`, excluded from general interrogation,
see `is_counter/1`) `group` instead means the counter interrogation group
1..4 (`docs/DESIGN.md` section 7) — the two families never overlap on one
point since a point has exactly one type.

This module normalises such a map (`spec_to_point/1`) and turns a stored
point into the `#object{}` the codec consumes (`to_object/3`). It is
transport-free and lives in `src/asdu/` with the rest of the application
layer.
""".

-include_lib("iec60870/include/iec60870_asdu.hrl").

-export([spec_to_point/1, to_object/3, is_timestamped/1, interrogable/1,
         is_counter/1]).

-export_type([point/0, group/0]).

-type group() :: 1..16 | undefined.

-doc """
The stored form of one monitored point. `quality` is kept sorted so equal
points compare equal; `qualifier` carries the type-specific extras
(`#{transient => boolean()}` for step position, the BCR flags for counters).
""".
-type point() :: #{type := iec60870_asdu:type_name(),
                   value := term(),
                   quality := [iec60870_asdu:quality_flag()],
                   ts := non_neg_integer() | undefined,
                   group := group(),
                   qualifier => term()}.

%%%===================================================================
%%% Normalisation
%%%===================================================================

-doc "Fill a user-supplied spec map out to a full `t:point/0`.".
-spec spec_to_point(map()) -> point().
spec_to_point(#{type := Type} = Spec) ->
    Base = #{type => Type,
             value => maps:get(value, Spec, undefined),
             quality => lists:usort(maps:get(quality, Spec, [])),
             ts => maps:get(ts, Spec, undefined),
             group => maps:get(group, Spec, undefined)},
    case qualifier(Type, Spec) of
        undefined -> Base;
        Qualifier -> Base#{qualifier => Qualifier}
    end.

qualifier(Type, Spec) ->
    case maps:get(qualifier, Spec, undefined) of
        undefined -> default_qualifier(Type, Spec);
        Qualifier -> Qualifier
    end.

default_qualifier(m_st_na_1, Spec) ->
    #{transient => maps:get(transient, Spec, false) =:= true};
default_qualifier(Type, Spec)
  when Type =:= m_it_na_1; Type =:= m_it_tb_1 ->
    #{sequence => maps:get(sequence, Spec, 0),
      carry => maps:get(carry, Spec, false) =:= true,
      adjusted => maps:get(adjusted, Spec, false) =:= true};
default_qualifier(_, _) ->
    undefined.

%%%===================================================================
%%% Point -> #object{}
%%%===================================================================

-doc """
Build the information object for `Ioa` from a stored point. For a timestamped
type with no `ts` the current system time is used.
""".
-spec to_object(iec60870_asdu:type_name(), non_neg_integer(), point()) -> #object{}.
to_object(Type, Ioa, Point) ->
    Obj0 = #object{ioa = Ioa,
                   value = maps:get(value, Point),
                   quality = maps:get(quality, Point, [])},
    Obj1 = case maps:get(qualifier, Point, undefined) of
               undefined -> Obj0;
               Qualifier -> Obj0#object{qualifier = Qualifier}
           end,
    case is_timestamped(Type) of
        false -> Obj1;
        true -> Obj1#object{timestamp = timestamp(maps:get(ts, Point, undefined))}
    end.

timestamp(undefined) ->
    iec60870_cp56:from_timestamp(erlang:system_time(millisecond));
timestamp(Millis) when is_integer(Millis) ->
    iec60870_cp56:from_timestamp(Millis).

%%%===================================================================
%%% Type predicates
%%%===================================================================

-doc "Whether a type id carries a CP56Time2a on the wire.".
-spec is_timestamped(iec60870_asdu:type_name()) -> boolean().
is_timestamped(m_sp_tb_1) -> true;
is_timestamped(m_dp_tb_1) -> true;
is_timestamped(m_me_td_1) -> true;
is_timestamped(m_me_te_1) -> true;
is_timestamped(m_me_tf_1) -> true;
is_timestamped(m_it_tb_1) -> true;
is_timestamped(_) -> false.

-doc """
Whether a point of this type is returned by (general / group) interrogation.
Integrated totals are excluded — they answer to counter interrogation
(`docs/DESIGN.md` section 7, IEC 60870-5-5).
""".
-spec interrogable(iec60870_asdu:type_name()) -> boolean().
interrogable(m_sp_na_1) -> true;
interrogable(m_dp_na_1) -> true;
interrogable(m_st_na_1) -> true;
interrogable(m_me_na_1) -> true;
interrogable(m_me_nb_1) -> true;
interrogable(m_me_nc_1) -> true;
interrogable(m_sp_tb_1) -> true;
interrogable(m_dp_tb_1) -> true;
interrogable(m_me_td_1) -> true;
interrogable(m_me_te_1) -> true;
interrogable(m_me_tf_1) -> true;
interrogable(_) -> false.

-doc """
Whether a point of this type answers to counter interrogation
(`docs/DESIGN.md` section 7, IEC 60870-5-5) rather than general interrogation.
""".
-spec is_counter(iec60870_asdu:type_name()) -> boolean().
is_counter(m_it_na_1) -> true;
is_counter(m_it_tb_1) -> true;
is_counter(_) -> false.
