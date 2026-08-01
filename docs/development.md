# Development

## Setup

```bash
brew install xcodegen

cd app
xcodegen generate
open Bounce.xcodeproj
```

Nothing to configure. Bounce asks for your Plaud Client ID and Secret Key on first launch and stores them in the keychain — there is no xcconfig and no credential in any tracked file.

## Build

| | |
|---|---|
| From Xcode | Select a **physical iPhone** and run. |
| From the CLI | `cd app && xcodebuild -project Bounce.xcodeproj -target Bounce -sdk iphoneos -configuration Debug CODE_SIGNING_ALLOWED=NO build` |

Use `-target Bounce -sdk iphoneos` rather than `-scheme Bounce -destination ...` from the CLI. With no simulator runtime installed, scheme-based destination resolution fails with a misleading *"iOS 26.5 is not installed"* even though the SDK is present.

### The watch app

`BounceWatch` is a second, watchOS target. It builds on its own with no ceremony:

```bash
cd app && xcodebuild -project Bounce.xcodeproj -target BounceWatch -sdk watchos \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

**It is not embedded in the iOS app by default** — the `[WATCH APP] 1 of 1` block in `app/project.yml` is commented out, in the same style as the `[WIFI FAST TRANSFER]` blocks. Uncommenting it is what actually installs the watch app onto a paired Apple Watch, and it changes two things:

1. **`-target Bounce -sdk iphoneos` stops working.** `-sdk` is forced onto dependencies, so the watch sources compile against the iOS SDK and fail — `WCSessionDelegate` has different requirements per platform. Failing is the *good* outcome here; the bad one would be succeeding and embedding an iOS binary as a watch app. Build with the scheme instead:

   ```bash
   xcodebuild -project Bounce.xcodeproj -scheme Bounce \
     -destination "generic/platform=iOS" \
     -configuration Debug CODE_SIGNING_ALLOWED=NO build
   ```

2. **The watchOS *runtime* has to be installed, not just the SDK.** `xcodebuild -showsdks` listing `watchos26.5` is not enough — a scheme with an embedded watch app refuses to resolve with *"watchOS 26.5 must be installed in order to run the scheme"*. Fix with `xcodebuild -downloadPlatform watchOS` (~4 GB). Same misleading error class as the iOS one below.

**Simulator builds are impossible.** The Plaud frameworks ship an `arm64` device slice only, with no simulator slice, so any simulator build fails at link time. There is no workaround short of Plaud shipping an XCFramework.

### Tests

There is no test target. The interesting behaviour is Bluetooth state machines against real hardware, and the value of unit tests over `DispatchQueue`-based callback plumbing is low. Verification is manual, on-device.

If you add one, the seams worth testing are `RecordingStore` (pure persistence), `DeliveryService.Payload` (filename derivation, content selection), and `Transcript` formatting — all independent of the SDK.

## project.yml is the source of truth

`Bounce.xcodeproj` is generated and git-ignored. **Never hand-edit it** — regenerate instead. All target settings, Info.plist keys, and entitlements live in `app/project.yml`.

Two XcodeGen traps that have already bitten this project:

1. **There is no `resources:` target key.** Declaring one is silently ignored — no warning, no error, the files just never reach Copy Bundle Resources. Declare resources under `sources:` with an explicit `buildPhase: resources`. The upstream Plaud template has this bug, which is why its `PlaudDeviceBasicSDK.bundle` never actually got copied.
2. `entitlements.properties` **generates** `Bounce.entitlements`. Editing that file by hand is pointless; it is overwritten on the next `xcodegen generate`.

## Credentials

Runtime only. `Auth/TokenProvider` owns them; see [architecture.md](architecture.md#authentication) for the flow and threat model.

**Never move a credential into `project.yml`, an xcconfig, or `Info.plist`.** The security claims in the README depend on there being nothing to extract from the built app, and `project.yml` is tracked. If you need a new secret, add it to `PlaudCredentials` and let it ride the keychain path.

Practical notes when working on this area:

- Wipe stored state by deleting the app from the device — the keychain items are `ThisDeviceOnly` and app-scoped.
- `TokenProvider.userId` is generated once and persisted. Changing it orphans the recorder's binding, so don't regenerate it casually while debugging.
- `revealCredentials()` prompts for Face ID. On a device with no passcode, `canEvaluatePolicy` fails and it falls through to returning the credentials — deliberate, so you can't lock yourself out of your own settings.
- Never `print` a credential or token. There is no redaction layer to save you.

## Signing, and the WiFi entitlement gate

WiFi Fast Transfer needs two entitlements — `com.apple.developer.networking.HotspotConfiguration` and `wifi-info` — that only a **paid** Apple Developer Program membership can sign. Declaring them on a free Personal Team fails the build with:

> Provisioning profile "iOS Team Provisioning Profile" doesn't include the com.apple.developer.networking.HotspotConfiguration entitlement.

So they ship **off**. Three things move together, all in `app/project.yml`, marked `[WIFI FAST TRANSFER] n of 3`:

1. `SWIFT_ACTIVE_COMPILATION_CONDITIONS: BOUNCE_WIFI_FAST_TRANSFER`
2. The `entitlements:` block
3. `NSLocalNetworkUsageDescription` + `NSLocationWhenInUseUsageDescription`

Uncomment all three, `xcodegen generate`, done. `AppCapabilities.wifiFastTransfer` reads the compilation condition, and `AppModel.canUseWiFiTransfer` plus the Home toolbar menu gate on it.

**Why item 3 is not optional.** `SyncManager.startWiFiTransfer` calls `CLLocationManager.requestWhenInUseAuthorization()`, and iOS **terminates the app** if that runs without `NSLocationWhenInUseUsageDescription` present. That is why `startWiFiTransfer` opens with a hard `guard AppCapabilities.wifiFastTransfer` rather than relying on the UI to hide the entry point.

A pleasant side effect of the default: with WiFi transfer off, Bounce requests no location access whatsoever.

### Free provisioning

- Profiles expire after **7 days**; the app stops launching until you Run from Xcode again. Re-running installs over the top, so recordings, transcripts, and keychain credentials all survive. Only deleting the app wipes them.
- **Switching from a free team to a paid one changes your Team ID**, which changes the keychain access group prefix — stored Plaud credentials become unreadable and must be re-entered once. `Documents/` (recordings, transcripts) is unaffected.

## The app icon

The icon is **generated from a script**, not committed as a hand-drawn asset:

```bash
swift tools/make-icon.swift app/Bounce/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png
```

`tools/make-icon.swift` draws a 1024×1024 PNG with Core Graphics — a gradient background and a five-bar waveform. Keeping it as code means the icon is diffable and tweakable (change a height, a colour, the bar count, re-run) rather than a binary blob nobody can edit. Xcode's `actool` renders the smaller variants from the 1024 source.

The gradient uses the same blue family as `Color.bounce` in `UI/Common/Theme.swift`. **Change one, change the other** — nothing enforces it.

### If actool fails

You may see this on a machine with no simulator runtime installed:

> `Assets.xcassets: error: No available simulator runtimes for platform iphonesimulator. SimServiceContext supportedRuntimes=[]`

`actool` wants a simulator runtime even for a device-only build. It happened in this repo before Xcode had finished its first-launch component install, and resolved itself once Xcode was opened and signed in. If it persists:

```bash
xcodebuild -downloadPlatform iOS     # installs a simulator runtime (large)
```

## Conventions

- **SwiftUI only.** No UIKit views, no storyboards. `UIColor` appears once, in `Theme.swift`, to build a light/dark `Color` pair in code.
- **Glass is navigation chrome.** Never apply glass to content, never stack glass on glass, always route custom glass through `.adaptiveGlass(...)` so Reduce Transparency is honoured.
- **Don't modernise `Device/`.** Its `DispatchQueue.main.async` hops and guard flags are load-bearing. Read the guard table in [architecture.md](architecture.md) before touching reconnect logic.
- **Audio stays MP3.** `AVAudioFile` must be able to read it for transcription; Opus in Ogg cannot be read and would break transcription silently.
- **Paths are relative.** Store bare filenames for audio and resolve via `RecordingStore.audioURL(for:)`.
- Logging is `print` with a `[Component]` prefix. There is no logging abstraction; add one if it starts to hurt.

## Debugging notes

| Symptom | Likely cause |
|---|---|
| "Plaud rejected those credentials" on save | Wrong Client ID / Secret Key, or the region doesn't match your developer account. `PlaudAuthService` maps 401/403 to this message. |
| Worked yesterday, fails today | Token expiry. Check the Access token row in Settings; `refreshIfNeeded()` runs on foreground but stays silent on failure by design. |
| Scan finds nothing | Filter the console on `[Device]`. No `bleScanResult` at all means the radio never produced anything: check the logged Bluetooth status, then whether the recorder is still bound to another app (a Plaud device talks to one at a time — remove it in the Plaud app *and* force-quit that app, since a live BLE connection keeps it from advertising). A `bleScanResult` that lists devices you don't want means filtering is the problem, not scanning. |
| Spinner forever, no error | Bluetooth denied or powered off. `PlaudDeviceAgent.startScan()` is completely silent in that case — no error, no callback. `BluetoothMonitor` exists to catch it; `startScan` refuses and publishes `.failed` rather than pretending to scan. |
| SDK logs `region = jp` against a US domain | `setCustomDomain` sets the host but leaves the SDK's region enum stale. `DeviceManager.configure` now calls `PlaudDomainManager.setRegion` too. |
| Connects then immediately drops | Check the guard flags; something started a scan without publishing `.scanning`, or an OTA/WiFi transfer is in flight. |
| Transcription fails | Filter the console on `[Transcribe]`. It logs each stage — locale resolution, model install, format negotiation, then success or the failing stage — because the Speech framework's own errors are frequently a bare `Foundation._GenericObjCError error 0` that names nothing. |
| Transcription fails with "couldn't read the audio file" | The file is not MP3/WAV. Check `SyncManager.exportFormat`. |
| Transcript timestamps drift against the audio | `BufferConverter.primeMethod` must stay `.none`. Priming inserts leading silence, which offsets every `CMTimeRange` the transcriber reports. |
| `Failed precondition: Attempt to modify worker after it was locked` | The drive and finalise calls are mismatched. Use `analyzeSequence(_:)` + `finalizeAndFinish(through:)`. Never `start(inputSequence:)` + `finalizeAndFinishThroughEndOfInput()` — `start` runs its own worker and finalising from your task races it. Also check no `SpeechTranscriber` is being reused across two analyzers. |
| `_GenericObjCError.nilError` from the read loop | End-of-file. `AVAudioFile.read(into:)` throws at EOF instead of returning zero frames, so the loop must be bounded by `audioFile.length`. |
| `SpeechAnalyzer: Input loop ending with error: nilError` | Same mismatched-finalise cause as the worker-locked precondition above. |
| Transcription fails instantly with `CancellationError` | Something is cancelling the task running the analysis. Do not wrap `LocalTranscriber.transcribe` in a task-group timeout — `cancelAll()` tears down analysis mid-flight. See architecture.md. |
| Transcription hangs on "Transcribing…" | The locale wasn't reserved — look for `Cannot use modules with unallocated locales`. Reservation is required to *use* a module, not just to download the model. |
| Recording won't play, snaps back to 0:00 | Don't infer playback completion from `AVAudioPlayer.isPlaying` — it races with playback starting. Use `audioPlayerDidFinishPlaying`. Also check `AudioPlayerModel.errorMessage`, which the detail view surfaces. |
| WiFi Fast Transfer never starts | Location permission. `NEHotspotConfigurationManager` needs it on iOS 13+; `startWiFiTransfer` requests it and returns early, so the user must tap again after granting. |
| Audio missing after reinstall | Something stored an absolute path. Audio must be resolved through `RecordingStore.audioURL(for:)`. |
| Shortcuts actions don't appear | Confirm `Metadata.appintents` is present in the built `.app`. |

## Reference material

`reference/plaud-template-app-uikit/` is Plaud's original sample, kept read-only. It is the best source for SDK usage patterns not yet exercised by Bounce — microphone gain, U-disk mode, WiFi sync config, factory reset.

The authoritative API surface for the SDK is the generated Swift interface, not the docs:

```
sdk/ios/<Framework>.framework/Modules/<Framework>.swiftmodule/arm64-apple-ios.swiftinterface
```

Plaud's hosted docs: <https://docs.plaud.ai/plaud-embedded/overview>
