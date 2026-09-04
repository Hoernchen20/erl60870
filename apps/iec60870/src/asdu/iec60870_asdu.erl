-module(iec60870_asdu).
-moduledoc """
APDU/ASDU wire codec and information-object builders.

Transport-free: shared verbatim by the 104 and 101 stacks — 104 is the
companion standard of 101 and only the lower layers differ (`docs/DESIGN.md`
sections 2 and 10).

An ASDU is the data-unit identifier (type id, variable structure qualifier,
cause of transmission, common address) followed by its information objects.
The field widths of the identifier and of the information object address are
configurable per link (`docs/DESIGN.md` section 9, `params`); pass them in
`t:opts/0`, defaulting to the IEC 60870-5-104 norm (COT 2, COA 2, IOA 3).

The `#asdu{}` / `#object{}` records (`include/iec60870_asdu.hrl`) are the
internal form; per-type payload dispatch lives in `m:iec60870_type`.
""".

-include_lib("iec60870/include/iec60870_asdu.hrl").

-export([encode/1, encode/2, decode/1, decode/2]).
-export([type_id/1, type_name/1]).

%% object builders (docs/DESIGN.md section 8)
-export([single_point/2, single_point/3,
         double_point/2, double_point/3,
         step_position/3, step_position/4,
         measured_value_normalized/2, measured_value_normalized/3,
         measured_value_scaled/2, measured_value_scaled/3,
         measured_value_short/2, measured_value_short/3,
         integrated_total/2, integrated_total/3,
         end_of_initialization/1, end_of_initialization/2,
         single_command/2, single_command/3,
         double_command/2, double_command/3,
         regulating_step_command/2, regulating_step_command/3,
         setpoint_normalized/2, setpoint_normalized/3,
         setpoint_scaled/2, setpoint_scaled/3,
         setpoint_short/2, setpoint_short/3,
         interrogation/1, counter_interrogation/1,
         read_command/1, clock_sync/1, test_command/2,
         parameter_normalized/3, parameter_normalized/4,
         parameter_scaled/3, parameter_scaled/4,
         parameter_short/3, parameter_short/4,
         parameter_activation/2]).

-export_type([type_name/0, cot_size/0, coa_size/0, ioa_size/0, quality_flag/0,
              opts/0, decode_error/0]).

-doc """
Type identification, as an atom. The raw integer is used for type ids the
codec does not model. Kept in sync with `docs/DESIGN.md` section 10.
""".
-type type_name() ::
        m_sp_na_1 | m_sp_tb_1
      | m_dp_na_1 | m_dp_tb_1
      | m_st_na_1
      | m_me_na_1 | m_me_nb_1 | m_me_nc_1
      | m_me_td_1 | m_me_te_1 | m_me_tf_1
      | m_it_na_1 | m_it_tb_1
      | m_ei_na_1
      | c_sc_na_1 | c_dc_na_1 | c_rc_na_1
      | c_se_na_1 | c_se_nb_1 | c_se_nc_1
      | c_ic_na_1 | c_ci_na_1 | c_rd_na_1 | c_cs_na_1 | c_ts_ta_1
      | p_me_na_1 | p_me_nb_1 | p_me_nc_1 | p_ac_na_1.

-doc """
Configurable field widths of the data-unit identifier / IOA (`docs/DESIGN.md`
section 9, `params`).
""".
-type cot_size() :: 1 | 2.
-type coa_size() :: 1 | 2.
-type ioa_size() :: 1 | 2 | 3.

-type quality_flag() ::
        overflow | blocked | substituted | not_topical | invalid.

-type opts() :: #{cot_size => cot_size(),
                  coa_size => coa_size(),
                  ioa_size => ioa_size()}.

-doc "`truncated` also covers a payload that is malformed for its type id.".
-type decode_error() :: {unsupported_type, 0..255} | truncated.

-define(DEFAULTS, #{cot_size => 2, coa_size => 2, ioa_size => 3}).

%%%===================================================================
%%% Type identification
%%%===================================================================

-doc "Type-identification atom to its integer code (integers pass through).".
-spec type_id(type_name() | 0..255) -> 0..255.
type_id(Name) -> iec60870_type:name_to_id(Name).

-doc """
Integer type-identification code to its atom (unmodelled codes stay
integers).
""".
-spec type_name(0..255) -> type_name() | 0..255.
type_name(Id) -> iec60870_type:id_to_name(Id).

%%%===================================================================
%%% Encode
%%%===================================================================

-spec encode(#asdu{}) -> binary().
encode(Asdu) -> encode(Asdu, #{}).

-doc """
Serialise one `#asdu{}`. Crashes on a malformed record (a programming
error); `decode/2` is the side that tolerates bad input.
""".
-spec encode(#asdu{}, opts()) -> binary().
encode(#asdu{type = Type, cot = Cot, negative = Neg, test = Test,
             orig_addr = Orig, coa = Coa, sequence = SQ, objects = Objs},
       Opts) ->
    #{cot_size := CotSz, coa_size := CoaSz, ioa_size := IoaSz} = with_defaults(Opts),
    Count = length(Objs),
    Count =< 127 orelse error({too_many_objects, Count}),
    Bin = [<<(type_id(Type)):8, (bit(SQ)):1, Count:7>>,
           cot_octets(Cot, Neg, Test, Orig, CotSz),
           uint_le(Coa, CoaSz),
           objects(Type, SQ, IoaSz, Objs)],
    iolist_to_binary(Bin).

cot_octets(Cot, Neg, Test, _Orig, 1) ->
    <<(bit(Test)):1, (bit(Neg)):1, (iec60870_cot:to_int(Cot)):6>>;
cot_octets(Cot, Neg, Test, Orig, 2) ->
    <<(bit(Test)):1, (bit(Neg)):1, (iec60870_cot:to_int(Cot)):6, Orig:8>>.

objects(_Type, _SQ, _IoaSz, []) ->
    [];
objects(Type, true, IoaSz, [#object{ioa = Base} | _] = Objs) ->
    _ = lists:foldl(
          fun(#object{ioa = Ioa}, Expected) ->
                  Ioa =:= Expected orelse
                      error({non_contiguous_sequence, Expected, Ioa}),
                  Expected + 1
          end, Base, Objs),
    [uint_le(Base, IoaSz) | [iec60870_type:encode_payload(Type, O) || O <- Objs]];
objects(Type, false, IoaSz, Objs) ->
    [[uint_le(O#object.ioa, IoaSz), iec60870_type:encode_payload(Type, O)]
     || O <- Objs].

%%%===================================================================
%%% Decode
%%%===================================================================

-spec decode(binary()) -> {ok, #asdu{}, binary()} | {error, decode_error()}.
decode(Bin) -> decode(Bin, #{}).

-doc """
Parse one ASDU off the front of `Bin`, returning the record and any bytes
left over (for 104 the APCI layer hands an exact slice, so the remainder is
normally empty).
""".
-spec decode(binary(), opts()) -> {ok, #asdu{}, binary()} | {error, decode_error()}.
decode(Bin, Opts) ->
    #{cot_size := CotSz, coa_size := CoaSz, ioa_size := IoaSz} = with_defaults(Opts),
    try
        <<TypeId:8, SQ:1, Count:7, R0/binary>> = Bin,
        {Cot, Neg, Test, Orig, R1} = decode_cot(R0, CotSz),
        <<CoaBin:CoaSz/binary, R2/binary>> = R1,
        Type = type_name(TypeId),
        is_atom(Type) orelse throw({unsupported_type, TypeId}),
        {Objs, R3} = decode_objects(Type, SQ =:= 1, Count, IoaSz, R2),
        {ok, #asdu{type = Type, cot = Cot, negative = Neg, test = Test,
                   orig_addr = Orig, coa = uint_from_le(CoaBin),
                   sequence = SQ =:= 1, objects = Objs},
         R3}
    catch
        error:{badmatch, _} -> {error, truncated};
        error:function_clause -> {error, truncated};
        throw:Reason -> {error, Reason}
    end.

decode_cot(<<Test:1, Neg:1, C:6, R/binary>>, 1) ->
    {iec60870_cot:from_int(C), Neg =:= 1, Test =:= 1, 0, R};
decode_cot(<<Test:1, Neg:1, C:6, Orig:8, R/binary>>, 2) ->
    {iec60870_cot:from_int(C), Neg =:= 1, Test =:= 1, Orig, R}.

decode_objects(_Type, _SQ, 0, _IoaSz, Bin) ->
    {[], Bin};
decode_objects(Type, false, Count, IoaSz, Bin) ->
    decode_discrete(Type, Count, IoaSz, Bin, []);
decode_objects(Type, true, Count, IoaSz, Bin) ->
    {Base, Rest} = uint_take(Bin, IoaSz),
    decode_sequence(Type, Base, Count, Rest, []).

decode_discrete(_Type, 0, _IoaSz, Bin, Acc) ->
    {lists:reverse(Acc), Bin};
decode_discrete(Type, N, IoaSz, Bin, Acc) ->
    {Ioa, Rest0} = uint_take(Bin, IoaSz),
    {Obj, Rest1} = iec60870_type:decode_payload(Type, Ioa, Rest0),
    decode_discrete(Type, N - 1, IoaSz, Rest1, [Obj | Acc]).

decode_sequence(_Type, _Ioa, 0, Bin, Acc) ->
    {lists:reverse(Acc), Bin};
decode_sequence(Type, Ioa, N, Bin, Acc) ->
    {Obj, Rest} = iec60870_type:decode_payload(Type, Ioa, Bin),
    decode_sequence(Type, Ioa + 1, N - 1, Rest, [Obj | Acc]).

%%%===================================================================
%%% Object builders (return the internal `#object{}')
%%%===================================================================

single_point(Ioa, Value) -> single_point(Ioa, Value, #{}).
single_point(Ioa, Value, Opts) ->
    monitored(Ioa, to_bool(Value), Opts).

double_point(Ioa, Value) -> double_point(Ioa, Value, #{}).
double_point(Ioa, Value, Opts) when is_integer(Value), Value >= 0, Value =< 3 ->
    monitored(Ioa, Value, Opts).

step_position(Ioa, Position, Transient) ->
    step_position(Ioa, Position, Transient, #{}).
step_position(Ioa, Position, Transient, Opts) ->
    (monitored(Ioa, Position, Opts))#object{qualifier = #{transient => Transient}}.

measured_value_normalized(Ioa, Raw) -> measured_value_normalized(Ioa, Raw, #{}).
measured_value_normalized(Ioa, Raw, Opts) -> monitored(Ioa, Raw, Opts).

measured_value_scaled(Ioa, Raw) -> measured_value_scaled(Ioa, Raw, #{}).
measured_value_scaled(Ioa, Raw, Opts) -> monitored(Ioa, Raw, Opts).

measured_value_short(Ioa, Value) -> measured_value_short(Ioa, Value, #{}).
measured_value_short(Ioa, Value, Opts) -> monitored(Ioa, Value, Opts).

integrated_total(Ioa, Counter) -> integrated_total(Ioa, Counter, #{}).
integrated_total(Ioa, Counter, Opts) ->
    Q = #{sequence => maps:get(sequence, Opts, 0),
          carry => maps:get(carry, Opts, false),
          adjusted => maps:get(adjusted, Opts, false)},
    (monitored(Ioa, Counter, Opts))#object{qualifier = Q}.

end_of_initialization(Cause) -> end_of_initialization(Cause, #{}).
end_of_initialization(Cause, Opts) when is_integer(Cause) ->
    #object{ioa = 0, value = Cause,
            qualifier = #{local_change => maps:get(local_change, Opts, false)}}.

single_command(Ioa, On) -> single_command(Ioa, On, #{}).
single_command(Ioa, On, Opts) ->
    #object{ioa = Ioa, value = to_bool(On), qualifier = command_qualifier(Opts)}.

double_command(Ioa, Code) -> double_command(Ioa, Code, #{}).
double_command(Ioa, Code, Opts) when is_integer(Code), Code >= 0, Code =< 3 ->
    #object{ioa = Ioa, value = Code, qualifier = command_qualifier(Opts)}.

regulating_step_command(Ioa, Code) -> regulating_step_command(Ioa, Code, #{}).
regulating_step_command(Ioa, Code, Opts) when is_integer(Code), Code >= 0, Code =< 3 ->
    #object{ioa = Ioa, value = Code, qualifier = command_qualifier(Opts)}.

setpoint_normalized(Ioa, Raw) -> setpoint_normalized(Ioa, Raw, #{}).
setpoint_normalized(Ioa, Raw, Opts) -> setpoint(Ioa, Raw, Opts).

setpoint_scaled(Ioa, Raw) -> setpoint_scaled(Ioa, Raw, #{}).
setpoint_scaled(Ioa, Raw, Opts) -> setpoint(Ioa, Raw, Opts).

setpoint_short(Ioa, Value) -> setpoint_short(Ioa, Value, #{}).
setpoint_short(Ioa, Value, Opts) -> setpoint(Ioa, Value, Opts).

interrogation(Qoi) when is_integer(Qoi) ->
    #object{ioa = 0, value = Qoi}.

counter_interrogation(Qcc) ->
    #object{ioa = 0, value = Qcc}.

read_command(Ioa) ->
    #object{ioa = Ioa}.

clock_sync(#cp56{} = Time) ->
    #object{ioa = 0, timestamp = Time}.

test_command(Tsc, #cp56{} = Time) when is_integer(Tsc) ->
    #object{ioa = 0, value = Tsc, timestamp = Time}.

parameter_normalized(Ioa, Raw, Kind) -> parameter_normalized(Ioa, Raw, Kind, #{}).
parameter_normalized(Ioa, Raw, Kind, Opts) -> parameter(Ioa, Raw, Kind, Opts).

parameter_scaled(Ioa, Raw, Kind) -> parameter_scaled(Ioa, Raw, Kind, #{}).
parameter_scaled(Ioa, Raw, Kind, Opts) -> parameter(Ioa, Raw, Kind, Opts).

parameter_short(Ioa, Value, Kind) -> parameter_short(Ioa, Value, Kind, #{}).
parameter_short(Ioa, Value, Kind, Opts) -> parameter(Ioa, Value, Kind, Opts).

parameter_activation(Ioa, Qpa) ->
    #object{ioa = Ioa, value = Qpa}.

parameter(Ioa, Value, Kind, Opts) ->
    #object{ioa = Ioa, value = Value,
            qualifier = #{kind => Kind,
                          in_operation => maps:get(in_operation, Opts, true),
                          local_change => maps:get(local_change, Opts, false)}}.

monitored(Ioa, Value, Opts) ->
    #object{ioa = Ioa, value = Value,
            quality = maps:get(quality, Opts, []),
            timestamp = maps:get(timestamp, Opts, undefined)}.

setpoint(Ioa, Value, Opts) ->
    #object{ioa = Ioa, value = Value,
            qualifier = #{select => maps:get(select, Opts, false),
                          ql => maps:get(ql, Opts, 0)}}.

command_qualifier(Opts) ->
    #{select => maps:get(select, Opts, false),
      qu => maps:get(qu, Opts, 0)}.

to_bool(true)  -> true;
to_bool(false) -> false;
to_bool(1)     -> true;
to_bool(0)     -> false;
to_bool(on)    -> true;
to_bool(off)   -> false.

%%%===================================================================
%%% Integer <-> little-endian octets
%%%===================================================================

uint_le(Value, NBytes) ->
    Bits = 8 * NBytes,
    (Value >= 0 andalso Value < (1 bsl Bits)) orelse
        error({value_out_of_range, Value, NBytes}),
    <<Value:Bits/little-unsigned>>.

uint_from_le(Bin) ->
    Bits = bit_size(Bin),
    <<Value:Bits/little-unsigned>> = Bin,
    Value.

uint_take(Bin, NBytes) ->
    <<Chunk:NBytes/binary, Rest/binary>> = Bin,
    {uint_from_le(Chunk), Rest}.

with_defaults(Opts) -> maps:merge(?DEFAULTS, Opts).

bit(true) -> 1;
bit(false) -> 0.
