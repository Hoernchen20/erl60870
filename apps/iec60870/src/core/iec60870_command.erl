-module(iec60870_command).
-moduledoc """
Command decode/match/mirror helpers (`docs/DESIGN.md` section 7).

Pure and transport-free, like `m:iec60870_point` and `m:iec60870_batch`: it
turns a decoded single-object `#asdu{}` into the public command map the
`select/2` / `execute/2` callbacks see, decides whether an operate matches an
outstanding select, and builds the `act_con` / `act_term` mirror ASDU. The
protocol mechanics (timers, callback dispatch, the connection owner) live in
`m:iec60870_server_ctl`.
""".

-include_lib("iec60870/include/iec60870_asdu.hrl").

-export([is_command/1, to_map/1, matches/2, mirror/3]).

-export_type([command/0]).

-doc """
The map handed to the `select/2` / `execute/2` callbacks (`docs/DESIGN.md`
section 7). `value` and `qualifier` follow the same per-type representation
as `#object{}` (see the `m:iec60870_type` moduledoc): boolean for single
command, `0..3` for double / regulating step, a raw i16 or float for
setpoints; `qualifier` is `#{select => boolean(), qu => 0..31}`
(single/double/step) or `#{select => boolean(), ql => 0..127}` (setpoints) —
`select` mirrors the S/E bit also broken out as the top-level `select` field.
""".
-type command() :: #{type := iec60870_asdu:type_name(),
                     coa := 0..65535,
                     ioa := non_neg_integer(),
                     value := boolean() | 0..3 | number(),
                     select := boolean(),
                     qualifier := map(),
                     orig_addr := 0..255,
                     test := boolean()}.

%%%===================================================================
%%% API
%%%===================================================================

-doc """
Whether a type id is one of the v1 command types (`docs/DESIGN.md`
section 10) — single, double, regulating step, and the three setpoints.
""".
-spec is_command(iec60870_asdu:type_name() | term()) -> boolean().
is_command(c_sc_na_1) -> true;
is_command(c_dc_na_1) -> true;
is_command(c_rc_na_1) -> true;
is_command(c_se_na_1) -> true;
is_command(c_se_nb_1) -> true;
is_command(c_se_nc_1) -> true;
is_command(_) -> false.

-doc "Decode a single-object command ASDU into the public `t:command/0`.".
-spec to_map(#asdu{}) -> command().
to_map(#asdu{type = Type, coa = Coa, orig_addr = OrigAddr, test = Test,
             objects = [#object{ioa = Ioa, value = Value, qualifier = Ql}]}) ->
    #{type => Type, coa => Coa, ioa => Ioa, value => Value,
      select => is_select(Ql), qualifier => qualifier(Ql),
      orig_addr => OrigAddr, test => Test}.

-doc """
Whether `Operate` (S/E = 0) is the operate half of the select-before-operate
sequence started by `Selected` (S/E = 1): same type, common address,
information object address and value, and the same qualifier once the
`select` bit each carries is disregarded.
""".
-spec matches(command(), command()) -> boolean().
matches(Selected, Operate) ->
    maps:get(type, Selected) =:= maps:get(type, Operate) andalso
    maps:get(coa, Selected) =:= maps:get(coa, Operate) andalso
    maps:get(ioa, Selected) =:= maps:get(ioa, Operate) andalso
    maps:get(value, Selected) =:= maps:get(value, Operate) andalso
    qualifier_sans_select(maps:get(qualifier, Selected)) =:=
        qualifier_sans_select(maps:get(qualifier, Operate)).

-doc """
Build the `act_con` / `act_term` mirror of a received command ASDU: same
common address, originator address, test bit and (single) object, cause of
transmission and P/N bit replaced.
""".
-spec mirror(#asdu{}, iec60870_cot:cot(), boolean()) -> #asdu{}.
mirror(#asdu{} = Asdu, Cot, Negative) when is_boolean(Negative) ->
    Asdu#asdu{cot = Cot, negative = Negative}.

%%%===================================================================
%%% Internal
%%%===================================================================

is_select(#{select := S}) -> S =:= true;
is_select(_) -> false.

qualifier(Ql) when is_map(Ql) -> Ql;
qualifier(_) -> #{}.

qualifier_sans_select(Ql) -> maps:remove(select, qualifier(Ql)).
