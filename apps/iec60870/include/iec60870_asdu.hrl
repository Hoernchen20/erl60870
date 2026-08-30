%% -*- erlang -*-
%%%
%%% IEC 60870-5 ASDU layer — shared record and constant definitions.
%%%
%%% Public header. These records are the internal representation produced and
%%% consumed by `iec60870_asdu' (the codec) and by user code that assembles
%%% ASDUs by hand (docs/DESIGN.md section 8). The public *API* speaks maps;
%%% records are the internal form (decision 5).

-ifndef(IEC60870_ASDU_HRL).
-define(IEC60870_ASDU_HRL, true).

%% Maximum ASDU size in octets for IEC 60870-5-104 (APDU max 253; see
%% docs/DESIGN.md section 4). Used when batching objects into ASDUs.
-define(IEC60870_ASDU_MAX_OCTETS, 249).

%% CP56Time2a — 7-octet binary time (IEC 60870-5-4, section 6.8).
%% `year' counts from 2000; `day_of_week' 0 means "not used".
-record(cp56, {
    milliseconds = 0     :: 0..59999,
    minute       = 0     :: 0..59,
    hour         = 0     :: 0..23,
    day_of_month = 1     :: 1..31,
    day_of_week  = 0     :: 0..7,
    month        = 1     :: 1..12,
    year         = 0     :: 0..99,
    summer_time  = false :: boolean(),
    invalid      = false :: boolean()
}).

%% QDS — quality descriptor (1 octet), shared by most monitored-information
%% types (IEC 60870-5-3, section 6). Carried on `#object.quality' as an atom
%% list; this record is the expanded internal form.
-record(qds, {
    overflow    = false :: boolean(),
    blocked     = false :: boolean(),
    substituted = false :: boolean(),
    not_topical = false :: boolean(),
    invalid     = false :: boolean()
}).

%% One information object: an address plus its decoded, type-specific payload.
%%
%%   value     - decoded per type id (boolean | 0..3 | integer | float | ...)
%%   quality   - quality flags as an atom list, [] when nominal
%%               ([overflow | blocked | substituted | not_topical | invalid])
%%   timestamp - #cp56{} for the timestamped variants (_TB_, _TD_, ...),
%%               otherwise undefined
%%   qualifier - command / qualifier extras where a type carries them
%%               (select bit, QU, QOS, QOI, QCC, QRP, ...)
-record(object, {
    ioa                     :: non_neg_integer(),
    value                   :: term(),
    quality   = []          :: [atom()],
    timestamp = undefined   :: #cp56{} | non_neg_integer() | undefined,
    qualifier = undefined   :: term()
}).

%% One ASDU: the data-unit identifier plus its information objects.
%%
%%   type     - type identification, as an atom (see iec60870_asdu:type_name/0)
%%              or the raw integer for types the codec does not model
%%   cot      - cause of transmission, as an atom (see iec60870_cot) or integer
%%   negative - P/N bit; true = negative confirmation
%%   test     - T bit; true = test ASDU
%%   sequence - VSQ SQ bit; true = sequence of objects sharing a base IOA
-record(asdu, {
    type                 :: atom() | 0..255,
    cot                  :: atom() | 0..63,
    negative  = false    :: boolean(),
    test      = false    :: boolean(),
    orig_addr = 0        :: 0..255,
    coa                  :: 0..65535,
    sequence  = false    :: boolean(),
    objects   = []       :: [#object{}]
}).

-endif.
