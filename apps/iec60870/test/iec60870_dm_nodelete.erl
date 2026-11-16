-module(iec60870_dm_nodelete).
-moduledoc "Test data model without the optional `delete/3` (wraps `iec60870_dm_ets`).".
-behaviour(iec60870_data_model).

-export([init/1, terminate/1, read/3, write/4, fold/5, coas/1,
         fold_counters/5, freeze_counters/4]).

init(Args) -> iec60870_dm_ets:init(Args).
terminate(St) -> iec60870_dm_ets:terminate(St).
read(St, C, I) -> iec60870_dm_ets:read(St, C, I).
write(St, C, I, P) -> iec60870_dm_ets:write(St, C, I, P).
fold(St, C, G, F, A) -> iec60870_dm_ets:fold(St, C, G, F, A).
coas(St) -> iec60870_dm_ets:coas(St).
fold_counters(St, C, G, F, A) -> iec60870_dm_ets:fold_counters(St, C, G, F, A).
freeze_counters(St, C, G, Fr) -> iec60870_dm_ets:freeze_counters(St, C, G, Fr).
