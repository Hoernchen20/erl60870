# Conformance

Which ASDU type IDs this library implements today, and over which side of
which companion standard. Type ID numbers are shared between IEC 60870-5-101
and -104 — both name the same ASDU on the wire — so one table covers both.

Current status, in one line: a 104 **server** implements the full v1 type set
below end to end (see [docs/DESIGN.md](DESIGN.md) section 10 for the encoding
decisions behind it). The 104 **client** and **101** are not implemented yet
— see the [README roadmap](../README.md#roadmap) — so their columns are all
"not yet" regardless of type ID; once they land they reuse the same ASDU
codec (`iec60870_asdu`, `iec60870_type`), so the v1 column will carry over
unchanged.

Legend: ✅ supported · — not yet implemented

## Process information in monitor direction

| ID | Name | Description | 104 server | 104 client | 101 |
|---:|------|--------------|:---:|:---:|:---:|
| 1  | M_SP_NA_1 | Single-point information | ✅ | — | — |
| 2  | M_SP_TA_1 | Single-point information with time tag (CP24Time2a) | — | — | — |
| 3  | M_DP_NA_1 | Double-point information | ✅ | — | — |
| 4  | M_DP_TA_1 | Double-point information with time tag (CP24Time2a) | — | — | — |
| 5  | M_ST_NA_1 | Step position information | ✅ | — | — |
| 6  | M_ST_TA_1 | Step position information with time tag (CP24Time2a) | — | — | — |
| 7  | M_BO_NA_1 | Bitstring of 32 bit | — | — | — |
| 8  | M_BO_TA_1 | Bitstring of 32 bit with time tag (CP24Time2a) | — | — | — |
| 9  | M_ME_NA_1 | Measured value, normalized value | ✅ | — | — |
| 10 | M_ME_TA_1 | Measured value, normalized value with time tag (CP24Time2a) | — | — | — |
| 11 | M_ME_NB_1 | Measured value, scaled value | ✅ | — | — |
| 12 | M_ME_TB_1 | Measured value, scaled value with time tag (CP24Time2a) | — | — | — |
| 13 | M_ME_NC_1 | Measured value, short floating point value | ✅ | — | — |
| 14 | M_ME_TC_1 | Measured value, short floating point value with time tag (CP24Time2a) | — | — | — |
| 15 | M_IT_NA_1 | Integrated totals | ✅ | — | — |
| 16 | M_IT_TA_1 | Integrated totals with time tag (CP24Time2a) | — | — | — |
| 17 | M_EP_TA_1 | Event of protection equipment with time tag (CP24Time2a) | — | — | — |
| 18 | M_EP_TB_1 | Packed start events of protection equipment with time tag (CP24Time2a) | — | — | — |
| 19 | M_EP_TC_1 | Packed output circuit info of protection equipment with time tag (CP24Time2a) | — | — | — |
| 20 | M_PS_NA_1 | Packed single-point information with status change detection | — | — | — |
| 21 | M_ME_ND_1 | Measured value, normalized value without quality descriptor | — | — | — |
| 30 | M_SP_TB_1 | Single-point information with time tag CP56Time2a | ✅ | — | — |
| 31 | M_DP_TB_1 | Double-point information with time tag CP56Time2a | ✅ | — | — |
| 32 | M_ST_TB_1 | Step position information with time tag CP56Time2a | — | — | — |
| 33 | M_BO_TB_1 | Bitstring of 32 bit with time tag CP56Time2a | — | — | — |
| 34 | M_ME_TD_1 | Measured value, normalized value with time tag CP56Time2a | ✅ | — | — |
| 35 | M_ME_TE_1 | Measured value, scaled value with time tag CP56Time2a | ✅ | — | — |
| 36 | M_ME_TF_1 | Measured value, short floating point value with time tag CP56Time2a | ✅ | — | — |
| 37 | M_IT_TB_1 | Integrated totals with time tag CP56Time2a | ✅ | — | — |
| 38 | M_EP_TD_1 | Event of protection equipment with time tag CP56Time2a | — | — | — |
| 39 | M_EP_TE_1 | Packed start events of protection equipment with time tag CP56Time2a | — | — | — |
| 40 | M_EP_TF_1 | Packed output circuit info of protection equipment with time tag CP56Time2a | — | — | — |

## Process information in control direction

| ID | Name | Description | 104 server | 104 client | 101 |
|---:|------|--------------|:---:|:---:|:---:|
| 45 | C_SC_NA_1 | Single command | ✅ | — | — |
| 46 | C_DC_NA_1 | Double command | ✅ | — | — |
| 47 | C_RC_NA_1 | Regulating step command | ✅ | — | — |
| 48 | C_SE_NA_1 | Set point command, normalized value | ✅ | — | — |
| 49 | C_SE_NB_1 | Set point command, scaled value | ✅ | — | — |
| 50 | C_SE_NC_1 | Set point command, short floating point value | ✅ | — | — |
| 51 | C_BO_NA_1 | Bitstring of 32 bit | — | — | — |
| 58 | C_SC_TA_1 | Single command with time tag CP56Time2a | — | — | — |
| 59 | C_DC_TA_1 | Double command with time tag CP56Time2a | — | — | — |
| 60 | C_RC_TA_1 | Regulating step command with time tag CP56Time2a | — | — | — |
| 61 | C_SE_TA_1 | Set point command, normalized value with time tag CP56Time2a | — | — | — |
| 62 | C_SE_TB_1 | Set point command, scaled value with time tag CP56Time2a | — | — | — |
| 63 | C_SE_TC_1 | Set point command, short floating point value with time tag CP56Time2a | — | — | — |
| 64 | C_BO_TA_1 | Bitstring of 32 bit with time tag CP56Time2a | — | — | — |

## System information

| ID | Name | Description | 104 server | 104 client | 101 |
|---:|------|--------------|:---:|:---:|:---:|
| 70  | M_EI_NA_1 | End of initialization | ✅ | — | — |
| 100 | C_IC_NA_1 | Interrogation command | ✅ | — | — |
| 101 | C_CI_NA_1 | Counter interrogation command | ✅ | — | — |
| 102 | C_RD_NA_1 | Read command | ✅ | — | — |
| 103 | C_CS_NA_1 | Clock synchronization command | ✅ | — | — |
| 104 | C_TS_NA_1 | Test command | — | — | — |
| 105 | C_RP_NA_1 | Reset process command | — | — | — |
| 106 | C_CD_NA_1 | Delay acquisition command | — | — | — |
| 107 | C_TS_TA_1 | Test command with time tag CP56Time2a | ✅ | — | — |

## Parameter in control direction

| ID | Name | Description | 104 server | 104 client | 101 |
|---:|------|--------------|:---:|:---:|:---:|
| 110 | P_ME_NA_1 | Parameter of measured value, normalized value | ✅ | — | — |
| 111 | P_ME_NB_1 | Parameter of measured value, scaled value | ✅ | — | — |
| 112 | P_ME_NC_1 | Parameter of measured value, short floating point value | ✅ | — | — |
| 113 | P_AC_NA_1 | Parameter activation | ✅ | — | — |

## File transfer

Not implemented. IDs 120–127 (`F_FR_NA_1` … `F_SC_NB_1`) are out of scope for
now and not on the roadmap.

## System parameters — field widths

The data-unit identifier's field widths are configurable per link
(`iec60870_asdu:opts()`), defaulting to the IEC 60870-5-104 norm. 101 is
expected to reuse the same options once its link layer lands (they are
already transport-free, [docs/DESIGN.md](DESIGN.md) sections 2 and 9).

| Field | Width | 104 default | Configurable |
|---|---|---|:---:|
| Type identification | 1 octet | fixed | — |
| Variable structure qualifier | 1 octet | fixed | — |
| Cause of transmission (COT) | 1 or 2 octets | 2 | ✅ `cot_size` |
| Common address of ASDU (CA) | 1 or 2 octets | 2 | ✅ `coa_size` |
| Information object address (IOA) | 1, 2, or 3 octets | 3 | ✅ `ioa_size` |
| APCI (start + length + control field) | 6 octets | fixed | — (104 only) |
| Maximum ASDU length | 249 octets | fixed | — |
| Maximum APDU length (APCI + ASDU) | 253 octets | fixed | — (104 only; a 101 frame's length is a link-layer property, not yet implemented) |

## Timers and flow control

Configured per connection via `iec60870_104_conn:params()`
([docs/DESIGN.md](DESIGN.md) section 4); all are enforced at start
(`validate_params/1`), not just documented defaults.

| Parameter | Standard range | Default | This library |
|---|---|---:|---|
| t0 — connection establishment | 1–255 s | — | not applicable yet: no client to establish connections (roadmap) |
| t1 — sent I/U-frame confirmation | 1–255 s | 15 s | enforced; closes the connection on expiry |
| t2 — acknowledge received I-frames | 1–255 s, t2 < t1 | 10 s | enforced (`t2 < t1` validated) |
| t3 — idle-line test | 1–172800 s | 20 s | enforced; sends `TESTFR_ACT` |
| k — max unacknowledged I-frames | 1–32767 | 12 | enforced |
| w — ack-by-count threshold | 1–32767, w ≤ ⅔k | 8 | enforced (`w ≤ (2·k) div 3`) |

Note: this library validates each parameter is a positive integer (plus the
relations above) but does not itself clamp to the standard's upper bounds —
the "standard range" column is for reference, not a limit this code imposes.

## Redundancy groups

Edition 2 redundancy, all three modes from v1 ([docs/DESIGN.md](DESIGN.md)
section 5, decision #3):

| Mode | Behaviour | Supported |
|---|---|:---:|
| `connection` | each accepted connection is its own group — classic multi-master, no redundancy | ✅ |
| `single` | all connections share one group; exactly one member `active` at a time | ✅ |
| `multiple` | explicitly configured groups, connections matched to a group by peer IP/prefix | ✅ |

Each group owns a bounded, ordered event buffer with drop-oldest overflow and
replays everything unacknowledged to a newly-promoted active connection on
switchover — see [docs/DESIGN.md](DESIGN.md) section 5 for the full
mechanism.

## TLS (IEC 62351-3)

Supported for the 104 server (`transport => {tls, SslOpts}`); not yet
wired for a 104 client or for 101. Defaults filled in by
`iec60870_tls:server_opts/1` for whichever the caller hasn't already set
([docs/DESIGN.md](DESIGN.md) section 11):

| Option | Default |
|---|---|
| `versions` | `['tlsv1.2', 'tlsv1.3']` |
| `verify` | `verify_peer` (mutual auth, the 62351-3 norm) |
| `fail_if_no_peer_cert` | `true` (only added when `verify` resolves to `verify_peer`) |
| `ciphers` | AEAD + forward-secret only (TLS 1.3 suites plus ECDHE-\*-GCM/CHACHA20 for 1.2) |
| `port` | `19998` (the IEC 62351-3 secure-104 convention) |

Caller-supplied options always win, including certificates — there is no
library default for `cert`/`key`/`cacerts`, so a `tls` listener with none set
fails to start.

## Notes

- The CP24Time2a-tagged monitor types (2, 4, 6, 8, 10, 12, 14, 16–19) are
  conventionally 101-only and superseded by their CP56Time2a counterparts
  (30–40); this library only implements the CP56 variants (decision in
  [docs/DESIGN.md](DESIGN.md) section 10).
- "104 server" supported means wired end to end: reachable through the
  default data model, general/counter interrogation, background scan,
  spontaneous transmission, and (for commands) the `iec60870_server`
  callback behaviour — not merely encodable by the ASDU codec.
