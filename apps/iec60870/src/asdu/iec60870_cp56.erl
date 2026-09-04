-module(iec60870_cp56).
-moduledoc """
CP56Time2a — the 7-octet binary time of IEC 60870-5-4 section 6.8.

Wire layout (octet 1 first, little-endian for the millisecond field):

```text
  1-2  milliseconds of the minute, 0..59999   (octet 1 = LSB)
  3    IV:1  RES1:1  minutes:6                 (0..59)
  4    SU:1  RES2:2  hours:5                   (0..23)
  5    day-of-week:3  day-of-month:5           (dow 0 = not used, dom 1..31)
  6    RES3:4  month:4                         (1..12)
  7    RES4:1  year:7                          (0..99, counted from 2000)
```

The record lives in `include/iec60870_asdu.hrl` because hand-assembled ASDUs
(`docs/DESIGN.md` section 8) carry it on the public surface.
""".

-include_lib("iec60870/include/iec60870_asdu.hrl").

-export([to_binary/1, from_binary/1]).
-export([from_datetime/1, to_datetime/1, from_timestamp/1, to_timestamp/1]).

-define(EPOCH_GREGORIAN_SECONDS, 62167219200). %% {{1970,1,1},{0,0,0}}

-doc "Encode a `#cp56{}` into its 7 wire octets.".
-spec to_binary(#cp56{}) -> <<_:56>>.
to_binary(#cp56{milliseconds = MS, minute = Min, hour = Hour,
                day_of_month = DoM, day_of_week = DoW, month = Month,
                year = Year, summer_time = SU, invalid = IV})
  when MS >= 0, MS =< 59999, Min >= 0, Min =< 59, Hour >= 0, Hour =< 23,
       DoM >= 1, DoM =< 31, DoW >= 0, DoW =< 7, Month >= 1, Month =< 12,
       Year >= 0, Year =< 99 ->
    <<MS:16/little-unsigned,
      (bit(IV)):1, 0:1, Min:6,
      (bit(SU)):1, 0:2, Hour:5,
      DoW:3, DoM:5,
      0:4, Month:4,
      0:1, Year:7>>.

-doc "Decode 7 wire octets into a `#cp56{}`. Reserved bits are ignored.".
-spec from_binary(<<_:56>>) -> #cp56{}.
from_binary(<<MS:16/little-unsigned,
              IV:1, _:1, Min:6,
              SU:1, _:2, Hour:5,
              DoW:3, DoM:5,
              _:4, Month:4,
              _:1, Year:7>>) ->
    #cp56{milliseconds = MS, minute = Min, hour = Hour,
          day_of_month = DoM, day_of_week = DoW, month = Month, year = Year,
          summer_time = SU =:= 1, invalid = IV =:= 1}.

-doc """
Build a `#cp56{}` from a `t:calendar:datetime/0`. Sub-second precision comes
out as 0; set `#cp56.milliseconds` afterwards if it matters. The day-of-week
field is filled in.
""".
-spec from_datetime(calendar:datetime()) -> #cp56{}.
from_datetime({{Year, Month, Day}, {Hour, Min, Sec}}) ->
    #cp56{milliseconds = Sec * 1000,
          minute = Min, hour = Hour, day_of_month = Day, month = Month,
          year = Year rem 100,
          day_of_week = calendar:day_of_the_week(Year, Month, Day)}.

-doc """
`#cp56{}` to `t:calendar:datetime/0`, truncating to whole seconds and
resolving the two-digit year into 2000..2099.
""".
-spec to_datetime(#cp56{}) -> calendar:datetime().
to_datetime(#cp56{milliseconds = MS, minute = Min, hour = Hour,
                  day_of_month = Day, month = Month, year = Year}) ->
    {{2000 + Year, Month, Day}, {Hour, Min, MS div 1000}}.

-doc """
Build a `#cp56{}` from milliseconds since the Unix epoch, interpreted as UTC.
The higher layers decide UTC vs. local before calling the codec.
""".
-spec from_timestamp(integer()) -> #cp56{}.
from_timestamp(Millis) when is_integer(Millis) ->
    Base = from_datetime(calendar:system_time_to_universal_time(Millis, millisecond)),
    Base#cp56{milliseconds = (Base#cp56.milliseconds) + (Millis rem 1000)}.

-doc """
`#cp56{}` to milliseconds since the Unix epoch, interpreting the value as UTC
and the year as 2000..2099.
""".
-spec to_timestamp(#cp56{}) -> integer().
to_timestamp(#cp56{milliseconds = MS, minute = Min, hour = Hour,
                   day_of_month = Day, month = Month, year = Year}) ->
    Secs = calendar:datetime_to_gregorian_seconds(
             {{2000 + Year, Month, Day}, {Hour, Min, 0}}),
    (Secs - ?EPOCH_GREGORIAN_SECONDS) * 1000 + MS.

bit(true) -> 1;
bit(false) -> 0.
