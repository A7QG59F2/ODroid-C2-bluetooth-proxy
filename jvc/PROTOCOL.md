# KD-SX38MBT remote protocol (JVC Remote app, RFCOMM channel 16)

Decoded on 2026-11-11 from JVC Remote's own logcat output (`OpenLinkService_BT`,
`Outstream values` / `Instream values`), 168+ frames, all checksums verified.
`decode-logcat.py` turns such a log into the frame list used below.

Values marked *(unconfirmed)* were seen only once or are guesses.

## Frame format

```
7e | 0b 01 | src dst | grp cmd | seq | ack | 01 00 | len | payload… | crc_hi crc_lo | 7c
```

| Field | Meaning |
|---|---|
| `7e` … `7c` | start / end flag |
| `0b 01` | constant (protocol id / version) |
| src, dst | addresses: **`a4` = phone/remote**, **`50` = radio main unit**, **`16` = tuner** (all `8c xx` and `5c 20` frames), **`4c` = BT-audio module** (`5b 02/03/04/07/80/81/91`). The phone always sends to `50`; replies and notifications come from whichever unit owns them (`50 a4`, `16 a4`, `4c a4`). |
| grp, cmd | command group and command, see below |
| seq | per-sender sequence number, `+1` per data frame, wraps at `ff` |
| ack | `00` = data frame, `01` = acknowledgement of the frame with that seq |
| `01 00` | constant |
| len | payload length (one byte) |
| crc | **CRC-16/ARC** (poly 0x8005 reflected = 0xA001, init 0, no xorout) over `0b` … end of payload, **big-endian** |

**Escaping:** inside a frame (including the CRC), `7e` → `7d 5e` and `7d` → `7d 5d`
(HDLC style, XOR 0x20). The CRC is computed on the unescaped bytes.

**ACKs:** every data frame is acknowledged by the receiver of it: same dst/src/grp/cmd/seq,
ack = `01`, len = `01`, payload `00`. Note the ACK keeps the **original** src/dst order
(the phone ACKs a radio frame with `50 a4 …`, not `a4 50`). The phone ACKs everything the radio sends, and the
radio ACKs every command before any reply.

```python
def crc16_arc(data: bytes) -> int:
    c = 0
    for b in data:
        c ^= b
        for _ in range(8):
            c = (c >> 1) ^ 0xA001 if c & 1 else c >> 1
    return c
```

Example, Vol+ with seq `09`:
`7e 0b 01 a4 50 11 05 09 00 01 00 01 08 80 ce 7c`

## Connect handshake

Right after the RFCOMM link opens:

1. radio → `3b 02` (no payload). Phone ACKs and answers `5b 02 [00 00 01 01]`.
   If nobody answers, the radio repeats `3b 02` every ~2 s and drops the link after ~20 s.
2. The app then queries, each one ACKed and answered with a `5b xx` reply:

| Phone sends | Reply | Meaning |
|---|---|---|
| `3b 01` | `5b 01 [00 10 00 00]` | *(unconfirmed)* capabilities |
| `3b 34` | `5b 34 [ff 31 24 22 00 00 00 01]` | *(unconfirmed)* model / firmware |
| `3b 36` | `5b 36 [01]` | *(unconfirmed)* |
| `3b 35 [dow hh mm ss]` | `5b 35 [01]` | **set clock**, e.g. `03 00 10 2d` = Wed 00:16:45 |
| `3b 37 [yy yy mm dd]` | `5b 37 [01]` | **set date**, e.g. `14 1a 0b 0b` = 20 26 11 11 |
| `3b 12` | `5b 11 [01 00]`, `5b 12 […"FLAT"…]` | current source / EQ name |
| `3b 30` | 18 × `5b 30 [13 idx src_hi src_lo en]` | **source list**: `en` = `01` enabled, `00` disabled in the radio's settings, `ff` not available. Re-sent for one entry when it changes on the radio (enabling AM sent `[13 02 03 01 01]`). |

Then the radio pushes current status (`12 12`, `12 05`/`06`/`07` text, `12 03`).

## Keys: `11 05 [code]`

The meaning of a key depends on the current source.

| Code | App button | FM | BT audio |
|---|---|---|---|
| `01` | Mute / Play | mute | play/pause *(from the app it pauses <1 s then resumes; retest from the Odroid)* |
| `02` | Sound | next EQ preset | next EQ preset |
| `03` | Right | tune up | next track |
| `04` | Left | tune down | previous track |
| `05` | Up | next preset station | *(untested)* |
| `06` | Down | previous preset station | *(untested)* |
| `07` | Vol− | volume down | volume down |
| `08` | Vol+ | volume up | volume up |

The app has **no Power button**. Codes `09` and up are untried; test them from the Odroid
to look for power, play/pause on BT, etc.

**Disconnect:** the app sends no goodbye frame, it just closes the RFCOMM socket.
The link also drops on its own now and then (seen twice in ~45 min), so the bridge
must reconnect and redo the handshake.

## Source select: `11 01 [src_hi src_lo]`

| Source | ID |
|---|---|
| AUX | `02 00` |
| AM | `03 01` |
| FM | `03 02` |
| BT audio | `06 14` |

Radio confirms with `12 01 [x src_hi src_lo 01 <EQ name, 10 chars>]` (the EQ preset is per source).

## Radio → phone notifications

| Frame | Payload | Meaning |
|---|---|---|
| `12 04` | `[n]` | **volume** (0 … at least 18). Also sent when the knob is turned. |
| `12 02` | 10 chars | **EQ preset name** after a change |
| `12 01` | see above | **source changed** |
| `12 03` | `[f7 5c]` | periodic, *(unconfirmed)* |
| `8c 01` | `[band 00 hi lo]` | **tuner frequency**. band `02` = FM in 10 kHz units (`24 fe` = 9470 = 94.7 MHz); band `01` = AM in 1 kHz units (`03 e8` = 1000 kHz) |
| `8c 03` | `[01 band 00 hi lo]` | tuning in progress, target frequency |
| `8c 05`, `8c 06` | small flags | *(unconfirmed)* stereo / signal / preset number |
| `5c 20` | `[08 + 8 chars]` | **RDS text**, 8-character chunks every ~3 s |
| `5b 80` | 18-byte header + text | **track title** (BT audio) |
| `5b 81` | same | **artist** |
| `5b 91` | same | **album** |
| `5b 02` from `4c` | `[ss 00 00 00 00 00]` | **playback time**, `ss` = elapsed seconds in BCD (`16`, `17` … `22`), every 1 s; minutes field *(unconfirmed)* |
| `5b 07` | `[00 01 00 00 xx]` | status refresh after a key; **not** play/pause state |

## Settings: `3d xx` → `5d xx`

Each setting has a *list options* / *get* / *set* triple. Lists are a count followed by
fixed-width ASCII names. Sets are answered with `5d xx [01]` = OK.

| Setting | list | get | set | Values |
|---|---|---|---|---|
| EQ preset | `0d` | `0e` | `0f [n]` | 11 presets, 10 chars: FLAT, DVRN 3, DVRN 2, DVRN 1, HARDROCK, HIP HOP, JAZZ, POP, R&B, USER, CLASSICAL (`00`–`0a`) |
| EQ edit bands | `01` (13 names, 9 chars) | `04` | `05` (on SAVE) | see below |
| EQ Q options | `03` → `[03 01 35 01 50 02 00]` | | | 1.35 / 1.50 / 2.00, as index `00`–`02` |
| Bass (extend) | | `40` | `41 [00/01]` | Off / On, applied immediately |
| Bass Boost | `48` | `49` | `4a [n]` | Off, Level 1–5 |
| Loudness | `4b` | `4c` | `4d [n]` | Off, Level 1–2 |
| Fader / Balance | | `0b` | `0c [00 f 01 b]` | `0f` = center; front and right are **lower** numbers |
| Subwoofer on/off | | `4e` | *(not seen)* | `01` = ON |
| Subwoofer level | `42` → `[b2 0a]` | `43` | `44 [n]` | **scale unclear**, see note |
| Speaker sizes | `51`, `53` | `54` | | front / tweeter / rear / sub size lists |
| Time alignment | `5a`, `5b`, `5c` | `5d` | | distance / gain per channel |
| Car type | `5f`, `60` | `45` | | car type + rear speaker location |
| Illumination color | `10` → `[02 02 02 01]`, `12 [02]` → `[02 03 02 31 R G B]` *(unconfirmed)* | `14 [02 00 00]` → `[R G B]` | user RGB: `11 [00 03 00 01 R G B]`; preset: `11 [00 01 00 nn]` | RGB, 5 bits each (`00`–`1f`), same order for get and set; was `1f 1f 17`. Presets seen `01`–`17`; a preset recolors the **whole face** (all zones). The app sends bursts of 4–6 identical sets while dragging; the first burst once got `00` replies and the link reset, so send one set per change. Night-color zones and key beep changed **on the radio** produce no frames, and the app only ever reads `14 [02 00 00]`. To try from the Odroid: other `3d 14` parameters (e.g. `02 00 01`, `02 01 00`) to read the second zone / night colors (night was set to blue + magenta on 2026-11-11). |
| `50 [00]` | | → `02` | | *(unconfirmed)*, sent when the settings menu opens |
| `61 [00]` | | → `05 00` | | *(unconfirmed)*, sent when the sub screen opens |

**EQ bands** (`3d 04` reply / `3d 05` set): `[Q index] [band value] × 13`, bands `00`–`0c` =
62.5 Hz, 100, 160, 250, 400, 630, 1k, 1.6k, 2.5k, 4k, 6.3k, … Hz. **value = 9 − dB**
(`09` = 0 dB, `07` = +2 dB, `0a` = −1 dB). Edits only reach the radio on SAVE (one `3d 05`
with all 13 bands).

**Subwoofer level:** the radio first reported `3d 43` → `0a` with the app showing 10. Taps
in the app then sent `3d 44` with `01`, `02`, `03` in a non-monotonic order while the app's
display drifted, so the app can't be trusted here. Set it from the Odroid and read it back
with `3d 43` to work out the scale.
