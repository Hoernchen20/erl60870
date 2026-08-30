%%% @doc Cause of transmission (COT) — the 6-bit code in the data-unit
%%% identifier (IEC 60870-5-101 section 7.2.3, table).
%%%
%%% Atoms for the fixed causes; `{interrogated_group, 1..16}' and
%%% `{interrogated_counter_group, 1..4}' for the two families that the standard
%%% spreads over a range of codes. Any code the table does not name round-trips
%%% as the raw integer.
-module(iec60870_cot).

-export([to_int/1, from_int/1]).

-type cot() ::
        periodic | background | spontaneous | initialized | request
      | act | act_con | deact | deact_con | act_term
      | return_remote | return_local | file_transfer
      | interrogated_station | {interrogated_group, 1..16}
      | interrogated_counter | {interrogated_counter_group, 1..4}
      | unknown_type_id | unknown_cot | unknown_coa | unknown_ioa
      | 0..63.
-export_type([cot/0]).

%% @doc COT term to its 6-bit code.
-spec to_int(cot()) -> 0..63.
to_int(periodic)                        -> 1;
to_int(background)                      -> 2;
to_int(spontaneous)                     -> 3;
to_int(initialized)                     -> 4;
to_int(request)                         -> 5;
to_int(act)                             -> 6;
to_int(act_con)                         -> 7;
to_int(deact)                           -> 8;
to_int(deact_con)                       -> 9;
to_int(act_term)                        -> 10;
to_int(return_remote)                   -> 11;
to_int(return_local)                    -> 12;
to_int(file_transfer)                   -> 13;
to_int(interrogated_station)            -> 20;
to_int({interrogated_group, N}) when is_integer(N), N >= 1, N =< 16 ->
    20 + N;
to_int(interrogated_counter)            -> 37;
to_int({interrogated_counter_group, N}) when is_integer(N), N >= 1, N =< 4 ->
    37 + N;
to_int(unknown_type_id)                 -> 44;
to_int(unknown_cot)                     -> 45;
to_int(unknown_coa)                     -> 46;
to_int(unknown_ioa)                     -> 47;
to_int(N) when is_integer(N), N >= 0, N =< 63 ->
    N.

%% @doc 6-bit code to its COT term; unnamed codes stay integers.
-spec from_int(0..63) -> cot().
from_int(1)  -> periodic;
from_int(2)  -> background;
from_int(3)  -> spontaneous;
from_int(4)  -> initialized;
from_int(5)  -> request;
from_int(6)  -> act;
from_int(7)  -> act_con;
from_int(8)  -> deact;
from_int(9)  -> deact_con;
from_int(10) -> act_term;
from_int(11) -> return_remote;
from_int(12) -> return_local;
from_int(13) -> file_transfer;
from_int(20) -> interrogated_station;
from_int(N) when N >= 21, N =< 36 -> {interrogated_group, N - 20};
from_int(37) -> interrogated_counter;
from_int(N) when N >= 38, N =< 41 -> {interrogated_counter_group, N - 37};
from_int(44) -> unknown_type_id;
from_int(45) -> unknown_cot;
from_int(46) -> unknown_coa;
from_int(47) -> unknown_ioa;
from_int(N) when is_integer(N), N >= 0, N =< 63 -> N.
