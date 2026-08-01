# Architecture

How Bounce is put together, and why.

## The shape of it

```
Plaud recorder
    │  BLE / WiFi
    ▼
┌─────────────────────────────────────────────┐
│ Device/          (ported from Plaud sample)  │
│   DeviceManager  ← the only SDK delegate     │
│     ├→ RecordingManager                      │
│     └→ SyncManager                           │
└──────────────────┬──────────────────────────┘
                   │  Combine publishers
                   ▼
┌─────────────────────────────────────────────┐
│ State/AppModel   @Observable bridge          │
└──────────────────┬──────────────────────────┘
                   ▼
        ┌──────────┴───────────┐
        ▼                      ▼
┌───────────────┐      ┌────────────────┐
│ Transcription/│      │ UI/  SwiftUI   │
│ LocalTranscri-│      │ Liquid Glass   │
│ ber (on-device│      └────────────────┘
│  SpeechAnalyz-│
│  er)          │
└───────┬───────┘
        ▼
┌───────────────────────────────────┐
│ Delivery/  webhook · folder ·     │
│            share sheet · Shortcuts│
└───────────────────────────────────┘
```

Storage (`Storage/RecordingStore`) sits underneath all of it as the single source of truth for recording metadata.

## What was kept, and what was replaced

Bounce started from Plaud's UIKit template app (preserved at `reference/plaud-template-app-uikit/`). The split was deliberate:

| Layer | Decision | Why |
|---|---|---|
| SDK integration (`Device/`) | **Kept, near-verbatim** | Encodes a lot of hard-won Bluetooth edge-case handling that is expensive to rediscover. |
| Models | Rewritten | Clearer names, `Equatable` for SwiftUI diffing, `Transcript` as a real type rather than a JSON string. |
| Cloud transcription | **Deleted** | Replaced by on-device transcription. `PlaudAPIService`, `TranscriptionManager`, the S3 multipart upload, the polling loop, and two API credentials all went with it. |
| Mock managers | Deleted | They existed for UI development but were never wired to anything — dead weight. |
| UI layer | Rewritten in SwiftUI | The original is UIKit targeting iOS 14, with a hand-drawn capsule tab bar faking glass via `UIVisualEffectView`. That predates Liquid Glass entirely. |

## Authentication

Plaud uses a two-tier token model:

| Token | Lifetime | Refresh |
|---|---|---|
| Partner token — from `client_id` + `secret_key` via Basic auth | 3600 s | Has a `refresh_token` |
| User token — minted from a partner token | `expires_in`, **hard-capped at 86 400 s (24 h)** | **None** |

The 24-hour ceiling is enforced by the API but absent from the docs, which state no maximum. Exceeding it fails the whole request rather than being silently clamped:

```json
{"detail":[{"type":"less_than_equal","loc":["body","expires_in"],
  "msg":"Input should be less than or equal to 86400","ctx":{"le":86400}}]}
```

`PlaudAuthService.maximumUserTokenLifetime` holds that constant, and `userToken(...)` clamps to it so no caller can trip the 422.

The absence of a user-token refresh is the whole design constraint. An app holding only a user token stops working within a day and cannot recover on its own; re-minting requires the partner credentials.

Bounce therefore holds `client_id` + `secret_key` on device and mints tokens itself:

```
CredentialsView  →  TokenProvider.save()          verify before persisting
                         │
                         ▼
                    KeychainStore                 ThisDeviceOnly, non-syncing
                         │
      ┌──────────────────┴───────────────────┐
      ▼                                      ▼
TokenProvider.validToken()            refreshIfNeeded()   on foreground
      │  cached token still good? return it
      │  otherwise:
      ▼
PlaudAuthService.mintUserToken()
      ├─ POST /oauth/partner/access-token        Basic base64(id:secret)
      └─ POST /open/partner/users/access-token   Bearer partner token
      │
      ▼
PlaudDeviceAgent.setUserAccessToken()   swaps the token live
```

Design notes:

- **No `refresh_token` flow.** We already hold the credentials, so re-minting a partner token is one Basic-auth call. Storing and rotating a refresh token for something that lives an hour would be more moving parts for no gain.
- **The server's `expires_in` is authoritative.** We request the 24-hour maximum and honour what comes back. `UserToken.isValid(margin:)` treats a token as spent 5 minutes early so a long transfer can't die on a token that lapsed mid-sync, and `refreshIfNeeded()` tops it up on foreground with an hour to spare. In practice Bounce re-mints roughly daily.
- **A day-long ceiling is why this design exists.** If tokens could be issued for a year, pasting one in would have been enough and the credentials could have stayed off the device entirely.
- **Concurrent callers share one mint.** `TokenProvider.validToken()` keeps the in-flight `Task`, so a burst of requests produces one network round trip.
- **Verify before persisting.** `save(_:)` mints a token first and only writes to the keychain if that succeeds, so a typo can't leave the app believing it is configured.
- **A stable `user_id`** is generated once (`bounce-<uuid>`) and kept in the keychain. The recorder's binding is tied to it, so regenerating it would orphan the paired device.

### Threat model

The credentials are **account-level**: they mint tokens for any `user_id` in the application, so a compromised device exposes the whole Plaud partner account rather than one user's device binding. That is exactly what Plaud's two-tier split exists to avoid, and accepting it is a deliberate trade for having no backend.

What that trade is mitigated by:

| Control | Effect |
|---|---|
| Entered at runtime, never in a build file or `Info.plist` | Nothing to extract from the IPA; nothing to leak via git |
| `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` | Encrypted at rest, unreadable while locked, **excluded from backups** |
| `kSecAttrSynchronizable: false` | Never replicated to iCloud Keychain or other devices |
| `LAContext` gate on `revealCredentials()` | Face ID / passcode required to display the secret |
| Never passed to `print` | Cannot leak into device logs or a crash report |

What it is **not** proof against: a jailbroken or malware-compromised device, or an attacker with both your encrypted backup and its password. If Bounce is ever distributed to other people, token minting has to move behind an endpoint — `TokenProvider` is the single seam, so that is a conformance change rather than a rewrite.

The keychain items are readable whenever the device is unlocked, deliberately, so opportunistic token refresh works without prompting. The biometric gate protects *displaying* the secret, which is where a second factor actually helps.

### Threat model: the desktop view

Turning the desktop view on opens a port carrying transcripts of the user's
meetings to **every other device on the network** — and "the local network" is
just as often office wifi, guest wifi, or a café as it is a home LAN. This is a
larger concession than the optional Soniox engine, because Soniox is chosen per
recording and this is ambient once switched on. It is **off by default** and
stops on its own; see `docs/plans/desktop-web-view.md` for the full design.

| Control | Effect |
|---|---|
| Off by default; explicit toggle in Settings | Never running unless asked for |
| TLS 1.2+ with a self-signed certificate, on by default | Nothing on the network can read transcripts, audio, or the pairing code in passing |
| Certificate fingerprint shown in Settings | The one available check that the browser reached *this* phone |
| Stops on background, and after an idle timeout | Can't be left open and forgotten |
| Six-digit pairing code, exchanged for a session token | Reaching the port is not the same as reading the library; requires physically holding the phone |
| Five failed attempts stops the server | A six-digit code can't be walked through |
| `HttpOnly; SameSite=Strict` cookie | Page script can't read the token; a cross-site request can't carry it |
| `Host` header validation | Blocks DNS rebinding — see below |
| CSP on the served page | Transcript text rendered into the page can't become script |
| Tokens and pairing state in memory only | Nothing persists past the session |
| Connected-browsers list with per-client revoke | The user can see and cut off anything unexpected |

Two of these are worth spelling out.

**Host validation is not optional.** Without it, any website the user visits can
have its JavaScript fetch `http://<phone-ip>:8080` from inside the user's own
browser, carrying the session cookie, and read the whole library back out. A
token alone does not stop that, because the browser attaches it automatically.
Checking that the `Host` header names this phone does, because a page can make
the browser connect but cannot make it lie about which host it asked for.

**Traffic is encrypted by default, but not authenticated.** `Web/SelfSignedCertificate`
mints a self-signed certificate on the phone and `HTTPServer` serves TLS 1.2+
with it. That closes the realistic threat — anything on the network passively
reading transcripts, audio, and the pairing code off the wire.

It does **not** prove the browser reached your iPhone. An attacker who can
redirect traffic can present their own certificate, and the browser shows the
same warning the user has already been trained to click past. The only
authentication available is by hand: Settings shows the certificate's SHA-256
fingerprint to compare against what the browser reports, because browsers expose
no API for a page to check its own certificate.

The cost is a browser interstitial the first time each browser connects, which
is why there is a toggle — but cleartext is the worse default, so it is on.

### Threat model: the API token

The desktop view's cookie is a **session** cookie on purpose — the state it
authenticates lives in memory and dies with the app. An agent can't work that
way, so Phase 5 adds a **long-lived bearer token**, and that is a materially
larger exposure than anything above. It is worth stating plainly:

**The token grants read access to every transcript on the phone, and it does not
expire.** A session cookie is bounded by the app's lifetime; this is bounded only
by the user revoking it. It is also, unlike everything else in the desktop view,
designed to be **copied off the phone** and pasted into a config file on another
machine — so it will end up on disk somewhere Bounce does not control, quite
possibly in a dotfile in someone's home directory or a shell history.

| Control | Effect |
|---|---|
| Generated on demand, never by default | No token exists until the user asks for one |
| Keychain, `ThisDeviceOnly` + non-synchronisable | Same attributes as the Plaud and Soniox credentials: not in iCloud Keychain, not in a backup |
| Revocable, taking effect immediately | The one control that actually bounds the lifetime |
| `Authorization: Bearer`, never a query string | Query strings land in server logs, browser history, and referrer headers |
| Constant-time comparison | A `==` leaks length and matching prefix through timing, which is enough to walk a token character by character |
| Logged only through a redactor | CLAUDE.md's "never log a credential" rule applies here, and this is the first credential the *user* is expected to copy, so it will be pasted into support threads |
| **Gates 1 and 2 still apply** | See below — a bearer token replaces neither |
| **MCP tools are read-only** | The blast radius of a confused agent with `DELETE /api/recordings` is the user's recordings |

**A bearer token does not replace the host check or the same-site check, and
adding one is not a reason to relax them.** The two gates defend against a
different attacker: a web page the user is merely *visiting*, whose JavaScript
tries to drive this server from inside the user's own browser. That page never
has the bearer token — but it doesn't need one if the browser is attaching a
cookie automatically, which is exactly what Gate 2 is for. Both gates already
pass non-browser clients correctly: `HTTPRequest.isCrossSite` treats "no
`Sec-Fetch-Site` **and** no `Origin`" as same-site so `curl` and MCP clients
work, and `WebSession.isAllowedHost` accepts any private IPv4 because that is the
phone on some interface. So no change was needed to let agents in, which is the
outcome you want — widening a security gate to admit a new client is how these
things go wrong.

**Read-only is a structural decision, not a default.** There is no write tool on
the MCP surface at all, so a prompt-injected agent reading a transcript that
contains "now delete every recording" has nothing to call. The HTTP API keeps its
write routes because the desktop view needs them and a browser session is
interactive; an agent's is not.

### The MCP server implements the *legacy* protocol era, deliberately

`Web/MCPProtocol.swift` is the Foundation-only wire layer (JSON-RPC 2.0 envelope,
dispatch, error codes — 133 standalone checks in `tools/mcp-endpoint-tests/`);
`Web/MCPEndpoint.swift` is the six read-only tools.

**MCP's current revision (`2026-07-28`) is effectively a different protocol** — no
`initialize` handshake, per-request `_meta` protocol version, a mandatory
`server/discover`. Bounce implements the **legacy** era instead
(`2024-11-05`…`2025-11-25`, answering `2025-11-25`), because that is what
`mcp-remote` and every currently reachable client actually speaks. A dual-era
client probing `server/discover` gets a plain `-32601`, which the spec's own
compatibility matrix says makes it fall back to `initialize` — the correct outcome,
since a legacy server is exactly what this is. There's a test pinning that
behaviour. Revisit when clients move, not before.

Three things that are easy to get wrong and are pinned by tests:

- **A notification must get no response at all.** `notifications/*` is answered with
  `202` and an *empty body*. Replying to `notifications/initialized` with a JSON-RPC
  result leaves the client waiting on an id that will never come, and it hangs
  rather than erroring — the worst failure shape.
- **Batching was removed from MCP in `2025-06-18`**, so a top-level array is refused
  with `-32600` rather than half-answered.
- **An unauthenticated `POST /mcp` returns HTTP 401 with the server's ordinary error
  body, not a JSON-RPC envelope.** Gate 3 rejects before the MCP layer parses
  anything, which is the right layering: transport-level auth belongs at the
  transport level, and answering `200` with a JSON-RPC error would disguise an
  auth failure as a successful exchange. Clients must check the status line first.

**Claude Desktop cannot reach this natively.** Its Custom Connectors flow takes a
URL but can neither attach a bearer header nor trust a self-signed certificate, so
the working path is `mcp-remote` spawned via `npx`. The config block is in
`docs/api.md`; the non-obvious part is that the `Bearer ` prefix must live *inside*
the env var, because `mcp-remote` mis-splits a `--header` value containing a space.

Three implementation facts worth knowing:

- **iOS cannot create a certificate.** `SecKeyCreateRandomKey` makes a keypair
  and `SecKeyCreateSignature` signs bytes, but nothing in Security.framework
  assembles X.509 — so `SelfSignedCertificate` writes the DER by hand. Bundling
  a certificate instead would ship its private key inside the IPA.
- **`SecIdentityCreate` is private API.** The key and certificate are stored in
  the keychain and iOS pairs them into a `SecIdentity` on lookup. That is why
  both are persisted rather than held in memory.
- **The certificate is minted against the same host set the `Host` check
  accepts**, and regenerated when that set changes. A browser validates the URL's
  host against the SAN, not the Common Name, so a new DHCP lease needs a new
  certificate — and an IP has to be encoded as an `iPAddress` general name, not
  a `dNSName`.

## Device layer

### One delegate, fanned out

`PlaudDeviceAgent` exposes exactly **one** delegate slot. `DeviceManager` claims it in `private init` and therefore receives every callback, including ones that conceptually belong elsewhere. It forwards them:

- `bleRecordStart` / `Stop` / `Pause` / `Resume`, `blePcmData` → `RecordingManager`
- `bleFileList`, `bleDownloadFile`, `bleWiFiOpen` / `Close` → `SyncManager`

To handle a new SDK callback, implement it in the `PlaudDeviceAgentProtocol` extension at the bottom of `DeviceManager.swift` and forward it. Do not try to register a second delegate — the SDK will simply drop the first.

`PlaudWiFiAgent` has its own separate delegate slot, which `SyncManager` claims directly.

### Discovering devices the SDK can't see

`BleAgent.startScan()` scans filtered on service `0x1910`, and iOS only reports peripherals whose advertisement contains that UUID. NotePro **"Find My"** units advertise `0x504C` (ASCII `"PL"`) instead. The result is that `bleScanResult` never fires for them — no error, no empty callback, nothing — and the device is undiscoverable through the SDK.

The advertisement itself is complete, though. Its manufacturer data carries everything needed:

```
mfg = 5D000271030456000701088810B50304423165441400040100
                              ^^^^^^^^^^^^^^^^ serial
BleDevice parse → sn=8810B50304423165  projectCode=881  versionCode=67328
```

`BleDevice(peripheral:rssi:manufacturerData:localName:)` is public, and its parser handles this correctly. So `BluetoothMonitor.startFallbackScan` scans unfiltered on a second `CBCentralManager` (iOS allows several per app), rebuilds `BleDevice`s itself, and `DeviceManager.handleFallbackDiscovery` merges them into the same `cachedBleDevices` and `scannedDevicesSubject` the SDK's results feed. `connectBleDevice` accepts them like any other device, so binding, handshake, sync, and everything downstream are untouched.

One further catch: **a `CBPeripheral` belongs to the central that discovered it.** Handing the SDK a peripheral from our central fails with

```
connectPeripheral failed: peripheral CF236E71-… not found
PlaudDeviceAgent bleConnectState state 2
```

even though the serial parsed, `sn-sign` succeeded, and the SDK reported `type=notepro, protVersion=20`. `BleAgent.cbManager` is public, so `rebindToSDKCentral` re-resolves the same identifier through the SDK's own central with `retrievePeripherals(withIdentifiers:)` — which works for any peripheral iOS knows about, regardless of which central scanned it — and the final `BleDevice` is built from *that* object.

Design notes:

- **Identification is by parsed serial**, via `PlaudModel.isSupportedSerial` — not by local name or service UUID. `BleDevice` will parse any manufacturer data, so the serial is the only trustworthy signal, and it also future-proofs against another service UUID appearing.
- **`allowDuplicates: true`, and dedupe only after a successful rebind.** The rebind can fail while the SDK's central is still coming up; with duplicates off, CoreBluetooth reports each peripheral once and a transient failure would blacklist the device for the whole scan.
- **`bleScanResult` merges rather than replaces.** It used to rebuild `cachedBleDevices` from scratch, which would silently drop fallback-discovered devices the moment the SDK reported anything.
- **The fallback mirrors auto-reconnect**, since the SDK's path never runs for these devices.
- Duplicates are suppressed per serial, so a device advertising ten times a second yields one callback.

This is a workaround for an SDK gap, not a design preference. Delete it if Plaud ships a scan that covers `504C`.

### Concurrency posture

The device layer deliberately uses `DispatchQueue.main.async` rather than actor isolation. This is not an oversight:

- SDK callbacks arrive on internal queues with no isolation guarantees.
- The reconnect / OTA / WiFi interactions are timing-sensitive and were validated against real hardware in this exact form.
- `DeviceManager` is marked `@unchecked Sendable` with a comment explaining the confinement, so the SDK's `@Sendable` completion closures can capture `self` without lying to the compiler.

`RecordingManager.latestLevel` is the one genuinely cross-queue value — written on the BLE callback queue, read by a main-queue timer — and it is guarded by an `NSLock`.

### The guards that matter

Several flags coordinate mutually exclusive Bluetooth activities. Getting these wrong produces reconnect storms:

| Guard | Protects against |
|---|---|
| `DeviceManager.isOTAInProgress` | The recorder reboots mid-update; the SDK handles reconnection, so a disconnect must be ignored. |
| `PlaudDeviceAgent.isWiFiTransferActive` | BLE intentionally drops during WiFi Fast Transfer; reconnecting would tear down the WiFi link. |
| `DeviceManager.suppressAutoReconnect` | During pairing, a scan would otherwise silently re-grab the previously paired device. |
| `SyncManager.expectingWiFiCallbacks` / `isWiFiConnecting` | Stale `bleWiFiOpen` callbacks re-entering the WiFi flow; also causes BLE export errors to be swallowed once WiFi has taken over. |

Auto-reconnect is a 30-second repeating timer capped at 10 attempts. The actual connect happens inside `bleScanResult` and **only fires when state is `.scanning`** — so anything that starts a scan must publish `.scanning` first.

### Reading the recorder's storage

The recorder reports storage through the `bleStorage(total:free:duration:)` callback, in response to `getStorage()`. Bounce derives `used = total - free` and shows it on the Recorder card.

Three things about it are easy to get wrong:

- **It must be re-read after anything that changes it.** `DeviceManager.refreshDeviceInfo()` runs only on bind and on pairing, so a figure sourced from it alone is a per-connection snapshot that can only rise during a session. `DeviceManager.refreshStorage(settling:)` is the mid-session re-read — narrower than `refreshDeviceInfo` (no `getState()`) and coalesced within one second, since each call is a real write to the shared BLE command channel. Trigger points: a confirmed device-side delete (`SyncManager.handleDeleteResult`), a drained sync queue (`SyncManager.downloadNext`), a stopped recording (`RecordingManager.handleRecordStop`), and `clearAllFiles` — which has no confirming callback of its own, so this figure is the only evidence it did anything.
- **A freed byte may not be freed yet.** The recorder acknowledges a delete before its free-space accounting reflects it, so `settling: true` schedules a second reading ten seconds later. Passed from the delete and erase paths.
- **It measures the whole device, not Bounce's recordings.** A recorder whose file list is empty still reports tens of megabytes used. Measured on a NotePro (V1.7.0): a recording costs one 64 KiB block whatever its size, and a confirmed delete removed it from the file list without freeing that block within a second. `HomeView.storageText` therefore states the pending-sync count alongside the bytes, so the number can't be read as "recordings Bounce failed to delete." Device-side delete itself is confirmed working; see the corresponding section in `CLAUDE.md` for the wire-level detail and the measurements.

## Transcription

`Transcription/LocalTranscriber` is an `actor` wrapping Apple's Speech framework:

1. Resolve the requested language via `SpeechTranscriber.supportedLocale(equivalentTo:)`.
2. Build a `SpeechTranscriber` with the `.timeIndexedTranscriptionWithAlternatives` preset — the time-indexed part is what yields a `CMTimeRange` per phrase, which is what makes tap-a-line-to-seek possible.
3. **Reserve** the locale with `AssetInventory.reserve(locale:)`, then install the model with `assetInstallationRequest(supporting:)` only if it isn't present. These are separate concerns and conflating them is a trap: a reservation is what permits a module to *be used*, installation merely puts the model on disk. Reserving only when a download was needed produced `Cannot use modules with unallocated locales [en_US]. Currently allocated locales are []`, and the analyzer then yielded no results and never terminated. Always reserve. Models persist across launches and are shared between apps, so the install step is normally a no-op after the first run.
4. Negotiate a format with `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:considering:)`, then stream the file in as `AnalyzerInput` buffers over an `AsyncStream`, resampling each chunk through `BufferConverter`.
5. Consume `transcriber.results` concurrently with the feed, then `finalizeAndFinishThroughEndOfInput()`.

### Use `analyzeSequence` + `finalizeAndFinish(through:)`, never `start` + `finalizeAndFinishThroughEndOfInput`

This is the single most important thing on this page, and getting it wrong cost several rounds of misdiagnosis.

`analyzeSequence(_:)` drives analysis on the calling task and **returns the last sample time**, which is precisely the argument `finalizeAndFinish(through:)` wants. That pairing is Apple's documented pattern:

```swift
let lastSampleTime = try await analyzer.analyzeSequence(stream)
if let lastSampleTime {
    try await analyzer.finalizeAndFinish(through: lastSampleTime)
}
```

`start(inputSequence:)` instead spins up the analyzer's **own autonomous input-loop worker**. Finalising from our task then races that worker, which reports itself as:

```
Failed precondition: Attempt to modify worker after it was locked
SpeechAnalyzer: Input loop ending with error: _GenericObjCError.nilError
```

Those two lines are what a mismatched drive/finalise pair looks like. They were variously mistaken here for an audio-format problem and for a cancellation problem, and neither reading was right.

### Reading the file

The audio is decoded and fed as buffers rather than handing the file to `analyzeSequence(from:)`, because the analyzer performs **no audio conversion** and the recorder's MP3s need resampling into whatever `bestAvailableAudioFormat` reports.

Two things about the read loop:

- **It is bounded by `audioFile.length`.** `read(into:)` *throws* at end-of-file rather than returning zero frames, so an unbounded `while true` reads one chunk too many and fails with `_GenericObjCError.nilError` — which looks exactly like file corruption and isn't.
- **A tail read failure is salvaged, not thrown.** MP3 frame counts are estimates, so `length` can overshoot the real end. If audio has already decoded, the feeder stops and keeps what it has rather than discarding a whole transcript over the final few milliseconds.

Also: a `SpeechTranscriber` **cannot be reused across two `SpeechAnalyzer` instances**. An earlier "try file mode, fall back to streaming" design tripped the worker-locked precondition for exactly that reason. One analyzer, one module, one attempt. `BufferConverter` holds one `AVAudioConverter` for the whole file, because the resampler carries state between calls and rebuilding it per chunk clicks at every boundary. Its `primeMethod` is `.none` — priming inserts leading silence, which would shift every timestamp in the transcript against the source audio.

### Three roles, three tasks

`transcriber.results` does not terminate until analysis is finalised, and `analyzeSequence` does not return until the input stream ends. So the work splits three ways:

| Task | Role |
|---|---|
| `collector` (detached) | Consumes `transcriber.results` |
| `feeder` (detached) | Decodes, converts, yields, then `continuation.finish()` |
| calling task | `analyzeSequence(stream)` → await feeder → `finalizeAndFinish(through:)` → await collector |

Both helpers are **detached** so neither inherits cancellation from the caller. That matters: cancellation from outside has torn down analysis mid-flight more than once here.

Two related traps already hit:

- **A `withThrowingTaskGroup` watchdog made things worse.** Racing the work against a timeout meant `cancelAll()` killed the analysis, and every transcription failed instantly with `CancellationError`. There is no timeout wrapper.
- **The analyzer ends the results stream by cancelling it.** A `CancellationError` out of the results loop is a normal stop, so the collector catches it and returns what it gathered rather than discarding the transcript.

`LocalTranscriber` is also deliberately **not an actor**: as one, the collector `Task` inherited its isolation and reentered it while `transcribe` still held it. There is no shared mutable state to protect, so isolation bought nothing.

`TranscriptionCoordinator` sits above it as a `@MainActor @Observable` queue: FIFO, one file at a time, with a per-recording status so several library rows can show independent progress. It also chains into delivery when auto-send is on.

### Why the audio format matters

Everything is exported as **MP3**, in both the BLE and WiFi paths. Two hard constraints drive that:

- `AVAudioPlayer` must be able to play it (for the detail-view player).
- `AVAudioFile` must be able to *read* it (for transcription).

The SDK also offers Opus, which is meaningfully smaller — but it lands in an Ogg container that `AVAudioFile` cannot open, which would break transcription outright. So Opus is deliberately unused despite being available. This is a change from the reference template, which used Opus on the WiFi path.

Concretely the recorder produces **MPEG-2 (LSF) Layer III, 16 kHz mono**, LAME-encoded with an `Info`/`Xing` metadata frame at the head. 16 kHz exists only in the MPEG-2 sampling-rate table, so frames are 576 samples (36 ms), not the 1152 that most MP3 references quote.

## Stored-model compatibility

`library.json` is one top-level JSON array decoded in a **single** `RecordingStore.load` call. So a field that can't decode doesn't degrade one recording — it loses the whole library.

**Every stored field must be `Optional`. A default value does not work.** A default is used by the memberwise initialiser only; synthesised `init(from:)` still calls `decode(_:forKey:)` for a non-optional property and throws `keyNotFound`. This shipped as a real bug: `Recording.deliveredTo` was `var deliveredTo: [String] = []` and was therefore undecodable from any library predating it. It's now an optional `deliveredToRaw` behind a non-optional computed accessor, with `CodingKeys` preserving the original `"deliveredTo"` key so existing data survives.

Two consequences:

- **`Recording` has an explicit `CodingKeys` enum now**, and every new stored property must be added to it or it silently stops persisting. That's a worse failure than the one it fixed — invisible until data is lost — so it's the first thing to check when a field mysteriously doesn't save.
- **`tools/library-decode-tests/main.swift` is the gate.** It decodes fixtures from every era of the format, including one predating every optional field, and asserts a mixed-era library decodes in one pass. `Recording.swift` is Foundation-only, so it compiles standalone and the test exercises the *real* model rather than a stub that drifts. Run it after touching any stored model.

## Action items

`Transcription/ActionItems.swift` holds the `@Generable` extractor; `ActionItemMerge.swift` holds `ActionItem` itself plus the merge, deliberately split so the model type is compilable without `FoundationModels` (otherwise `Recording.swift` stops building standalone and the decode tests can't reach it).

Extraction runs **inside `AutoOrganizer.process`, after the template loop** — so the documented ordering (transcript → auto-organize → deliver) holds and delivered payloads carry the items, with every model job serialised behind the transcription queue. Not a detached task.

**The merge is the load-bearing part.** Re-running extraction folds results in on a normalised text key, preserving `isDone`, `id` and `createdAt`, so an item the user ticked off is never resurrected and an item they added by hand is never deleted by a pass that didn't produce it. Covered by `tools/action-items-tests/`.

`Recording.actionItems` normalises to nil when empty, so "no items" has one representation. `AppModel` exposes `allActionItems` / `openActionItems` as computed pairs of `(recording, item)` — the items live on their recordings and a second aggregated copy would be one more thing to keep in step.

## Calendar matching

`Transcription/CalendarMatching.swift` is pure (a `CandidateEvent` value type and the overlap scoring, tested in `tools/calendar-match-tests/`); `CalendarMatcher.swift` is the EventKit layer. The split exists so the matching rules — greatest overlap, ties to the shorter event, all-day excluded, ±5 min tolerance for recorder-vs-phone clock skew, contains-start precedence — are testable without a calendar.

- **Reading events needs `NSCalendarsFullAccessUsageDescription` and `requestFullAccessToEvents()`.** iOS 17 split calendar authorization; write-only is refused for reads.
- **`CalendarMatcher` never writes, and never retains an `EKEvent`** — title and attendee display names are extracted and the object dropped. Bounce *can* now write calendar events, but through a separate type (`TaskCalendarWriter`, below); keeping the read path incapable of writing is why they aren't one class.
- **Attendee names are personal data.** They live in `library.json`, are never logged, and must not join the webhook payload without a settings toggle, since that payload's shape is a contract for whatever the user wired downstream.
- `AutoOrganizer` runs the match *before* classification and uses the event title only when the recording is still untitled. When a calendar title is taken, the AI title is skipped but the category is still assigned — `applyCalendarMatch` returns whether it retitled, precisely so those two decisions stay separate.

## The watch app is a remote for the phone

`Shared/WatchLink.swift` (compiled into **both** targets), `Bounce/Watch/WatchBridge.swift` (iOS), `BounceWatch/` (watchOS).

The watch has no Bluetooth relationship with the recorder and never will: a Plaud binds to one app, and the SDK ships an arm64 **iOS** slice only, so watchOS cannot link it. Every command is therefore a request for the phone to issue the BLE write — the watch is a transport control, and the phone stays the single source of truth.

What makes it more than a toy is that `WCSession.sendMessage` **wakes the iOS app in the background** when it isn't running. Combined with the `bluetooth-central` background mode Bounce already declares, a wrist tap starts a recording with the phone in a pocket and the app off screen.

- **Two transports, each for what it is for.** `sendMessage` is the watch asking for something now, needs the counterpart reachable, and carries a reply. `updateApplicationContext` is the phone volunteering state: queued by the system, delivered when the watch is next available, and **only the newest one kept** — which is exactly right, because a `Snapshot` is a complete picture and a stale one is worth nothing.
- **One `Snapshot`, not a message per property.** The watch is usually asleep and will miss individual updates; what it needs on waking is the whole current state, not a diff it can't reconstruct. `WatchBridge.publish()` drops an unchanged payload, because `AppModel` republishes several times a second during a sync and `updateApplicationContext` throttles.
- **Commands return the state *before* the recorder has answered.** Each is a BLE write confirmed on a callback later, so waiting would sit on `sendMessage`'s reply until it timed out. The watch shows the optimistic state and the truth arrives moments later via `publish()`.
- **A command with no connected recorder sets `lastMessage` rather than failing silently.** A wrist tap that appears to do nothing is indistinguishable from a broken app. The watch also distinguishes "can't reach the phone" from "phone is there, recorder isn't" — different problems, different fixes.
- **The snapshot carries no transcript, title or location.** The watch is a transport control; shipping content to a second device would widen the app's data footprint for no feature anyone asked for.
- **`WatchLink.Command` is a closed set of five, none of them destructive.** Nothing on the wrist can delete, deliver or edit a recording.
- **`Color.bounceWatch` restates `Brand.blueDark`** because `Theme.swift` builds its colours from `UIColor`, which doesn't exist on watchOS. Nothing enforces that they stay in step — the same standing warning the app icon carries.

**Build consequences are real and are why the embed is off by default** — see `docs/development.md#the-watch-app` and the `[WATCH APP] 1 of 1` block in `app/project.yml`. Short version: embedding makes the project multi-platform, `-target ... -sdk iphoneos` forces the iOS SDK onto the watch target, and a scheme build additionally needs the watchOS *runtime* installed, not just the SDK.

## Meeting series: a rolling digest, because N transcripts don't fit

`Device/Models/MeetingSeries.swift`, `Transcription/MeetingSeriesStore.swift`, `Transcription/SeriesContinuity.swift`, `UI/Library/SeriesView.swift`, `UI/Detail/SeriesCard.swift`.

The obvious implementation — hand the model every transcript in the series — is impossible. The on-device model's context window is ~4,096 tokens **shared** across instructions, question and answer, which is under one long transcript, never mind eleven. What fits is a *rolling* summary: after each session, rewrite a compact "where things stand" note from the previous note plus this transcript. It stays a fixed size however long the series runs.

One model call produces both halves — `SeriesUpdate.recap` (what the user reads on the recording) and `.carryForward` (what the *next* session reads) — because they are two views of the same reasoning and generating them separately let them disagree.

The limitation this design accepts, stated so nobody is surprised by it: **the model never sees an older transcript again, only its own notes about it.** Detail not carried forward is gone from this pass. The transcripts are all still there, and Ask still works over any one of them.

Load-bearing details:

- **`digestThroughRecordingId` is the idempotency guard.** `TranscriptionCoordinator` re-runs the whole organize pass on a re-transcribe; without it the same session gets folded into the notes twice, which reads as the meeting having happened twice.
- **`digestThroughDate` is the out-of-order guard.** A Plaud syncs whenever it next connects, so an older session can land after a newer one. It is still folded into the notes — dropping it would lose it permanently — but gets **no recap**, because "since last time" is a claim about sequence and would be false.
- **Grouping keys on `EKEvent.calendarItemExternalIdentifier`, not the event title.** Every occurrence of a recurring event shares it, so sessions months apart group with nothing asked of the user, and renaming the meeting in Calendar doesn't fork the series halfway through. `CandidateEvent.seriesKey` is nil for a non-recurring event on purpose — a one-off is not a series.
- **`AutoOrganizer` never reassigns.** A recording the user filed by hand keeps its series even when the calendar disagrees.
- **`Recording.seriesId` stores an id, not a name** — the `tagIds` choice, not the `categoryName` one — so renaming a series keeps every session attached. `MeetingSeriesStore.remove` sweeps it out of every recording, the same requirement `CategoryStore.sweepTag` documents.
- **`seriesRecap` is cleared whenever a recording changes series or leaves one.** It describes one series' history; leaving it would attribute one meeting's context to another.
- **`rebuild(seriesId:progress:)` is serial and never automatic.** It is N model calls, so it is offered as "Read all sessions" and runs only when asked — the same reasoning as `AutoOrganizer.scanForActionItems`. It clears the digest first so a cancelled run leaves incomplete notes rather than notes mixing two runs.
- **No settings toggle.** The pass no-ops unless a recording is in a series, and a series only exists because the user made one or has a recurring meeting with calendar matching on. It gates itself.

`SeriesListView` is the Library's fourth view mode and is **deliberately unfiltered** — the other three index recordings and the filters narrow which; this indexes series, and hiding one because none of its sessions match the current search would read as the series having been deleted.

## Where a recording happened

`Location/LocationCapture.swift` (CoreLocation), `Location/PlaceStore.swift` (the parking lot and the single write gate), `Device/Models/RecordingPlace.swift` (the stored value), `UI/Detail/PlaceCard.swift` (show and edit), `UI/Library/RecordingMap.swift` (the Library's third mode).

The problem this feature has to solve is not "get a coordinate". It's that **a Plaud records standalone**, so the phone is often nowhere near the recording when the file arrives. Four sources answer "where was this", with very different confidence, and `RecordingPlace.Source` is what keeps them from being confused for each other:

| Source | When | Confidence |
|---|---|---|
| `.recordStart` | `RecordingManager.handleRecordStart` — the recorder told the phone it started, so the phone was in BLE range at that instant | Real |
| `.calendar` | The matched event's `structuredLocation.geoLocation`, applied by `AutoOrganizer` | Real, and often more precise than GPS |
| `.sync` | A fix taken as the file transferred | **Approximate**, and labelled so everywhere |
| `.manual` | The user set it | Authoritative |

Things that are load-bearing:

- **`PlaceStore.write` is the only writer, and it enforces `Source.precedence`.** Four sources can each fire late — a slow GPS fix, the auto-organize pass, a re-sync — and without one gate the last writer wins, which means a sync-time approximation silently replaces a real fix. Same-source writes are refused too, so a repeated pass can't churn the row. The one deliberate bypass is `AppModel.setPlace`, because the user is allowed to move or clear their own pin.
- **A `.sync` fix is refused for anything older than `PlaceStore.syncFallbackWindow` (30 min).** Record in the car, sync at the office, and a sync-time pin is simply a different place. No location is a better answer than a confident wrong one — the recording just doesn't appear on the map.
- **The fix is parked by `sessionId`, not written directly** — the `HighlightStore` / `LiveTranscriptStore` pattern, for the same reason: a recording starts long before a `Recording` row exists. `AppModel`'s `didSyncPublisher` sink applies it beside the highlights. `PlaceStore.attachOrPark` covers the race where a short recording syncs before the fix returns.
- **`RecordingPlace.source` is stored as a `String`, not the enum.** An unrecognised raw value throws out of a synthesised `Decodable`, and `library.json` decodes as one array — so a source case added by a later build would make the whole library undecodable on an older one. Unknown degrades to `.sync`, the weakest claim. Covered in `tools/library-decode-tests/`, along with the precedence rules and the 0,0 / out-of-range rejection.
- **`CandidateEvent` gained `locationName` / `latitude` / `longitude`, not a `CLLocation`.** That file is deliberately EventKit- *and* CoreLocation-free so `tools/calendar-match-tests/` compiles it on the Mac. A calendar location with a name but no coordinates is dropped rather than stored: `RecordingPlace` exists to put a pin on a map, and "Room 4B" cannot.
- **`NSLocationWhenInUseUsageDescription` moved out of the `[WIFI FAST TRANSFER]` block in `project.yml`.** It used to live inside block 3 of 3, which means commenting that block out for a free Personal Team would have removed the key while `LocationCapture.requestAccess()` still called `requestWhenInUseAuthorization()` — and iOS **terminates the app** for that. It's a plist key, not a signable entitlement, so it belongs outside. Its old copy also promised "Bounce never stores or transmits your location", which geotagging made untrue.
- **One-shot fixes only — no `location` background mode, no blue indicator.** The cost: with When In Use authorization a fix only arrives while the app is foreground or recently so, so `.recordStart` can miss when the phone is locked in a pocket. The calendar and sync fallbacks and manual editing cover that gap; adding background location to close it would trade an always-on location indicator and an App Store review conversation for a metadata nicety.
- **Coordinates are personal data**, same class as `calendarAttendees`: they stay in `library.json`, are never logged, and must not join the webhook payload without their own settings toggle.

`MKReverseGeocodingRequest` (iOS 26) resolves the pin's name, and failures are swallowed on purpose — the geocoder is rate-limited and offline-hostile, and `RecordingPlace.displayName` falls back to the coordinates. The name is **stored** rather than resolved in a view body, or the map would throttle itself into silence the first time it scrolled.

## Where tasks go

Three destinations, all off by default, all writing into something outside Bounce: Apple Reminders (`RemindersSync`), Apple Calendar (`TaskCalendarWriter`), and a per-task webhook (`TaskWebhook`). Each splits the same way — a pure, tested planning layer and a thin layer that applies the plan — because the reconciliation rules are where the bugs live, not the API calls.

Rules they share, and the reasoning:

- **Plan before acting, and treat a failed fetch as different from an empty one.** The planners take the current remote state as the complete truth; `[:]` from a fetch that errored would unlink every synced item at once.
- **Deleted remotely means unlink, never recreate.** Recreating fights a user who deleted something on purpose.
- **Idempotent.** These run on every foreground, so re-planning after applying must yield an empty plan.
- **Completion flows both ways for Reminders**, one way for the others. Ticking in Reminders and having Bounce not notice is the failure that would annoy daily; the rest resolve in Bounce's favour.

Destination-specific decisions worth knowing:

- **Calendar takes only dated tasks.** A calendar is for things that happen at a time; an undated task belongs in Reminders. This is the one feature that makes Bounce write to the user's calendar, which is why `NSCalendarsFullAccessUsageDescription` had to be rewritten — it previously promised nothing was ever written, and leaving that as a comfortable lie was not an option.
- **The webhook never carries the transcript.** A hook firing once per task would otherwise be a far better exfiltration path than the recording webhook beside it. There's a test asserting no transcript text reaches the serialised payload — a security check, not a formatting one.
- **Fire-once for the webhook is tracked by id in UserDefaults**, not on `ActionItem`, because that type lives in `library.json` and every field added to it is a decode-compat change. A failed POST isn't marked sent, so it retries: the failure mode is a late delivery, not a lost one.

## Deadlines are resolved, and the model is told what day it is

`ActionItem` carries both `dueText` (the phrase as spoken — "by Friday") and `dueDate` (resolved). Keeping both is deliberate: the phrase is better UI text, and it's the evidence when a resolution looks wrong.

An earlier version refused to resolve dates at all, on the grounds that "the on-device model has no reliable notion of today". **That reasoning was wrong** — the model doesn't need to know, because `DueDateResolver.instructions(recordedAt:calendar:)` tells it, anchoring on the recording's own date *and weekday* and giving worked examples. The model returns a strict ISO-8601 fragment, which `resolve` validates hard: unparseable, before the recording, or more than two years out all yield nil. A wrong date in someone's Reminders is worse than no date, so validation is what earns the feature.

The anchor is the **recording's** `createdAt`, not the transcript's — those differ whenever transcription runs days later, and using the wrong one shifts every deadline by that gap.

## Tags, and why not folders

`Recording.tagIds` stores **`RecordingCategory.id` values, not names.** This is the deliberate counterexample to `categoryName`, which stores a name and therefore silently detaches every recording when a category is renamed. Tags are additive and user-applied; category stays singular and AI-assigned, and the two are not merged.

`RecordingTags` (pure, tested in `tools/recording-tags-tests/`) owns the set operations. Filtering is **AND** — a recording must carry every selected tag — which is what makes tags serve the "subfolders" request better than folders would, since the complaint there is that one recording only fits in one folder.

`CategoryStore.remove(id:)` sweeps the deleted id out of every recording. Without it the library accumulates ids that resolve to nothing, render as nothing, and can't be cleared — while still failing an intersection filter for a tag that no longer exists.

## Speaker names are a name pool, not voice recognition

**Diarization is anonymous.** Labels like `"1"` are per recording, label "1" is not the same person twice, and neither engine has a voice-profile or enrollment API. Cross-recording voiceprints are not buildable, and **nothing in the UI may imply otherwise** — a user who believes names are matched by voice will trust a pre-filled name they should check.

What is built: `SpeakerDirectory` (a `DeliverySettings`-pattern UserDefaults singleton, read directly from views) remembers names the user has typed, ranked by recency then frequency. `SpeakerSuggestions.autoFill` offers the previous same-category recording's names, in order, **only** when the speaker counts match and every speaker there was named. Tested in `tools/speaker-directory-tests/`.

Two rules in the UI: suggestions are held as **unconfirmed** view state and never written to `Recording.speakerNames` until the user accepts them, and only names the user actually saved feed the directory — never a guess, or the pool would reinforce its own mistakes.

## Battery drain measurement

`Device/BatteryDrainEstimator.swift` is pure and tested (`tools/battery-drain-tests/`), and **is not surfaced in the UI yet, on purpose.**

Battery arrives change-driven via `blePowerChange(power:oldPower:)` — nothing polls it. The scale is confirmed integer percent (standard BLE Battery Service, uint8 0–100) but the firmware's **step granularity is unknown**, and it decides whether the feature is viable at all: at 1% steps a ~3 h session gives roughly ±10%, at 5% steps you need ~15 h and a per-session figure is worthless. A `#if DEBUG` log in `blePowerChange` records `step=` and `after=` so that can be measured on hardware before any UI commits to a number.

The estimator's rules are what make it honest: edge-to-edge timing between transitions rather than endpoint arithmetic (halving the window needed for a given accuracy), a minimum transition count before it reports anything, and spans *invalidated* — not averaged — by charging, disconnect, WiFi transfer, or a rising level. It also refuses to compare rates across different starting levels, because percent is not energy: the discharge curve is flat in the middle and steep at the ends, and fuel gauges re-estimate.

**Attributing drain to live transcription is not currently possible**, and the code says so: `DeviceManager.bleRecordStart` calls `startLivePCMStream` unconditionally, so the recorder streams over BLE whether live transcription is on or off. The setting only gates whether the *phone* consumes the bytes (`RecordingManager`), and the assembler's own read replaces the SDK's rather than adding a second. An A/B would first need that call gated on the setting — a deliberate behaviour change, not a tidy-up.

## Audio editing

`Audio/` holds the editor: trim, delete a range, remove silence, save the result as a new recording. Four pieces, and the split is deliberate — three of them are pure logic with no UI or actor involvement, which is what makes them verifiable outside the app.

| File | Role |
|---|---|
| `MP3Frames` | Frame-level index of an MP3, and a writer that emits a subset of its frames |
| `SilenceDetector` | Short-window RMS pass → coarse speech segments |
| `TimelineMap` | Set operations on kept ranges, and remapping timestamps onto a shortened timeline |
| `AudioEditModel` | `@MainActor @Observable` editor state; the only piece that touches the store |

### Editing copies frames — it never re-encodes

**iOS ships an MP3 decoder and no MP3 encoder.** Anything routed through `AVAssetExportSession` or `AVAudioFile(forWriting:)` comes out AAC, ALAC or LPCM, never MP3 — which would break the invariant above, plus `Web/WebAPI`'s hardcoded `audio/mpeg` and `SonioxBatchTranscriber`'s upload content type.

So `MP3Frames` cuts by copying whole frames. Layer III frames are self-delimiting (each header states its own length), so an edit is a byte-range copy: bit-identical audio, still MP3, no quality loss, and fast enough to be synchronous from the user's point of view. Two consequences to know:

- **Cuts quantise to one frame** — 36 ms on the recorder's output. `MP3Frames.write` returns the ranges it *actually* wrote, and callers must remap against those rather than against what they asked for, or each cut drifts by up to a frame and the transcript walks progressively out of step.
- **The bit reservoir means a frame boundary is not a decode boundary.** A frame may hold part of its main data in space left over by earlier frames, referenced backwards by up to 255 bytes (MPEG-2) or 511 (MPEG-1). The first retained frame after a cut can point at bytes that are gone. Every mainstream decoder, Apple's included, silences that granule and carries on — so the cost is up to ~72 ms of imperfect audio at each cut, after which the stream self-heals. This is what happens on every seek in every MP3 player, and it's why fast-cut tools universally accept it.

The encoder's `Info`/`Xing` frame is **excluded from the frame index**, because it carries no samples and would otherwise prepend a frame of silence and shift every timestamp. A fresh one is synthesized on output only for a variable-bitrate source; on CBR, `AVAudioPlayer` derives an exact duration from file size and bitrate, so writing one could only add risk.

### Saving is the app's first non-SDK recording-creation path

Everything else in the library comes from `SyncManager`. An edited copy doesn't, and three store invariants become load-bearing:

- **`audioFilename` must be non-nil before the `Recording` is ever persisted.** `SyncManager.handleFileList` rebuilds the library as `recordings.filter(\.isSynced) + placeholders`, and it runs on every BLE reconnect — not just on user-initiated sync. Any window in which the row exists with a nil filename is a window in which reconnecting destroys it, orphaning the MP3 (nothing prunes `Documents/Audio/`). So: write the file, *then* add the record.
- **`sessionId` must be negative.** Real ids are the recording's start time as a Unix timestamp, and `RecordingStore.markSynced` joins on it. A collision would let a device download overwrite the edited copy's `audioFilename`, orphan the edit, and leave the real recording never marked synced — so it would be wiped and re-listed forever. `AudioEditModel` allocates a negative id and verifies it's unused, because `RecordingStore.add` silently drops duplicates.
- **The filename must be unique.** `RecordingStore.delete(id:)` removes audio and the cached waveform envelope by bare filename, so two recordings sharing one would cross-delete.

The transcript is carried over, remapped by `TimelineMap`: a phrase survives if more than half its audio does, timings shift by the removed duration ahead of them, and monotonicity is preserved. Highlights get the same treatment. Summaries are dropped — they describe content that may be gone, and a stale summary is worse than none. The one accepted cost is that a copy with a transcript appears twice in `AskCorpus`'s grounding, which is correct if you keep both recordings and irrelevant once you delete the original.

### Verification

There is still no test target (the app can't build for the Mac — the Plaud frameworks are arm64-iOS only). `tools/audio-edit-tests/main.swift` compiles the three pure files as a standalone Swift program and exercises them against synthesized MPEG-2 Layer III fixtures, ending by decoding its own output through `AVAudioFile` so the result is verified to be a real MP3. Run it after touching any of them; the invocation is in the file header.

## Joining recordings

`Audio/RecordingMerge.swift` (orchestration), `Audio/RecordingMergePlan.swift` (the pure part), `MP3Frames.merge`, `Transcription/ContinuationStore.swift`, `UI/Library/MergeRecordingsSheet.swift`.

A session and a *file* are not the same thing. A Plaud closes its file every time recording stops, so half an hour of dictation captured in bursts arrives as thirty rows that can't be read, summarised or searched as the one train of thought they are. Two ways in:

- **After the fact** — "Join with…" in a recording's context menu, which opens a sheet to pick the other parts.
- **While recording** — "Continue a recording…" on the live screen, which links the session in progress to an existing recording and joins them automatically once it syncs.

Note that the recorder's own **pause** already produces one file with one `sessionId`, and Bounce drives it from the phone, the watch, the Lock Screen and the Live Activity. Joining is for the case where recording actually *stopped*.

### The audio is concatenated frame-by-frame, like every other edit

`MP3Frames.merge` is the same copy `write` does, run across several files. Layer III frames are self-delimiting and carry no file-level state, so an MP3 is a bare sequence of frames and appending one file's to another's produces a valid stream — nothing is decoded, nothing re-encoded, and the output is still MP3, which the whole app depends on. `write` and `merge` share `selectFrames`/`appendFrames` so an edit and a join can't drift into two different notions of "kept".

- **Version, sample rate and channel count must match across sources; bitrate need not.** A decoder handles a bitrate change mid-stream — that is all VBR is, and a mixed-bitrate result gets a synthesized Xing header — but a sample-rate or mono/stereo change would play the rest of the file at the wrong speed or drop a channel. Mismatches throw `Failure.formatMismatch` rather than being written. Every file from one Plaud is 16 kHz mono MPEG-2, so in practice this only fires on a hand-imported file. This mirrors what `MP3Frames.index` already enforces within a single file, and for the same reason.
- Expect the usual ~72 ms of imperfect audio at each join (bit reservoir), exactly as at any cut.

### Everything attached to the audio shifts by the part's placement

`RecordingMergePlan` is Foundation-only and does no I/O, so `tools/library-decode-tests` compiles it against the **real** `Recording`. It rewrites transcript segments, highlight marks, chapter starts and action-item offsets by `MP3Frames.Placement.start`.

- **Use the placements, never the sources' stored `duration`.** The writer snaps to frame boundaries, so a stored duration is up to a frame out, and accumulating that error across parts walks the tail of the transcript off its audio.
- **Diarization labels are renumbered into one sequence.** "1" in the second part is not the person "1" in the first — labels are per recording and no engine here has enrollment. Two rows for one human is a wrong guess the user fixes by naming them; one row for two humans is a wrong transcript. `speakerNames` follows the renumbering.
- **A hole marks the stitch `isPreview`.** A part with no transcript, or one still holding a live preview, makes the merged transcript incomplete — and `isPreview` is exactly what `TranscriptionCoordinator.enqueue` already treats as "not transcribed", so the merged file goes through a full pass with no second mechanism.
- **One chapter per seam**, titled with the part. `AutoOrganizer.generateChapters` skips any recording with `parts`, because it writes `nil` through on a device that can't chapter and would erase them permanently.
- Category and series carry over **only when the parts agree**; absent values abstain rather than dissent. Summaries and `seriesRecap` are dropped — they describe a fragment, or a position in a series' history that the merge no longer occupies.

### It always writes a new recording

Nothing is mutated in place, exactly as `AudioEditModel.save` never touches what it edits — so the same three invariants in [Saving is the app's first non-SDK recording-creation path](#saving-is-the-apps-first-non-sdk-recording-creation-path) apply verbatim. `RecordingStore.syntheticSessionId()` is now the one allocator for both paths. Sources are deleted afterwards only if the caller asks, and only once the new row is confirmed present — `RecordingStore.add` drops duplicates silently, so a dropped insert followed by a delete would destroy the only copy.

### The continuation link is an intent, redeemed later

Nothing can be joined at the moment the user says "continue that one": the audio is still on the recorder and no `Recording` row exists until `SyncManager` reconciles the device's file list. `ContinuationStore` therefore parks the link **by session id** — the `PlaceStore.attachOrPark` / `HighlightStore` shape — and `TranscriptionCoordinator` redeems it once a recording has its authoritative transcript.

- **Both directions are checked**, because the halves can finish in either order: a short continuation can sync and transcribe before the long session it continues.
- **`absorb` returning true means the row has been deleted**, so the coordinator must skip `AutoOrganizer` and auto-delivery for it. The merge runs both itself, over the combined recording — which is why `RecordingMerge.merge` takes `organize:` and `deliver:` rather than assuming. A hand-made merge organizes but does **not** deliver: the user is looking at it, and firing a webhook unprompted would be a surprise.
- **`repoint` moves links off a consumed recording onto its replacement**, which is what makes stop-start-stop across an afternoon collapse into one transcript rather than three pairs.
- A merge that fails leaves the link parked, so a transient unreadable file is retried at the next pass rather than silently abandoned. Links expire after 7 days.

## Delivery

`Delivery/DeliveryService` handles the unattended paths:

- **Webhook** — one `multipart/form-data` POST carrying `metadata` (JSON), `transcript` (text), `transcript_file`, and `audio`. That shape maps cleanly onto n8n, Zapier, Make, or a plain handler. An optional shared secret goes out as `X-Bounce-Secret`.
- **Folder** — copies audio and transcript into a user-chosen folder in Files or iCloud Drive, held as a **security-scoped bookmark** rather than a path (the folder is outside our sandbox).

The **share sheet** is intentionally *not* in this layer. SwiftUI's `ShareLink` does it natively, picks up Liquid Glass for free, and covers Mail, Messages, Slack, Notion, Obsidian, AirDrop, and Files with no per-service code.

**Shortcuts** (`Delivery/BounceIntents.swift`) is the real "anywhere" unlock. Rather than integrating with every service directly, Bounce exposes recordings and transcripts as App Intents and lets Shortcuts route them.

## Desktop view

`Web/` runs an HTTP server inside the app so a browser on the same network can
read the library, play recordings, and organize them. The phone is the server;
there is no cloud component and nothing leaves the LAN.

A native Mac app isn't an option, and it's worth knowing why before someone
proposes one: the Plaud frameworks ship an **arm64 iOS device slice only** — the
same fact that makes simulator builds impossible rules out Catalyst and a macOS
target. Syncing to a separate Mac app through iCloud would mean putting
transcripts in the cloud. A browser talking to the phone is the only desktop
story that leaves the data where it already is.

| File | Role |
|---|---|
| `HTTPServer.swift` | `NWListener`, request parsing, response writing, byte ranges, SSE framing |
| `WebSession.swift` | Pairing codes, session tokens, Host validation, attempt cap |
| `WebAPI.swift` | The route table. Every handler on the main actor |
| `WebTypes.swift` | The JSON shapes the client sees |
| `LiveChannel.swift` | Server-sent-events fan-out for live transcript and status |
| `DesktopServer.swift` | Lifecycle, addresses, idle timeout — `DesktopServer.shared` |
| `WebClient.swift` | Serves `index.html` out of the bundle |
| `../WebClient/index.html` | The entire client: one file, inline CSS and JS, no build step |

Four things here are load-bearing.

**It is a foreground session, not a service.** iOS suspends the app seconds after
it backgrounds and the socket dies with it. Neither declared background mode
helps: `audio` grants residency only while an `AVAudioSession` is actually
playing, and `bluetooth-central` wakes the app for BLE events rather than keeping
a listener alive. Playing silent audio to stay resident is the usual workaround
and is an App Store rejection. So the server keeps the screen awake while it runs
and stops on `scenePhase` leaving `.active`. The client is built for this — it
uses `EventSource`, which reconnects on its own.

**Every handler hops to the main actor, once, at the edge.** `RecordingStore` is
a plain class with an unsynchronised `[Recording]` cache and no lock; it works
today only because every existing caller is already on the main queue. A handler
touching it from the network queue compiles clean under
`SWIFT_STRICT_CONCURRENCY: minimal` and races at runtime. `WebAPI.handle` is the
single hop.

**Every write goes through `AppModel`, never `RecordingStore` directly.**
`AppModel.rename` writes *and then* calls `SyncManager.refreshLibrary()`, which is
what republishes the library to SwiftUI. Skipping that persists correctly and
leaves the phone showing stale data — and if the user then edits on the phone,
the phone writes its stale copy back over the browser's edit. `setCategory` and
`generateSummary` were added to `AppModel` for this reason rather than
implemented in the web layer.

**Formatting and grouping stay in Swift.** `WebTypes` sends preformatted
timecodes, because `TimeInterval.timecodeText` is meant to be the only such
formatter in the app, and pre-grouped blocks from
`Transcript.blocks(speakerNames:)`. Speaker labels are resolved server-side for
the same reason. The browser renders what it is given.

### Ask over the wire

`GET /api/ask?q=` and `GET /api/recordings/<id>/ask?q=` stream an answer from the
same on-device model the phone uses. Both are `GET` returning
`text/event-stream`, not `POST`, because the answer streams and `EventSource` is
the only thing in a browser that consumes a stream with no plumbing.

`Transcription/AskCorpus` holds the keyword matching and corpus assembly that
used to live inside `AskView`. It was extracted rather than reimplemented
because two clients matching independently would answer the same question
differently — the same class of quiet divergence the single timecode formatter
exists to prevent.

### The client is laid out as a published interview

`WebClient/index.html` treats a recording as a document to read, not a record to
administer. **Who spoke and when hang in the left margin; the words run as one
continuous column.** Speaker names above each paragraph — the obvious
arrangement, and the first thing tried — chop the reading column into blocks and
stop it reading as speech.

The margin is the typographic device: names in small, heavy, letterspaced caps,
timecode in mono beneath. Consecutive turns from one speaker are marked
`data-same` and run on as a continued paragraph, so the margin stays quiet.
Playback position is a single ochre bar in that margin, and ochre appears nowhere
else on the page — it means "where you are" or "you marked this", nothing more.
Red belongs only to the recorder being live.

Prose is `ui-serif` (New York on Apple platforms), every number is
`ui-monospace`, and the recording's title is set in the reading face rather than
the UI face because it is a headline, not a window label. All system faces: the
page must render with no network beyond the phone, so there are no webfonts to
fetch.

Two earlier directions were discarded and are worth not repeating. A palette of
cool greys read as a generic admin panel. Before that, the transcript sat below
four stacked metadata cards, which buried the only thing anyone opens the page
for.

Playback is a custom transport rather than `<audio controls>`, because the
waveform doubles as the scrubber and carries the highlight marks, which native
controls cannot show. That trade is paid back with hand-wired ARIA
(`role="slider"`, `aria-valuetext`) and keyboard handling.

The live channel is SSE rather than a WebSocket, and is polled at 4 Hz and
diffed rather than driven by an observation. `docs/plans/desktop-web-view.md`
records why, along with the other deviations from the original plan.

## State bridge

`State/AppModel` is a `@MainActor @Observable` class that subscribes to every manager publisher and republishes plain observable properties.

This exists so the device layer never had to be rewritten as `@Observable`. One clean seam, no risk to the proven logic underneath. It also owns the cross-cutting reactions:

- Connect → quietly fetch the recorder's file list.
- File synced → enqueue transcription (if enabled).
- Transcription done → deliver (if enabled) — handled inside `TranscriptionCoordinator`.

## Storage

`Storage/RecordingStore`: metadata as `library.json` in `Documents/`, pairing state in `UserDefaults`, audio in `Documents/Audio/`.

One invariant worth internalising: **`audioFilename` is a bare filename, never an absolute path.** The sandbox container path changes between installs and OS upgrades, so a stored absolute path goes stale and the audio silently disappears. Always resolve through `RecordingStore.audioURL(for:)`.

A second: device-side and phone-side files are **disjoint**. A recording is deleted from the recorder once downloaded, so anything still in `bleFileList` is by definition unsynced. `SyncManager.handleFileList` reconciles by merging locally-synced records with the current device list.

## UI

SwiftUI throughout, iOS 26, portrait only.

Liquid Glass is applied per Apple's guidance — glass belongs to the **navigation layer floating above content**, never to content itself, and never stacked on glass:

- `TabView` with `Tab(value:)` gets the glass tab bar automatically, plus `.tabBarMinimizeBehavior(.onScrollDown)` and a `.tabViewBottomAccessory` activity strip.
- Buttons use `.buttonStyle(.glass)` / `.glassProminent`.
- Custom surfaces — the player bar, the recording transport, library section headers — use `.adaptiveGlass(...)`, a wrapper that falls back to `.regularMaterial` when **Reduce Transparency** is on. `Glass.identity` would keep the layout but the material fallback reads better.
- Content sits in `ContentCard`, which is a plain `.background.secondary` surface, explicitly *not* glass.
- The recording transport lives in a `GlassEffectContainer` so its buttons share one sampling region and can morph.

`RootView.MainTab` is named that way rather than `Tab` specifically so it does not shadow SwiftUI's own `Tab` type inside the `TabView` builder.
