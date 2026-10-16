<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

# The optional server

> **The wearable works fully standalone.** With BLE + on-device transcription
> (see [`APP.md`](APP.md)), the device and phone need no server at all — audio
> never leaves the phone. Everything in this document is **optional**: it applies
> only when the app is configured for *cloud* transcription or the
> chief-of-staff agent loop.

When a server is used, it is one **you run yourself**. The server for this
wearable is **[OrphusBot](../../README.md)**: `orphusbot-server` implements the
device channel below in Rust (see [OrphusBot DESIGN §9](../../docs/DESIGN.md)),
turns button captures into tasks for its bots, and talks back through the
duplex habitat. The original reference server was a separate private project
and is retired. This folder keeps a **reference copy** of the device-channel
code under [`server-contract/src/device/`](../server-contract) as the
specification the Rust implementation is tested against. There is no
third-party cloud account in either direction.

Contents:

- [The device channel](#the-device-channel) — HTTP + WebSocket endpoints
- [Self-hosted STT (Qwen3-ASR)](#self-hosted-stt-qwen3-asr-06b) — the accurate final transcript
- [Commands back to the wearable](#commands-back-to-the-wearable)
- [Exposing it off-LAN](#exposing-it-off-lan) — NetBird (OrphusBot's default) or a Cloudflare tunnel
- [How the app pairs](#how-the-app-pairs)

---

## The device channel

Source (reference copy): `server-contract/src/device/`. The wearable app talks
to these endpoints. HTTP calls authenticate with **`X-Device-Id` +
`X-Device-Token`**; the audio WebSocket carries its pairing token in the
**`Sec-WebSocket-Protocol`** header (a `?token=` query string is rejected).

| Endpoint | Method | Purpose |
|---|---|---|
| `/api/device/register` | POST | One-time pairing; returns the device id + pairing token |
| `/api/device/ws/audio` | WS | Audio stream in (Opus or linear16); emits transcripts |
| `/api/device/event` | POST | Button gesture codes from the wearable |
| `/api/device/text` | POST | Transcribed text (an `overheard` flag gates whether the agent replies) |
| `/api/device/command/poll` | GET | Drain the queued LED/haptic commands |
| `/api/device/voice-profile/train` | POST | Speaker enrolment |
| `/api/device/voice-profiles[/…]` | GET/POST | Manage stored voice profiles |
| `/api/device/voice-sample/latest` | GET | Latest captured voice sample |
| `/api/device/hands-free` | GET/POST | Hands-free mode |
| `/api/device/list` | GET | Registered devices |

**Audio WebSocket** (`ws-audio.ts`). Binary frames in are either Opus packets
(from the firmware, via the phone's BLE bridge) or 16 kHz PCM (from the phone
mic). The server spins up an Opus decoder per connection and decodes to
**PCM16, 16 kHz mono** server-side, so the STT provider always sees `linear16`.
The `frameMs` (10 ms / 20 ms) reflects the firmware's Opus packetization.

---

## Self-hosted STT (Qwen3-ASR-0.6B)

Behaviour of the original reference server's `stt.ts` (provider selection) and
`stt-selfhosted.ts` (the client). OrphusBot keeps the self-hosted Qwen3-ASR path
(see OrphusBot DESIGN §9.5) and drops the cloud fallbacks.

The server picks an STT provider from configuration (`selectSttProvider`):

- If **`STT_SELFHOSTED_URL`** is set → the self-hosted **Qwen3-ASR-0.6B** service
  (provider tag `selfhosted:qwen3-asr-0.6b`).
- Otherwise it falls back to a cloud provider by API key — Soniox, or Deepgram
  (`nova-3` / `nova-2-general`).

**Why self-hosted Qwen3 is the accurate path.** Measured on the same wearable
channel as the on-device models (this firmware's Opus + reverb + 10 dB babble),
recorded in [`research/ASR_CANDIDATES.md`](research/ASR_CANDIDATES.md):

| Model | WER (wearable channel) | Notes |
|---|---|---|
| **Qwen3-ASR-0.6B** (self-hosted) | **6.24%** | Apache-2.0, 0.6B params, ~2.3 GB VRAM, batch |
| SenseVoice-2024 (prev. best on-channel) | 9.0% | — |
| zipformer-small (on-device incumbent) | 11.2% | the phone's saved-transcript model |

Qwen3-ASR is a **batch** transcriber, not streaming: it returns the accurate
**final** transcript for a *complete* utterance. So the division of labour is:
the phone runs its on-device streaming zipformer for the live preview, and the
server supplies the high-accuracy final. `stt-selfhosted.ts` buffers the decoded
PCM16 frames and, on WebSocket close (the natural per-utterance boundary), POSTs
the whole utterance to the service's `/transcribe` endpoint (16 kHz mono int16,
capped at 120 s ≈ 3.84 MB) and emits one final `Utterance`.

The Qwen3 service itself (a small Python server) runs on the AI server and is
reached either directly on the LAN or, off-LAN, through the Cloudflare tunnel
below.

---

## Commands back to the wearable

The reverse path turns agent results into the wearable's LED/haptic vocabulary:

```
agent result ─► alert-mapping.ts (pick a cue) ─► commands.ts (encode 4-byte packet)
            ─► channel.ts (queue) ─► app GET /api/device/command/poll
            ─► app writes GATT 0xCAB1AB97 ─► firmware agent_commands.c ─► NeoPixel / motor
```

`commands.ts` is the **authority** for the 4-byte wire format and the
`HABITAT_CUE` id table; it is mirrored verbatim in the firmware's
`agent_commands.h` and the app's `command_codec.dart`, and the mapping is
verified by `server-contract/tests/device.test.ts`. The cue vocabulary itself is
documented in [`HABITAT_ALERTS.md`](HABITAT_ALERTS.md).

---

## Exposing it off-LAN

**OrphusBot's default is [NetBird](https://netbird.io):** the phone, the server
and your other machines join one private WireGuard network, so the phone
reaches the server's device channel off-LAN with nothing exposed to the
internet. Pair the app to the server's NetBird name or address.

**Alternative: a Cloudflare tunnel with Access.** Run a named `cloudflared`
tunnel from the server to `localhost`, put it behind a Cloudflare Access
service-token policy (never open to the world), and pair the app to the
tunnel's HTTPS hostname (for example `https://stt.example.com`). The app must
then send the `CF-Access-Client-Id` / `CF-Access-Client-Secret` headers on the
WebSocket handshake and HTTP calls; that change is not in the app yet.

---

## How the app pairs

From the app's pairing page (`app/lib/wearable/pages/pairing_page.dart`, client
in `wearable_client.dart`):

1. **With OrphusBot:** in OrphusBot's Settings → Wearable, choose **Pair a
   wearable**. It shows the server address and a one-time code (valid 10 minutes).
   In the app's pairing page, enter the address and paste the code where it asks
   for the bearer token; `POST /api/device/register` uses it once and returns the
   device id + pairing token. (On a LAN without OrphusBot's address, mDNS
   discovery via `_wearable._tcp.local` still works.)
2. **Off-LAN:** the operator pairs to a remote HTTPS `baseUrl` (e.g.
   `https://stt.example.com` or the server's NetBird name) instead of the LAN IP.
   `openAudioStream()` derives the WebSocket URL from the stored `baseUrl`
   (`https` → `wss`), so no code changes — only the Cloudflare Access headers, if
   the tunnel is live.
3. Credentials — `(baseUrl, bearer, deviceId, pairingToken)` — are stored in
   `flutter_secure_storage`.

Once paired in cloud mode, the BLE bridge forwards audio and button events to the
server and drains its command queue back to the wearable, as described in
[`APP.md`](APP.md).
