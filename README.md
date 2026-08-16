<h1 align="center">Bounce</h1>

<p align="center">
  <strong>Your Plaud recordings, transcribed on your iPhone, sent wherever you want.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-iOS%2026%2B-blue" alt="iOS 26+">
  <img src="https://img.shields.io/badge/SwiftUI-Liquid%20Glass-orange" alt="SwiftUI Liquid Glass">
  <img src="https://img.shields.io/badge/transcription-on--device-green" alt="On-device transcription">
</p>

---

Bounce pairs with a Plaud recorder over Bluetooth or WiFi, pulls your recordings onto your iPhone, transcribes them **on the device by default**, and hands them off to wherever you actually keep things — the share sheet, a webhook, a folder in Files or iCloud Drive, or any Shortcuts automation.

By default there is no transcription server, no speech API key, and audio never leaves the phone to become text. A **Soniox** cloud engine is available as an explicit opt-in in Settings for higher accuracy and more languages — turning it on uploads recording audio to Soniox's servers, and Bounce says so plainly before you do. The default stays on-device, and if Soniox is ever unreachable Bounce falls back to on-device automatically.

## Quick start

```bash
brew install xcodegen

cd app
xcodegen generate
open Bounce.xcodeproj
```

Select a **physical iPhone** and run. The Plaud frameworks are `arm64` device-only, so the simulator cannot build.

There is nothing to configure in the project — Bounce asks for your Plaud **Client ID** and **Secret Key** on first launch and keeps them in the keychain. No credentials live in any build file.

### Requirements

| | |
|---|---|
| Xcode | 26.0+ |
| iPhone | iOS 26.0+ (required for on-device `SpeechAnalyzer`) |
| Credentials | A Plaud **partner** Client ID + Secret Key |
| Hardware | A Plaud NotePro, NotePin, or NotePinS |

Create an Embedded SDK Application in the [Plaud Developer Portal](https://portal.plaud.ai) to get the credentials. These are B2B credentials — they are not available through the consumer Plaud app.

### Three things worth knowing before you start

1. **Bounce signs itself in.** Plaud user tokens last ~24 hours and have **no refresh mechanism**, so an app holding only a token stops working after a day. Bounce instead holds your Client ID and Secret Key and mints its own tokens on demand — a fresh partner token (1 h) then a user token — so you never sign in again and no backend is required.
2. **Those credentials are account-level.** They can mint tokens for any user id in your Plaud application, not just yours. Bounce keeps them in the keychain: encrypted at rest, `ThisDeviceOnly` so they are excluded from backups, never synced to iCloud, never logged, and Face ID gated to view. That is a sound trade for a personal app on a passcode-protected phone — but if you ever ship this to other people, move token minting to a server. See [docs/architecture.md](docs/architecture.md#authentication).
3. **A Plaud device binds to one app at a time.** Pairing with Bounce unbinds it from the official Plaud app, and vice versa. Unpair in Settings to hand it back.

### WiFi Fast Transfer is off by default

It requires the `HotspotConfiguration` and `wifi-info` entitlements, which Apple grants only to a **paid** Developer Program membership — a free Personal Team cannot sign them, and the build fails outright if they are declared. So the repo ships with them off, which also means Bounce currently requests **no location permission at all** (`NEHotspotConfigurationManager` is the only thing that needed it).

Everything else works on a free Apple ID: Bluetooth sync, on-device transcription, all delivery destinations, Shortcuts, recording control, firmware updates.

To enable it after enrolling, uncomment the three blocks marked `[WIFI FAST TRANSFER]` in `app/project.yml` and run `xcodegen generate`. No Swift changes needed — see `App/AppCapabilities.swift`.

> **Free provisioning caveats:** the app stops launching after **7 days** and needs another Run from Xcode (your data survives — only deleting the app wipes it). And if you later switch from a free team to a paid one, your **Team ID changes, so keychain items become unreadable** and you'll re-enter your Plaud credentials once. Recordings are unaffected.

## Features

| | |
|---|---|
| **On-device transcription** | Apple's `SpeechAnalyzer` / `SpeechTranscriber`. Per-phrase timestamps drive tap-a-line-to-seek playback. Language models download once and are shared with other apps. |
| **Optional cloud engine** | Soniox can be used instead, for speaker diarization, language hints and custom vocabulary. **On-device stays the default and the fallback** — any Soniox failure quietly finishes the transcript locally rather than losing it. Choosing Soniox uploads audio; nothing else in the app does. |
| **Auto-organize** | After each transcription, Apple Intelligence classifies the recording into one of your categories, titles it if you haven't, and runs that category's summary templates — all on device. Categories and templates are yours to define, edit and delete. Skipped cleanly on hardware without Apple Intelligence. |
| **Editable AI prompts** | Every instruction Bounce sends the on-device model is editable in Settings › AI › Prompts, with per-prompt and global Reset. Placeholders like `{transcript}` are listed and insertable. Editing changes how well a feature works, never whether the app runs — output structure is enforced separately. |
| **Tasks** | Action items are extracted after each transcription and collected in a Tasks tab as **proposals**, grouped by recording. Nothing is sent anywhere automatically — you review them and tap **Send** on the ones you want, per task or per recording. Sent tasks go to whatever destinations you've turned on: **Apple Reminders** (two-way completion, with the due date when one was spoken), **Calendar** (for tasks with a deadline), or a **webhook** (never includes the transcript). Ticking one off survives a re-transcribe. |
| **Ask your library** | On-device Q&A over a recording or across everything, grounded on the transcript via Apple Intelligence. Nothing leaves the phone. |
| **Tags and categories** | A recording can carry several tags at once, and the Library filters to recordings having *all* of them — the thing folders can't do. Tags are stored by identity, so renaming keeps every attachment. |
| **Named speakers** | Map `Speaker 1/2` to real names, with previously-used names and the recording's calendar attendees offered first. Names flow into the transcript view and every export. **Bounce does not recognise voices** — no engine it uses can — and the UI says so plainly. |
| **Apple Watch** | Start, stop, pause and mark a moment from your wrist, with the recorder's connection and battery on screen. A remote for the iPhone — the phone still owns the Bluetooth link — and a tap wakes Bounce in the background, so it works with the app closed. **Not embedded by default**: see the `[WATCH APP]` block in `app/project.yml`. |
| **Meeting series** | Group the sessions of a recurring meeting so each one is read against the ones before it: a per-session "since last time" recap plus a running "where this stands" note for the series. Recordings matching a repeating calendar event group themselves. Existing recordings can be folded in with one pass. On device, and the prompt is editable. |
| **Geotagged recordings + Map** | Optionally tag a recording with where it happened and browse the library on a map, filtered by the same search, category and tag filters as the list. One location reading is taken when the recorder starts recording — never in the background, never continuously — with a matched calendar event's location and an explicitly-labelled "synced here" reading as fallbacks. Any location can be searched for, tapped in, or removed. Off by default; locations never leave the phone and are never delivered. |
| **Calendar-aware naming** | Optionally name a recording after the meeting it happened in, from any calendar on the phone. It only names recordings you haven't titled, never writes to your calendar, and won't borrow a meeting name for a short recording. It links a meeting automatically only when it's confident and unambiguous; otherwise a **Link to a meeting** picker offers the meetings before, during and after the recording so you can tap the right one. A meeting you pick — or clear — by hand sticks, and is never overwritten by a re-transcription. Off by default. |
| **Correct a word everywhere** | Fix a misheard name once and replace every occurrence, with a count before you commit. Timings are preserved, so tap-to-seek keeps working, and on Soniox it offers to add the word to your vocabulary so future recordings get it right. |
| **Markdown export** | A transcript style that writes an Obsidian/Logseq-ready `.md` note — YAML frontmatter, summaries as sections, speaker-labelled paragraphs. Combined with the Files/iCloud destination, recordings land straight in a vault. |
| **Lossless audio editing** | Trim, cut a range out, or auto-remove silent gaps, then save as a new recording — the original is never modified. Audio is copied frame by frame rather than re-encoded, so there's no quality loss (cuts land on a ~36 ms frame boundary). The transcript is re-timed onto the edited audio rather than thrown away. |
| **Join recordings into one** | A recorder closes its file every time you stop, so a session captured in bursts arrives as many rows. **Join with…** combines them into one recording with one transcript, oldest first, with a chapter heading at each seam. Or say **Continue a recording…** while recording and the two are joined automatically once it syncs. Audio is concatenated frame by frame — no re-encode. (For a brief break, plain **pause** already keeps everything in one file.) |
| **Send anywhere** | Native share sheet, multipart webhook POST, and auto-export to a Files/iCloud Drive folder. |
| **Shortcuts + Siri** | Five App Intents (`Get Latest Transcript`, `Get Transcript`, `Transcribe Recording`, `Send Recording`, `Sync Recorder`) so automations can route recordings into anything with a Shortcuts action. |
| **Auto-sync** | Reconnects to your recorder in the background and pulls anything new, then transcribes and optionally delivers it — untouched. |
| **WiFi Fast Transfer** | ~10× faster than Bluetooth for long recordings. **Off by default** — needs a paid Apple Developer account, see below. |
| **Desktop view** | Read, search and organize your library from a browser on the same network — including Ask, answered on the phone. The iPhone is the server; nothing goes to a cloud. **Off by default**, needs a pairing code, encrypted with a certificate the phone mints itself (so your browser warns once), and Bounce has to stay on screen while it runs. |
| **Local API + MCP** | A documented HTTP API on your own network, and an MCP server so Claude Desktop and other agents can search and read your library. Bearer-token auth, generated on demand and revocable. **A token is read-only across the whole API** — nothing holding one can delete or change a recording. See [docs/api.md](docs/api.md). |
| **Multi-device** | Pair several recorders and switch between them. |
| **Low-battery alerts** | Notifies you once when the recorder drops below a threshold you pick, and stays quiet until it has charged back up. Off by default. Bounce has to be running to see the reading. |
| **Firmware updates** | OTA, handled end to end by the SDK. |
| **Liquid Glass** | SwiftUI throughout, built against the iOS 26 design language, and it honours Reduce Transparency. |

## Repository layout

```
Bounce/
├── app/                                  # The Bounce app — this is what you build
│   ├── project.yml                       # XcodeGen spec (source of truth, not .xcodeproj)
│   ├── WebClient/                        # Desktop view's browser front-end (HTML/CSS/JS)
│   └── Bounce/
│       ├── App/                          # SwiftUI entry point
│       ├── Auth/                         # Keychain credentials + token minting
│       ├── Audio/                        # Lossless MP3 frame editing (trim, cut, silence) and joining
│       ├── Device/                       # Plaud SDK integration (ported from the template)
│       ├── Transcription/                # On-device SpeechAnalyzer pipeline, AI passes
│       ├── Delivery/                     # Webhook, folder export, App Intents
│       ├── Web/                          # Local HTTP server, REST API, MCP endpoint
│       ├── Storage/                       # Local persistence
│       ├── State/                        # Combine → SwiftUI bridge
│       └── UI/                           # SwiftUI views
├── sdk/                                  # Precompiled Plaud SDK (proprietary, do not edit)
│   ├── ios/                              # arm64 .frameworks + resource bundle
│   └── android/plaud-sdk.aar
├── reference/plaud-template-app-uikit/   # Plaud's original UIKit sample, kept for reference
└── docs/
```

## Architecture

Bounce keeps Plaud's reference integration where it earns its place and replaces it where it doesn't.

The **device layer** (`Device/`) is ported near-verbatim from Plaud's UIKit template. `DeviceManager` is the single `PlaudDeviceAgentProtocol` delegate — the SDK has one delegate slot — and fans callbacks out to `RecordingManager` and `SyncManager`. Its reconnect, OTA, and WiFi guards are deliberately preserved: each one exists because Bluetooth drops for a legitimate reason and naive reconnection fights whatever is already in flight.

Everything above it is new. The cloud transcription path is **gone** — no `PlaudAPIService`, no S3 multipart upload, no polling, no API key — replaced by `Transcription/LocalTranscriber`. `State/AppModel` subscribes to the managers' Combine publishers and republishes them as `@Observable` properties, giving SwiftUI a clean seam without rewriting proven BLE logic.

See [docs/architecture.md](docs/architecture.md) for the full picture, [docs/development.md](docs/development.md) for conventions and gotchas, and [docs/api.md](docs/api.md) for the local HTTP API and the MCP server.

## License

Apache 2.0 — see [LICENSE](LICENSE).

The Plaud SDK binaries under `sdk/` are proprietary and distributed under a separate license.
