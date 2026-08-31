%%% @doc IEC 60870-5-104 APCI — the application protocol control information that
%%% frames every APDU on the wire, plus the 15-bit send/receive sequence-number
%%% arithmetic (docs/DESIGN.md section 4).
%%%
%%% Transport-free and side-effect-free: `iec60870_104_conn' owns the socket and
%%% the state machine; this module only turns frames into octets and back and
%%% answers questions about sequence numbers.
%%%
%%% ```
%%%   APDU = APCI (6 octets) + ASDU (0..249 octets)        ; APDU max 253
%%%
%%%   APCI:  68  LEN  CF1 CF2 CF3 CF4
%%%          │   │    └──────────────  control field, format-dependent
%%%          │   └─ octet count of CF1..CF4 + ASDU  (4..253)
%%%          └─ start
%%%
%%%   I-format  CF1 bit0 = 0    N(S) in CF1(b1..7)+CF2, N(R) in CF3(b1..7)+CF4
%%%   S-format  CF1 = 16#01     N(R) in CF3(b1..7)+CF4                 (ack only)
%%%   U-format  CF1 bits1..0 = 11, one function bit set               (no seq)
%%% '''
%%%
%%% Frames are represented as tagged tuples:
%%%
%%% <ul>
%%%   <li>`{i, N(S), N(R), ASDU :: binary()}'</li>
%%%   <li>`{s, N(R)}'</li>
%%%   <li>`{u, startdt_act | startdt_con | stopdt_act | stopdt_con
%%%          | testfr_act | testfr_con}'</li>
%%% </ul>
-module(iec60870_104_apci).

-export([encode/1, decode/1]).
-export([seq_succ/1, seq_add/2, seq_sub/2, seq_in_window/3]).

-export_type([seq/0, u_function/0, frame/0, decode_result/0]).

-define(START, 16#68).

%% Sequence numbers are 15-bit, counted modulo 32768 (docs/DESIGN.md section 4).
-define(SEQ_MOD, 32768).

-type seq() :: 0..32767.

-type u_function() :: startdt_act | startdt_con
                    | stopdt_act  | stopdt_con
                    | testfr_act  | testfr_con.

-type frame() :: {i, seq(), seq(), binary()}
               | {s, seq()}
               | {u, u_function()}.

-type decode_error() :: {bad_start, byte()}
                      | {bad_length, non_neg_integer()}
                      | {bad_control, byte()}.

-type decode_result() :: {ok, frame(), binary()}
                       | {incomplete, pos_integer()}
                       | {error, decode_error()}.

%%%===================================================================
%%% Encode
%%%===================================================================

%% @doc Serialise one frame into its complete APDU octets. Crashes on a
%% malformed frame (a programming error); `decode/1' is the tolerant side.
-spec encode(frame()) -> binary().
encode({i, NS, NR, Asdu}) when is_binary(Asdu) ->
    Len = 4 + byte_size(Asdu),
    Len =< 253 orelse error({asdu_too_large, byte_size(Asdu)}),
    <<?START, Len:8, (seq_octets(NS))/binary, (seq_octets(NR))/binary, Asdu/binary>>;
encode({s, NR}) ->
    <<?START, 4:8, 16#01, 0, (seq_octets(NR))/binary>>;
encode({u, Function}) ->
    <<?START, 4:8, (u_code(Function)):8, 0, 0, 0>>.

%% N(S) / N(R): low octet carries bits 0..6 shifted up by one (bit 0 is the
%% format indicator, always 0 here); high octet carries bits 7..14.
seq_octets(N) when is_integer(N), N >= 0, N < ?SEQ_MOD ->
    <<((N band 16#7F) bsl 1):8, (N bsr 7):8>>.

u_code(startdt_act) -> 16#07;
u_code(startdt_con) -> 16#0B;
u_code(stopdt_act)  -> 16#13;
u_code(stopdt_con)  -> 16#23;
u_code(testfr_act)  -> 16#43;
u_code(testfr_con)  -> 16#83.

%%%===================================================================
%%% Decode
%%%===================================================================

%% @doc Peel one APDU off the front of a stream buffer.
%%
%% `{incomplete, N}' means at least `N' more octets are needed before a frame
%% can be read; the caller keeps buffering. `{ok, Frame, Rest}' returns the
%% frame and whatever octets followed it (the next frame, or a partial one).
-spec decode(binary()) -> decode_result().
decode(<<>>) ->
    {incomplete, 2};
decode(<<?START>>) ->
    {incomplete, 1};
decode(<<?START, Len:8, Rest/binary>>) when Len >= 4, Len =< 253 ->
    case Rest of
        <<Body:Len/binary, Tail/binary>> -> decode_body(Body, Tail);
        _ -> {incomplete, Len - byte_size(Rest)}
    end;
decode(<<?START, Len:8, _/binary>>) ->
    {error, {bad_length, Len}};
decode(<<B:8, _/binary>>) ->
    {error, {bad_start, B}}.

decode_body(<<CF1:8, CF2:8, CF3:8, CF4:8, Asdu/binary>>, Tail) ->
    if
        CF1 band 2#01 =:= 0 ->
            {ok, {i, seq_of(CF1, CF2), seq_of(CF3, CF4), Asdu}, Tail};
        CF1 band 2#11 =:= 2#01 ->
            {ok, {s, seq_of(CF3, CF4)}, Tail};
        true ->
            case u_function(CF1) of
                undefined -> {error, {bad_control, CF1}};
                Function -> {ok, {u, Function}, Tail}
            end
    end.

seq_of(Lo, Hi) -> (Lo bsr 1) bor (Hi bsl 7).

u_function(16#07) -> startdt_act;
u_function(16#0B) -> startdt_con;
u_function(16#13) -> stopdt_act;
u_function(16#23) -> stopdt_con;
u_function(16#43) -> testfr_act;
u_function(16#83) -> testfr_con;
u_function(_)     -> undefined.

%%%===================================================================
%%% 15-bit sequence-number arithmetic (modulo 32768)
%%%===================================================================

%% @doc The next sequence number after `N'.
-spec seq_succ(seq()) -> seq().
seq_succ(N) -> (N + 1) rem ?SEQ_MOD.

%% @doc `N' advanced by `D' steps.
-spec seq_add(seq(), non_neg_integer()) -> seq().
seq_add(N, D) -> (N + D) rem ?SEQ_MOD.

%% @doc The number of steps from `B' forward to `A' (0..32767).
-spec seq_sub(seq(), seq()) -> seq().
seq_sub(A, B) -> (A - B + ?SEQ_MOD) rem ?SEQ_MOD.

%% @doc Whether `N' lies in the closed window `[Lo, Hi]' walking forward from
%% `Lo'. Used to validate a received N(R) against `[ack, V(S)]': every value
%% from "acknowledges nothing new" (`Lo') through "acknowledges everything
%% outstanding" (`Hi') is legal, anything else means the peer lost sync.
-spec seq_in_window(seq(), seq(), seq()) -> boolean().
seq_in_window(N, Lo, Hi) ->
    seq_sub(N, Lo) =< seq_sub(Hi, Lo).
