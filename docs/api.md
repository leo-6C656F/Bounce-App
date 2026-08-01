# The Bounce local API

Bounce runs a small HTTP server inside the iPhone app. It is what the desktop
view talks to, and it is documented here so that scripts, shortcuts, and AI
agents can talk to it too.

This document describes the routes in `WebAPI.route` — the dispatch table in
`app/Bounce/Web/WebAPI.swift` — which is the source of truth. If something here
disagrees with that file, the file is right.

---

## What this is, and what it isn't

**The iPhone is the server.** There is no Bounce cloud, no account, and no
relay. Your phone opens a TCP port on the local network and answers requests on
it. Everything a client reads — transcripts, summaries, audio — is read from the
phone's own storage and sent straight back over the LAN.

Five consequences worth understanding before you build anything on this:

- **It is LAN-only.** The server binds to the phone's address on the current
  wifi network. Nothing forwards it to the internet, and nothing should: the
  `Host` check described under [Security notes](#security-notes) exists partly
  to make sure a page on the internet can't drive it either.
- **It is off by default,** and it stops on its own. Settings → Desktop view has
  the switch, an idle timeout (30 minutes by default), and a per-browser revoke
  list.
- **Bounce must be running,** and on screen unless this build carries the
  background flag. iOS has no services — nothing runs outside the app's process —
  so an app switch is survivable only by not being suspended. Builds compiled
  with `BOUNCE_BACKGROUND_DESKTOP` stay resident by playing silence through the
  `audio` background mode, for up to two hours per background stretch; builds
  without it stop the server whenever Bounce leaves the foreground, except during
  an active recording, where continuous BLE traffic keeps the app awake. Either
  way the screen is kept awake while the server runs. **The flag is off in any
  build destined for the App Store** — Apple treats silent-audio residency as an
  abuse. See `BackgroundResidency.swift` for why every other mechanism
  (`BGContinuedProcessingTask`, `NEAppPushProvider`, background location) was
  rejected.
- **Nothing can start Bounce from off the phone.** With the app closed there is no
  listener, and iOS has no wake-on-LAN equivalent for an app. What works instead
  is a Shortcuts personal automation running the **Start Desktop View** action —
  on joining a wifi network, an NFC tag, a time of day. `DesktopIntents.swift`
  records why silent push, PushKit and CoreBluetooth state restoration are all
  worse answers, and why that intent has to open the app rather than run headless.
- **The address changes.** It's whatever DHCP gave the phone. A script that
  hardcodes an IP will break the next time you join a different network.
- **The certificate is self-signed**, so every client has to be told to accept
  it. See [Deal with the certificate](#2-deal-with-the-certificate).

What that adds up to: this is a good API for "my laptop, my agent, my phone on
the desk next to me". It is not a good API for anything that needs to reach your
recordings while the phone is in your pocket.

---

## Getting started

### 1. Switch the server on

On the iPhone: **Settings → Desktop view → Desktop view**.

The screen then shows three things you need:

| Shown | Example | What it's for |
|---|---|---|
| The address | `https://192.168.1.42:8080` | The base URL for every request below |
| A pairing code | `418302` | Six digits, exchanged once for a session token |
| A certificate fingerprint | `A1:B2:…` (SHA-256) | The only way to check you reached *this* phone |

The default port is **8080**; you can change it in Settings while the server is
stopped. The default scheme is **`https`** — encryption is on by default, which
is why the certificate needs the section below.

Every example in this document uses `https://192.168.1.42:8080` as the base URL.
Substitute the address your phone actually shows.

### 2. Deal with the certificate

Bounce mints its own TLS certificate on the phone, on first start, and stores it
in the keychain. **No one can issue a publicly-trusted certificate for
`192.168.1.42`** — certificate authorities do not sign private addresses, and
they couldn't verify ownership if they wanted to. So the certificate is
self-signed, and every client rejects it until told otherwise. That is expected,
not a misconfiguration.

What it buys you: **encryption without authentication.** Anything passively
sniffing the wifi — the realistic threat on office, guest, or café networks — can
no longer read your transcripts, your audio, or your pairing code off the wire.
What it does *not* buy: proof that the thing answering is your phone. An attacker
who can redirect traffic can present their own certificate and get the same
warning you're already used to clicking past.

**In a browser:** you get an interstitial the first time. On Safari, click
*Show Details → visit this website*. On Chrome, *Advanced → Proceed*. The
exception is remembered per browser, per certificate.

**With `curl`:** pass `-k` (equivalently `--insecure`) to skip verification.

```bash
curl -k https://192.168.1.42:8080/api/session
```

**Better than `-k`,** if you want the encryption to actually mean something: pin
the certificate instead of disabling verification. Fetch it once, check the
fingerprint against what Settings shows, then verify against it every time.

```bash
# 1. Grab the certificate the phone is serving.
openssl s_client -connect 192.168.1.42:8080 -showcerts </dev/null 2>/dev/null \
  | openssl x509 -outform PEM > bounce.pem

# 2. Print its SHA-256 fingerprint and compare, by eye, against the one under
#    Settings › Desktop view › Encryption. They must match exactly.
openssl x509 -in bounce.pem -noout -fingerprint -sha256

# 3. From now on, verify against that certificate instead of using -k.
curl --cacert bounce.pem https://192.168.1.42:8080/api/session
```

Comparing that fingerprint by hand is the *only* authentication available here.
Browsers expose no API for a page to check its own certificate, so Bounce cannot
do it for you.

Two more things about the certificate:

- **It covers the phone's current addresses.** The Subject Alternative Name is
  built from the addresses the phone has right now, so joining a different
  network mints a fresh certificate — and every stored exception and pinned copy
  stops matching. Re-accept, or re-pin.
- **Settings → Desktop view → Replace certificate** throws the current one away
  deliberately. Every browser will warn again.

If you would rather not deal with any of this on a network you fully control,
**Settings → Desktop view → Encrypt the connection** turns TLS off and the base
URL becomes `http://…`. Everything below works identically. Understand what you
are giving up: transcripts, audio, *and the pairing code* then cross the network
as plain text.

### 3. Pair

Pairing exchanges the six-digit code for a token. Do this once per client.

```bash
curl -k -c cookies.txt \
  -X POST https://192.168.1.42:8080/api/pair \
  -H 'Content-Type: application/json' \
  -d '{"code":"418302"}'
```

```json
{ "paired": true }
```

The token comes back in a `Set-Cookie` header, which `-c cookies.txt` saves.
Send it back with `-b cookies.txt` on subsequent requests.

**The code is spent on use.** A successful pair rotates it immediately, so a code
read over someone's shoulder is already worthless. **Five wrong attempts switches
the whole server off** — not just a lockout, the listener stops — so don't build
a client that retries a guess.

---

## Authentication

There are two ways in, for two different kinds of client.

### The browser session cookie

```
Set-Cookie: bounce_session=<64 hex chars>; Path=/; HttpOnly; SameSite=Strict
```

This is what `POST /api/pair` issues, and it is **deliberately short-lived**:

- It is a **session cookie** — no `Max-Age`, no `Expires` — so the browser drops
  it when it closes.
- The server side is in memory only. The paired-client list lives in `WebSession`
  and **dies with the app**. Force-quit Bounce and every browser has to pair
  again. (Backgrounding is gentler: the server stops but paired clients are kept
  so foregrounding restores them.)
- `HttpOnly` means page script can't read it. `SameSite=Strict` means a
  cross-site request can't carry it.

The reason it isn't durable is that **cookies ignore port and outlive DHCP
leases**. A long-lived cookie scoped to `192.168.1.42` would be offered to
whatever device holds that address next week.

That is the right trade for a browser and the wrong one for a script, hence:

### The bearer token

For agents and scripts, generate a token in **Settings → Desktop view** and send
it as a standard bearer credential:

```bash
curl -k -H "Authorization: Bearer $BOUNCE_TOKEN" \
  https://192.168.1.42:8080/api/library
```

**The header is the only way to present it.** `Authorization: Bearer <token>`,
and nothing else — there is no `X-Bounce-Token` header and no query parameter,
deliberately. The scheme is matched case-insensitively (`Bearer`, `bearer`,
`BEARER` all work) and stray whitespace around the header and between the scheme
and the token is tolerated. Rejected: any other scheme, `Bearer` with nothing
after it, a bare token with no scheme, and anything after the token (tokens
contain no spaces).

**The token looks like this:**

```
bnc_v2xbq7m9k4hjt3rnpw8scdf6zy5g2abc
```

A `bnc_` prefix and 32 characters, 36 in total. The alphabet is
`23456789abcdefghijkmnpqrstuvwxyz` — lowercase and digits with `0`, `1`, `l` and
`o` left out, so a human retyping one can't transpose the look-alikes. That's 160
bits of entropy; the prefix carries none and exists so a token is recognisable in
a config file. Where a token is shown truncated, the convention is the first
eight characters: `bnc_v2xb…`.

Unlike the cookie, this one lives in the iPhone **keychain**, so:

- **It survives an app restart, and desktop view being switched off and on
  again.** That is the whole reason it exists. The browser session cookie is
  in-memory trust that dies with the app; this doesn't.
- **It exists on exactly one device.** The keychain item is
  `WhenUnlockedThisDeviceOnly`: excluded from iCloud Keychain and from encrypted
  Finder/iTunes backups, and unreadable while the phone is locked. There's no way
  to copy it off except reading it in Settings. (In practice the lock state never
  shows up as a 401 — locking the phone backgrounds the app, which stops the
  server, so you get a refused connection first.)

**There is one token at a time.** Generating replaces the previous one — there's
no list of issued tokens, because unlike a paired browser a token isn't
attributable to a particular client. Two agents sharing your library share one
token, and revoking cuts off both.

**Understand what you are holding.** The token grants read access to **every
transcript, summary, and audio file on the phone** — plus the write and delete
routes in the reference — from any device on the same network, without the
pairing code, whether or not a browser is connected. It does not expire. It stops
working only when revoked, and revocation is immediate: the keychain is read per
request with no cache, so the very next request fails.

**Revocation reaches open streams too.** A bearer token works on `GET /api/live`,
and each stream is registered against whichever credential opened it. Revoking
sends that stream `{"type":"unauthorized"}` and closes it, rather than leaving an
agent quietly receiving live transcripts from a credential you've withdrawn.

**Where to get one, and the one chance to copy it.** Settings → Desktop view →
**API access**, which has a single *Generate API token* button. The token is
shown **once**, right after generating, with a Copy button — save it then. After
you dismiss it, the screen shows only a redacted form (`bnc_v2xb…`) and offers
*Replace token* and *Revoke token*. There is no way to read it back; a token
permanently readable on screen is a token that leaks over someone's shoulder.

Replacing immediately breaks anything using the old one. Revoking breaks
everything using the token — but **browsers paired with the six-digit code are
unaffected**, and vice versa: the two credentials are independent.

Three rules:

1. **Never put the token in a URL query string.** Query strings are written to
   server logs, browser history, and shell history, and they leak through
   `Referer` headers. This is also why no route accepts one — the option isn't
   there to be misused.
2. **Never commit it.** Keep it in an environment variable or your OS keychain.
   `export BOUNCE_TOKEN=…` in a file your shell reads, not in the script.
3. **Revoke it when you stop using it.** Generating a new one is five seconds;
   an unrevoked token on an old laptop is forever.

### What each gate rejects

Every request passes four gates, in this order, *before* any handler runs. A
`403` means Gate 1, 2 or 4; a `401` means Gate 3. Knowing which is which saves an
afternoon.

**Gate 1 — Host allow-list. Rejects with `403 {"error":"Unrecognised host."}`.**

The `Host` header must name this phone: `localhost`, `127.0.0.1`, one of the
phone's current IPv4 addresses, its Bonjour name (`Bounce.local`), or *any*
literal address in a private IPv4 range (`10.*`, `192.168.*`, `172.16–31.*`,
`169.254.*` — because the phone's address can change under the app faster than
the allow-list is refreshed).

This runs first, before even the login page, so a request that lies about the
host gets nothing to work with. It is what stops **DNS rebinding**: a page on
`evil.example` can make your browser connect to your phone, but it cannot make
the browser lie about which host it asked for.

You will trip this by using a hostname the phone doesn't know about — a
`/etc/hosts` alias, a public DNS name pointed at the LAN address, or a reverse
proxy that rewrites `Host`. Use the address Settings shows.

**Gate 2 — Same-site. Rejects with `403 {"error":"Cross-site requests aren't accepted."}`.**

Requests carrying `Sec-Fetch-Site: cross-site` (or `same-site`) are refused. That
header is set by the browser and page script cannot forge it. When it's absent,
`Origin` is checked instead; when *neither* is present the request is treated as
same-site, which is why `curl` works.

Without this, any website you happen to be visiting could `POST` to `/api/pair`
— a `text/plain` body makes a cross-origin POST a CORS "simple request", so
there is no preflight to block it — and burn the five-attempt cap to switch your
server off from across the internet.

You will trip this by `fetch()`-ing the API from a page served from anywhere
other than the phone itself, including a local `file://` HTML file.

**Neither gate needs anything special from a script.** Gate 1 accepts any private
IPv4 literal, and Gate 2 reads "no `Sec-Fetch-Site` and no `Origin`" as
same-site, so `curl`, an MCP client, and a shell script all pass with just the
token — while a browser page from another origin stays blocked, because a browser
always sends those headers. That asymmetry is the design, not a loophole: the
gates exist to stop a *page* driving the server, and a script you ran yourself
isn't one. If you're staring at a 403, the cause is almost always a `Host` you
invented (Gate 1) rather than anything about the credential.

**Gate 3 — Credential. Rejects with `401 {"error":"Not paired with this iPhone."}`.**

The session cookie or the bearer token. Four routes sit *in front* of this gate
and need no credential: `GET /`, `GET /index.html`, `GET /api/session`, and
`POST /api/pair`.

`/api/live` is the one exception to the 401, and it's a browser quirk rather than
a design choice: `EventSource` treats **any non-200 status as fatal** — per the
HTML spec that's *fail the connection*, not *reconnect*, so `readyState` goes to
CLOSED and stays there until the page is reloaded. A bad credential on that route
therefore gets a **200 event stream whose only message is
`{"type":"unauthorized"}`**, followed by a close. Clients must check for that
event; they cannot rely on a status code.

**Gate 4 — Read-only for bearer tokens. Rejects with `403 {"error":"This token is read-only."}`.**

A bearer token may only make **`GET` requests, plus `POST /mcp`**. A browser
session cookie is unaffected and keeps full write access — the desk view edits
titles, speakers and categories.

This is what makes the read-only guarantee true of *the whole API* rather than
just the MCP tool list. The tools in [The tools](#the-tools) are read-only by
construction, but the REST routes are not, and Gate 3 admits a bearer token to
every one of them — so without this gate a token could `DELETE
/api/recordings/<id>`, or retitle, recategorize, correct, re-transcribe and
re-summarize any recording. The reasoning is the same one that shaped the tool
list: the thing holding this token is a language model acting on instructions
that may themselves have come out of a transcript, and a prompt-injected agent
with a delete verb costs the user their recordings.

`POST /mcp` is the one write-shaped exception, because it is a JSON-RPC envelope
over read-only tools rather than a mutation.

You will trip this by pointing a script at a write route with a bearer token. There
is no token that can perform writes; use the desk view in a paired browser.

---

## Conventions

**Base URL.** `https://<phone-address>:8080`, from Settings. `http://` if you
turned encryption off.

**Content type.** Every JSON response is `application/json; charset=utf-8` with
`Cache-Control: no-store` and `X-Content-Type-Options: nosniff`. The `no-store`
matters: these payloads carry whole transcripts, and without it Safari would
answer a post-edit refetch out of its disk cache.

**Request bodies** are JSON. Send `Content-Type: application/json`. Bodies are
capped at **1 MB** (`413 Request body too large.`) and headers at 64 KB
(`413 Headers too large.`). **Chunked request bodies are not supported** —
`400 Chunked requests aren't supported.` Send a `Content-Length`.

**Dates** are ISO 8601 with a `Z` suffix: `"2026-07-31T09:14:22Z"`.

**Durations** come in two forms side by side. `duration` is seconds as a number;
`durationText` (and `timecode`) is a preformatted string — `m:ss`, or `h:mm:ss`
past the hour. Use the preformatted one for display. Bounce formats it server
side on purpose: there is exactly one timecode formatter in the app, and four
divergent copies once made a 92-minute recording read "92:14" in four places at
once.

**Errors** are always JSON: `{"error": "A sentence a human can read."}`. Status
codes in use are `400`, `401`, `403`, `404`, `405`, `409`, `413`, `416`, `429`,
`500`, and `503`.

**`HEAD` works** on any `GET` route — it is routed as the `GET` and the body
suppressed at write time, so the headers are exactly the ones the `GET` would
have sent.

**Keep-alive** is honoured. Event streams are the exception: they are
close-delimited, so they always answer `Connection: close`.

**Server-sent events are unnamed.** Every event is plain `data:` lines with no
`event:` field, so in a browser you handle them all in `onmessage` and switch on
the payload's `type`. Multi-line payloads are framed correctly (each line gets
its own `data:` prefix).

---

## Endpoint reference

### Unauthenticated

#### `GET /` · `GET /index.html`

The desktop client — one static `index.html` from the app bundle, with inlined
CSS and JavaScript. Served with a strict `Content-Security-Policy` that blocks
outside loads and framing.

Nothing else is served from here; there are no static asset routes.

---

#### `GET /api/session`

Whether the credential you presented is currently good. Used by the client to
decide between showing the pairing screen and showing the library.

```bash
curl -k -b cookies.txt https://192.168.1.42:8080/api/session
```

```json
{ "paired": true }
```

Always `200`, past Gates 1 and 2. `{"paired": false}` is the answer for no
credential, a wrong one, or one revoked since.

**Both credentials count** — a session cookie or a bearer token. This is a
reliable way to check whether a token still works without fetching anything.

---

#### `POST /api/pair`

Exchange the six-digit pairing code for a session cookie.

**Body:** `{"code": "418302"}` — non-digits are stripped before comparison, so
`"418 302"` also works.

```bash
curl -k -c cookies.txt -X POST https://192.168.1.42:8080/api/pair \
  -H 'Content-Type: application/json' -d '{"code":"418302"}'
```

**200** — paired. `Set-Cookie: bounce_session=…; Path=/; HttpOnly; SameSite=Strict`.

```json
{ "paired": true }
```

**400** `{"error":"Missing code."}` — no body, or no `code` key.

**401** — wrong code. Note the extra field:

```json
{ "error": "That code doesn't match.", "remainingAttempts": 3 }
```

**429** `{"error":"Too many attempts. Desktop view has been switched off on the iPhone."}`
— the fifth wrong attempt. The server stops; someone has to switch it back on
from the phone.

---

### Collections

#### `GET /api/library`

Every recording, newest first, as summary rows. **Transcript text is
deliberately excluded** — a library of long meetings would be megabytes per
refresh. Fetch a recording to get its text.

```bash
curl -k -H "Authorization: Bearer $BOUNCE_TOKEN" \
  https://192.168.1.42:8080/api/library
```

```json
[
  {
    "id": "live",
    "title": "Recording in progress",
    "categoryName": null,
    "createdAt": "2026-07-31T14:02:11Z",
    "duration": 184.3,
    "durationText": "3:04",
    "isSynced": false,
    "isTranscribed": false,
    "isPreview": true,
    "wordCount": 412,
    "summaryCount": 0,
    "highlightCount": 1,
    "speakerCount": 2,
    "status": "Recording"
  },
  {
    "id": "4C1F9B2A-7E30-4A6D-9C11-0B8E5D2F6A44",
    "title": "Budget review",
    "categoryName": "Meeting",
    "createdAt": "2026-07-30T09:14:22Z",
    "duration": 2734.0,
    "durationText": "45:34",
    "isSynced": true,
    "isTranscribed": true,
    "isPreview": false,
    "wordCount": 6841,
    "summaryCount": 2,
    "highlightCount": 3,
    "speakerCount": 4,
    "status": null
  }
]
```

| Field | Type | Meaning |
|---|---|---|
| `id` | string | Recording id — a UUID string, opaque and stable. `"live"` for the recording in progress, see below |
| `title` | string | Display title; falls back to the first words of the transcript when untitled |
| `categoryName` | string \| null | The AI-assigned or user-set category's **name** |
| `createdAt` | ISO 8601 | When the recording started |
| `duration` | number | Seconds |
| `durationText` | string | Preformatted, or `"--:--"` when the duration is unknown |
| `isSynced` | bool | The audio has been pulled off the recorder onto the phone |
| `isTranscribed` | bool | A transcript exists |
| `isPreview` | bool | That transcript is the live draft, not the authoritative pass |
| `wordCount` | number | 0 when untranscribed |
| `summaryCount` | number | Generated summaries |
| `highlightCount` | number | Marks the user dropped while recording |
| `speakerCount` | number | Distinct diarization labels; 0 when not diarized |
| `status` | string \| null | A human-readable transcription state, or `null` when idle. `"Queued"`, `"Downloading language model"`, `"Transcribing"`, `"Recording"` for the live row — **or, on failure, the error message itself.** Display it; don't switch on it |

**Errors:** the four gates only.

> **Rows carry no tags or action items** — fetch the recording for those. They're
> on `WebRecordingDetail`, not `WebRecordingRow`, for the same reason transcript
> text is: a library payload that carried everything would be megabytes per
> refresh. Nothing can *write* a tag or tick an item over this API.

---

#### `GET /api/search?q=<text>`

Recordings whose **title or transcript** contains `q`, case-insensitively.
Returns the same `WebRecordingRow` shape as `/api/library`.

```bash
curl -k -H "Authorization: Bearer $BOUNCE_TOKEN" \
  --get --data-urlencode 'q=hiring line' \
  https://192.168.1.42:8080/api/search
```

This exists so an agent can find one recording without pulling the whole library
and matching client-side — which matters more than it sounds, because the library
payload would carry every transcript. It matches on exactly the same two fields,
in the same order, as the Library screen's own search field, so the phone and a
script find the same recordings for the same words.

Unlike `/api/library`, the in-progress recording is **not** pinned to the top;
search only covers stored recordings.

**Errors:** **400** `{"error":"Missing q."}` when `q` is absent or blank. An empty
result is a `200` with `[]`.

---

#### `GET /api/openapi.json`

A static OpenAPI 3.1 schema of the read routes — `/api/library`, `/api/search`,
`/api/recordings/{id}`, `/api/recordings/{id}/audio`, `/api/categories`,
`/api/templates`, `/api/ask` — with `bearerAuth` declared as the security scheme.

```bash
curl -k -H "Authorization: Bearer $BOUNCE_TOKEN" \
  https://192.168.1.42:8080/api/openapi.json
```

`info.version` is read from the app bundle, so the schema can't claim a version
the app isn't.

**The schema is deliberately narrower than this document, and this document is
the authoritative reference.** It is hand-maintained and covers the read surface
only — the write routes the browser client uses (`title`, `speakers`, `correct`,
`category`, `transcribe`, `summarize`, `DELETE`) are documented here but left out
of the schema on purpose. A small honest schema beats an exhaustive one that
rots. Read it as a machine-readable starting point for a client generator, not as
the full contract.

One practical note: it's served as `Content-Type: application/json` **without**
the `no-store` / `nosniff` headers the other JSON routes carry, because it's a
static schema rather than a transcript.

---

#### `GET /api/categories`

The user's recording categories.

```json
[
  { "id": "9E1C…", "name": "Meeting", "colorName": "blue", "symbolName": "person.2.fill" },
  { "id": "4B7A…", "name": "Note",    "colorName": null,   "symbolName": null }
]
```

`colorName` and `symbolName` are plain strings the UI resolves to a colour and an
SF Symbol; both may be null. **`POST /api/recordings/<id>/category` matches on
`name`, not `id`** — see that route.

---

#### `GET /api/templates`

The summary templates available to `POST /api/recordings/<id>/summarize`.

```json
[
  { "id": "builtin.summary",   "name": "Summary",       "isBuiltIn": true },
  { "id": "builtin.actions",   "name": "Action items",  "isBuiltIn": true },
  { "id": "builtin.decisions", "name": "Key decisions", "isBuiltIn": true },
  { "id": "builtin.notes",     "name": "Meeting notes", "isBuiltIn": true },
  { "id": "3F02…",             "name": "Client recap",  "isBuiltIn": false }
]
```

The four `builtin.*` templates ship with the app; a user can edit their prompts
(the id stays the same) and add their own, which get UUID ids.

---

#### `GET /api/ask?q=<question>`

Ask Apple's on-device model a question about **the whole library**. Streams the
answer back as server-sent events.

It's a `GET` returning `text/event-stream` rather than a `POST` because the
answer streams and `EventSource` is the only thing in a browser that consumes a
stream with no plumbing. Same engine and same privacy posture as the phone's Ask
tab: on device, nothing uploaded.

```bash
curl -kN -H "Authorization: Bearer $BOUNCE_TOKEN" \
  --get --data-urlencode 'q=What did we decide about the budget?' \
  https://192.168.1.42:8080/api/ask
```

(`-N` disables curl's output buffering; without it the stream looks frozen.)

```
data: {"type":"sources","sources":[{"id":"4C1F9B2A-7E30-4A6D-9C11-0B8E5D2F6A44","title":"Budget review","durationText":"45:34"}]}

data: {"type":"answer","text":"You decided to"}

data: {"type":"answer","text":"You decided to defer the hiring line"}

data: {"type":"done"}
```

Event types:

| `type` | Payload | Notes |
|---|---|---|
| `sources` | `sources: [{id, title, durationText}]` | Which recordings were used as grounding. Always sent first; empty array for a single-recording ask |
| `answer` | `text: string` | **Cumulative, not a delta.** Assign, don't append |
| `unavailable` | `reason: string` | Model or content missing; the stream then closes |
| `done` | — | Finished; the stream then closes |

`unavailable` covers three cases, each with its own human-readable `reason`:
Apple Intelligence isn't available on this iPhone, this recording has no
transcript yet, or nothing in the library is transcribed yet. All three arrive
with **status 200** — the stream opened fine, there just isn't an answer.

**Errors** (these *are* status codes, because they're rejected before the stream
opens):

- **400** `{"error":"Ask a question."}` — `q` missing or blank.
- **400** `{"error":"That question is too long."}` — over 500 characters. The
  model's context window is small and the question is prepended to the grounded
  transcript, so an essay just crowds the transcript out.

The grounded corpus is capped to roughly the most recent 10k characters, so for
long recordings the answer comes from the tail.

---

#### `GET /api/live`

The phone pushing state to you: live transcript, device status, and a nudge to
refetch the library. One long-lived `text/event-stream`.

```bash
curl -kN -H "Authorization: Bearer $BOUNCE_TOKEN" \
  https://192.168.1.42:8080/api/live
```

Updates are polled and diffed at **4 Hz** and only sent on a change, plus a
heartbeat every 15 seconds.

| `type` | Payload | When |
|---|---|---|
| `live` | `isRunning`, `sessionId`, `error`, `volatile`, `blocks` | The live transcript changed. `volatile` is the not-yet-final text being spoken; `blocks` are settled `WebBlock`s |
| `status` | `connected`, `deviceName`, `isRecording`, `transcribing` | Recorder connection or transcription state changed. `transcribing` is the id of the recording being worked on, or null |
| `library` | — | Something in the library changed. **This is a signal to refetch `/api/library`, not the data** — sending the whole list at 4 Hz would re-encode every transcript |
| `ping` | — | Heartbeat, every 15s. Ignore it; it exists to notice dead sockets |
| `unauthorized` | — | Your credential isn't (or is no longer) good. The stream closes right after |

**The `unauthorized` quirk.** This route never answers `401`, because
`EventSource` treats any non-200 as fatal and would never retry. Both an
unauthenticated request *and* a mid-stream revocation are answered **in band**
with a 200 stream carrying `{"type":"unauthorized"}`, followed by a close.

Both credentials work here, and revocation reaches either. The stream is
registered under whichever one opened it — the session cookie for a browser, the
bearer token for an agent — so revoking a browser in Settings, or revoking the
API token, closes exactly that client's streams and no one else's.

**Errors:** Gates 1 and 2 still return `403` here. Only Gate 3 is answered in
band.

---

### Settings

#### `GET /api/settings` · `PATCH /api/settings`

**Cookie only, both verbs.** A bearer token gets `403 {"error":"Settings are only
available to a paired browser."}` — including on the `GET`, which Gate 4 would
otherwise allow. The snapshot carries the delivery webhook URL, and an internal
endpoint is not something to hand to a long-lived token sitting in a config file.
The token's contract is "read the recordings", not "read the configuration".

The response is grouped into four sections — `transcription`, `ai`, `delivery`,
`recorder` — each a flat map of field name to value. A field with a fixed set of
choices is accompanied by a sibling `<field>Options` array giving the exact
`{value, label}` pairs the phone's own picker offers, so a client can render the
control without hardcoding a list that drifts:

```json
{
  "transcription": {
    "engine": "local",
    "engineOptions": [
      { "value": "local",  "label": "On-device (Apple)" },
      { "value": "soniox", "label": "Soniox (cloud)" }
    ],
    "effectiveEngine": "local",
    "sonioxKeySet": false,
    "localeIdentifier": null,
    "localeLabel": "English (United States)",
    "transcribeOnSync": true,
    "liveTranscription": false,
    "sonioxLanguageHints": "en, es",
    "sonioxVocabulary": "",
    "sonioxTranslationTarget": "",
    "sonioxTranslationTargetOptions": [ { "value": "", "label": "Off" }, "…" ]
  },
  "ai": {
    "autoOrganize": true,
    "calendarTitles": false,
    "geotagRecordings": false,
    "appleIntelligenceAvailable": true,
    "appleIntelligenceReason": null
  },
  "delivery": {
    "autoDeliver": false,
    "activeDestinations": [ { "value": "webhook", "label": "Webhook" } ],
    "payloadContent": "audioAndTranscript",
    "payloadContentOptions": [ "…" ],
    "transcriptFormat": "markdown",
    "transcriptFormatOptions": [ "…" ],
    "webhookEnabled": true,
    "webhookURL": "https://example.com/hook",
    "webhookSecretSet": true,
    "folderEnabled": false,
    "folderName": null,
    "folderEditable": false
  },
  "recorder": {
    "deleteFromRecorderAfterSync": true,
    "lowBatteryAlerts": false,
    "lowBatteryThreshold": 20,
    "lowBatteryThresholdOptions": [ { "value": 10, "label": "10%" }, "…" ]
  }
}
```

A missing value is JSON `null`, never an omitted key — `localeIdentifier: null`
means "follow the phone's current locale", and `localeLabel` resolves what that
will actually be. `effectiveEngine` is what will really run: selecting Soniox
without storing a key leaves it `"local"`.

`PATCH` takes the same nesting but only the keys you're changing, and addresses
values directly — `{"transcription": {"engine": "soniox"}}`, not the `*Options`
arrays, which are read-only and rejected.

**Secrets are never returned.** `sonioxApiKey` and `webhookSecret` are write-only:
the snapshot reports only whether each is *set*, via `sonioxKeySet` and
`webhookSecretSet`. Writing an empty string to either clears it.

`PATCH` is **sparse and all-or-nothing**. Only the keys present are applied, and
nothing is written unless every field validates — a partially-applied settings
write is worse than a rejected one, because the client's next `GET` would
disagree with the error it just got. Returns the full fresh snapshot on success.

```bash
curl -X PATCH --cacert bounce.pem -b cookies.txt \
  -H 'Content-Type: application/json' \
  -d '{"transcription": {"engine": "soniox"}}' \
  https://192.168.1.42:8080/api/settings
```

| Status | Meaning |
|---|---|
| `400` | Unknown key, wrong type, a value outside the offered choices, or a write to a read-only field |
| `403` | Bearer token, on either verb |
| `500` | The keychain refused the secret |

Two things the API deliberately cannot do:

- **Nothing here touches the recorder.** `DeviceSettings` is absent from the
  registry: setting one of its properties fires a BLE command, which needs a
  connected device and has a completely different failure model from writing a
  preference.
- **It cannot grant a permission.** `ai.calendarTitles`, `ai.geotagRecordings`
  and `recorder.lowBatteryAlerts` can only be switched *off* from here. iOS can only
  prompt on the phone, and those toggles store what was granted rather than what
  was tapped.

**A recording's location is deliberately absent from every API response**, including
the MCP tools and the desktop view's own payloads. It is the most sensitive field
`library.json` holds, the API is reachable over the local network, and no consumer of
this API has asked for it — so it stays on the phone alongside the same rule for
webhook and folder deliveries. Adding it would need its own opt-in, not a quiet
inclusion.

`delivery.folderEditable` is always `false` and reported rather than omitted: the
folder is a security-scoped bookmark only `UIDocumentPicker` on the phone can
mint, so a client needs to know the control exists *and* that it can't drive it.

---

### Per-recording

Path shape: `/api/recordings/<id>[/<action>]`. A path with fewer than three
segments, or one that isn't `api/recordings/…`, is `404 {"error":"No such endpoint."}`.

An unknown `<id>` is **404** `{"error":"No such recording."}`. A method/action
combination that exists as an id but not as a route is **405**
`{"error":"Not allowed on this resource."}`.

#### The `live` pseudo-id

`<id>` = **`live`** addresses the recording *in progress*. It needs a synthetic
id because a live recording is not a `Recording` yet — the file is still on the
recorder, so there is no store entry and no real id until it syncs.

It is shaped as an ordinary recording so it flows through the same payload types,
and it is pinned to the top of `/api/library`. `hasAudio` comes out false, so a
client hides the transport.

Only three things work on it:

| Method | Path | |
|---|---|---|
| `GET` | `/api/recordings/live` | The detail payload, transcript included |
| `GET` | `/api/recordings/live/ask?q=` | Ask about the meeting you're in |
| `POST` | `/api/recordings/live/speakers` | Name the voices — mid-meeting is when you actually know who's talking |

Speaker names set here are parked by session id and attached when the file syncs.

**Errors:** `404 {"error":"Nothing is recording."}` when nothing is; anything
other than the three above is `400 {"error":"That isn't available until the recording finishes."}`.

---

#### `GET /api/recordings/<id>`

The whole recording: metadata, transcript grouped into blocks, speakers,
highlights, summaries.

```bash
curl -k -H "Authorization: Bearer $BOUNCE_TOKEN" \
  https://192.168.1.42:8080/api/recordings/4C1F9B2A-7E30-4A6D-9C11-0B8E5D2F6A44
```

```json
{
  "id": "4C1F9B2A-7E30-4A6D-9C11-0B8E5D2F6A44",
  "title": "Budget review",
  "rawTitle": "Budget review",
  "categoryName": "Meeting",
  "createdAt": "2026-07-30T09:14:22Z",
  "syncedAt": "2026-07-30T10:02:40Z",
  "duration": 2734.0,
  "durationText": "45:34",
  "deviceSN": "8810B5…",
  "isSynced": true,
  "hasAudio": true,

  "blocks": [
    {
      "id": 0,
      "start": 4.12,
      "timecode": "0:04",
      "speaker": "Dana",
      "speakerId": "1",
      "text": "Right, let's start with the hiring line.",
      "phrases": [
        { "start": 4.12, "text": "Right, let's start" },
        { "start": 5.60, "text": "with the hiring line." }
      ]
    }
  ],
  "plainText": "Right, let's start with the hiring line. …",
  "localeIdentifier": "en_US",
  "isPreview": false,
  "wordCount": 6841,

  "speakers": [
    { "id": "1", "label": "Speaker 1", "name": "Dana" },
    { "id": "2", "label": "Speaker 2", "name": null }
  ],
  "speakerNames": { "1": "Dana" },
  "livePreviewText": "Right lets start with the hiring line …",
  "highlights": [ { "seconds": 612.0, "timecode": "10:12" } ],
  "summaries": [
    {
      "templateId": "builtin.actions",
      "templateName": "Action items",
      "text": "- Dana to circulate the revised figures…",
      "createdAt": "2026-07-30T10:05:12Z"
    }
  ],

  "tags": [ { "id": "7C4E…", "name": "Budget" } ],
  "actionItems": [
    {
      "id": "B21F…",
      "text": "Circulate the revised figures",
      "owner": "Dana",
      "dueText": "by Friday",
      "isDone": false,
      "sourceOffset": 612.0
    }
  ]
}
```

Fields that aren't self-explanatory:

- **`title` vs `rawTitle`.** `title` is the display title, which falls back to
  the first words of the transcript when the recording is untitled. `rawTitle` is
  what's actually stored, possibly the `"Untitled Recording"` sentinel. **Prefill
  an edit field from `rawTitle`** — using `title` makes editing an untitled
  recording silently adopt its transcript's opening words.
- **`blocks`** are the transcript pre-grouped by speaker and rendered as
  paragraphs. Grouping happens server side so two clients can't disagree about
  where a block breaks.
- **`phrases`** are the sub-segments a block was joined from, for follow-along
  highlighting during playback. **Only `start` is sent, deliberately.** Segments
  don't abut — both Apple's phrase ranges and Soniox's token spans leave gaps at
  pauses — so a client that matched the playhead against `start..<end` would
  unhighlight the paragraph several times per block and reliably at its tail.
  Pick the most recent phrase that has *started*.
- **`speaker` vs `speakerId`.** `speaker` is the resolved display label — the
  user's name, or `"Speaker 1"`, or null when the transcript isn't diarized.
  `speakerId` is the raw diarization label, which is what you send back to
  `/speakers`. The label is resolved server side because `"Speaker " + id` is
  wrong for non-numeric labels: you'd render `spk_a` in the transcript and
  `Speaker spk_a` in the naming row beside it.
- **`speakers[].label`** is the same resolution, for the naming UI.
- **Diarization labels are anonymous and per recording.** Speaker `"1"` in one
  recording is not the same person as `"1"` in another. There is no voice
  enrollment; don't build one on top of this.
- **`isPreview`** true means the transcript is the live draft and the
  authoritative pass hasn't run yet.
- **`livePreviewText`** is the archived live draft, kept after the authoritative
  pass replaced it. Null when there wasn't one.
- **`hasAudio`** is whether the MP3 is actually on disk, which is not the same as
  `isSynced`.
- **`tags`** arrive as `{id, name}` pairs, resolved server-side. The model stores
  bare category ids, which mean nothing to a client with no way to resolve them,
  and making you fetch `/api/categories` to render a chip would be a round trip
  for nothing. Ids that no longer resolve — a tag deleted by hand — are dropped
  rather than rendered blank.
- **`actionItems[].dueText` is the deadline as spoken** ("by Friday"), never
  resolved to a date. The phrase is all the evidence there is; don't turn it into
  a calendar entry. `sourceOffset` is seconds into the recording, for seeking
  back to where it was said.

---

#### `GET /api/recordings/<id>/audio`

The MP3. Range-aware.

```bash
curl -k -H "Authorization: Bearer $BOUNCE_TOKEN" \
  -o budget-review.mp3 \
  https://192.168.1.42:8080/api/recordings/4C1F9B2A-7E30-4A6D-9C11-0B8E5D2F6A44/audio
```

**200** with `Content-Type: audio/mpeg` and `Accept-Ranges: bytes` for a whole
file. **206** with `Content-Range: bytes <start>-<end>/<size>` for a range
request — this is not optional politeness: Safari will not scrub an `<audio>`
element against a server that ignores `Range`, and the symptom looks like a
corrupt file rather than a missing header.

Single ranges only; `bytes=-500` (last 500 bytes) is understood. A multi-range
request is served as a full 200, which RFC 9110 permits.

Audio is always MP3, throughout the app, and that's load-bearing rather than
incidental — `AVAudioPlayer` must play it and `AVAudioFile` must read it for
transcription. Browsers playing it without transcoding is a free side effect.

**Errors:**

- **404** `{"error":"This recording hasn't been synced to the iPhone yet."}`
- **404** `{"error":"The audio file is missing."}` — the row references a file
  that isn't on disk, or is zero bytes.
- **416** with `Content-Range: bytes */<size>` and an empty body — the range
  starts past the end of the file.

---

#### `GET /api/recordings/<id>/waveform`

The amplitude envelope, for drawing a scrubber.

```json
[0, 3, 17, 42, 96, 120, 88, …]
```

**512 numbers, each 0–255**, one per bucket across the whole recording. Amplitude
is mapped through a square root rather than linearly — speech sits far below full
scale and a linear map draws a flat line.

Building an envelope is a full decode pass over the MP3, so the first request for
a recording can take a moment; it's cached on disk afterwards.

**Returns `[]` with status 200** when the recording has no audio — *not* a 404.
Worth knowing if you're switching on the status code.

---

#### `GET /api/recordings/<id>/ask?q=<question>`

Same streaming contract as [`GET /api/ask`](#get-apiaskqquestion), grounded on
this one recording instead of the library. The `sources` event is sent with an
empty array.

Adds one `unavailable` reason: `"This recording has no transcript yet."`

---

#### `POST /api/recordings/<id>/title`

Rename.

```bash
curl -k -H "Authorization: Bearer $BOUNCE_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"title":"Q3 budget review"}' \
  https://192.168.1.42:8080/api/recordings/4C1F9B2A-7E30-4A6D-9C11-0B8E5D2F6A44/title
```

Returns the full `WebRecordingDetail` as it now stands — every write route does,
so the client can replace its copy from the server rather than trusting its own
optimistic update. That's the cheapest workable answer to the phone and a
browser editing at the same time.

A user-set title is never overwritten by the AI titling pass afterwards.

**Errors:** **400** `{"error":"Missing title."}`.

---

#### `POST /api/recordings/<id>/speakers`

Name the diarized voices. Keys are the raw `speakerId`s from the detail payload.

```bash
curl -k -H "Authorization: Bearer $BOUNCE_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"names":{"1":"Dana","2":"Marcus"}}' \
  https://192.168.1.42:8080/api/recordings/4C1F9B2A-7E30-4A6D-9C11-0B8E5D2F6A44/speakers
```

The map **replaces** the stored one; it isn't merged. Send the full set. Values
that aren't strings are dropped. Returns the updated detail.

Names thread through display, share, and delivery, so this changes exported
transcripts too.

**Errors:** **400** `{"error":"Missing names."}`.

---

#### `POST /api/recordings/<id>/correct`

Replace a misheard word everywhere in the transcript.

```bash
curl -k -H "Authorization: Bearer $BOUNCE_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"from":"sonics","to":"Soniox"}' \
  https://192.168.1.42:8080/api/recordings/4C1F9B2A-7E30-4A6D-9C11-0B8E5D2F6A44/correct
```

| Field | Type | Default | |
|---|---|---|---|
| `from` | string | required | The word to replace. Word-boundary matched, so replacing `AI` doesn't touch `said` |
| `to` | string | required | The replacement |
| `caseSensitive` | bool | `false` | |
| `addToVocabulary` | bool | **`false`** | Also add `to` to the Soniox custom vocabulary, so future recordings get it right |

**`addToVocabulary` defaults off here while the phone's own sheet defaults it
on**, and that asymmetry is deliberate: a script correcting one word shouldn't
quietly reshape a transcription setting that affects every future recording.
Opting in is explicit over the wire.

The correction applies to the transcript *and* the archived live draft, and
leaves existing summaries alone — they were generated from the old text, and
regenerating them would be expensive and surprising.

Returns the updated detail. **Zero matches is a 200, not a 404** — a
correctly-executed replace that matched nothing is a successful request. If you
need the count, diff the returned transcript.

**Errors:**

- **400** `{"error":"Missing from/to."}`
- **400** `{"error":"“from” can't be empty."}` (note: curly quotes in the message)
- **409** `{"error":"This recording has no transcript to correct."}`

---

#### `POST /api/recordings/<id>/category`

Set or clear the category.

```bash
# Set
curl -k -H "Authorization: Bearer $BOUNCE_TOKEN" \
  -H 'Content-Type: application/json' -d '{"name":"Meeting"}' \
  https://192.168.1.42:8080/api/recordings/4C1F9B2A-7E30-4A6D-9C11-0B8E5D2F6A44/category

# Clear — an explicit JSON null
curl -k -H "Authorization: Bearer $BOUNCE_TOKEN" \
  -H 'Content-Type: application/json' -d '{"name":null}' \
  https://192.168.1.42:8080/api/recordings/4C1F9B2A-7E30-4A6D-9C11-0B8E5D2F6A44/category
```

**Matches on name, not id** (case-insensitively), because that's how the model
stores it. Get valid names from `GET /api/categories`. A name no category matches
is rejected rather than silently ignored, so a client can't toast "Saved" over a
write that never happened.

A consequence to be aware of: because recordings store the category *name*,
renaming a category on the phone detaches every recording tagged with the old
one.

Returns the updated detail.

**Errors:**

- **400** `{"error":"Missing name."}` — the `name` **key** is absent. An explicit
  `null` is the clear operation and is fine; omitting the key is the error.
- **400** `{"error":"No category by that name — it may have been renamed on the iPhone."}`

---

#### `POST /api/recordings/<id>/transcribe`

Queue a transcription.

```bash
curl -k -H "Authorization: Bearer $BOUNCE_TOKEN" \
  -H 'Content-Type: application/json' -d '{"force":true}' \
  https://192.168.1.42:8080/api/recordings/4C1F9B2A-7E30-4A6D-9C11-0B8E5D2F6A44/transcribe
```

`{"force": true}` re-transcribes a recording that already has a transcript;
without it, an already-transcribed recording is a no-op.

**Returns immediately** with `{"queued": true}` — transcription is a FIFO queue
that runs one recording at a time and can take minutes. Watch the `library`
event on `/api/live` and poll `/api/library` for the row's `status`.

**Errors:** **400** `{"error":"This recording hasn't been synced to the iPhone yet."}`.

---

#### `POST /api/recordings/<id>/summarize`

Generate one summary from one template.

```bash
curl -k -H "Authorization: Bearer $BOUNCE_TOKEN" \
  -H 'Content-Type: application/json' -d '{"templateId":"builtin.actions"}' \
  https://192.168.1.42:8080/api/recordings/4C1F9B2A-7E30-4A6D-9C11-0B8E5D2F6A44/summarize
```

**202** `{"started": true}`. Like transcription, this returns immediately;
generation runs on the on-device model and can take tens of seconds. The result
arrives in the recording's `summaries` array — watch the `library` event.

**Errors:**

- **400** `{"error":"Unknown template."}` — missing or unrecognised `templateId`.
- **400** `{"error":"This recording has no transcript to summarize."}`
- **409** `{"error":"That summary is already being generated."}` — one job per
  recording+template. Two clicks, or two clients, would otherwise start
  concurrent model sessions that also race the automatic organizing pass.
- **503** `{"error":"Apple Intelligence isn't available on this iPhone."}` — the
  on-device model only exists on capable hardware (A17 Pro / M1 and later) with
  the feature switched on. Without this check the request would return 202 and
  nothing would ever land.

---

#### `DELETE /api/recordings/<id>`

Delete the recording, its audio, and its waveform envelope. Irreversible — the
file is already gone from the recorder, since Bounce deletes it there once
downloaded.

```bash
curl -k -X DELETE -H "Authorization: Bearer $BOUNCE_TOKEN" \
  https://192.168.1.42:8080/api/recordings/4C1F9B2A-7E30-4A6D-9C11-0B8E5D2F6A44
```

```json
{ "deleted": true }
```

---

## The MCP server

> **Newly landed.** The endpoint compiles into the app and the wire layer has 133
> standalone checks (`tools/mcp-endpoint-tests/main.swift`), but it hasn't been
> exercised against a real MCP client on a real phone yet. Everything below is
> read from the shipped source. **Run `tools/list` against your own phone before
> wiring an agent up.**

Bounce exposes reads over the [Model Context
Protocol](https://modelcontextprotocol.io), so Claude Desktop and other agents
can query the library directly.

**Endpoint:** `POST /mcp`. JSON-RPC 2.0, behind the same four gates as every
other authenticated route — it is the one `POST` a bearer token may make (Gate 4). Authenticate with the bearer token — the session
cookie is a browser thing and an agent has no way to pair.

An MCP client needs nothing beyond the token to get past Gates 1 and 2 — see
[What each gate rejects](#what-each-gate-rejects) for why a script passes where a
browser page doesn't.

### Protocol

**MCP Streamable HTTP, legacy era, minus every optional part.** One JSON-RPC 2.0
message per `POST`, always answered as `application/json`. No SSE responses, no
`GET` stream, no resumability, and **`Mcp-Session-Id` is neither required nor
emitted**. The `MCP-Protocol-Version` request header is accepted and ignored, not
validated.

`POST /mcp` is the only method on that path. A `GET` or `DELETE` falls through the
router to `404 {"error":"No such endpoint."}`.

Versions: `initialize` echoes the client's requested version when it's one of
`2025-11-25`, `2025-06-18`, `2025-03-26`, `2024-11-05`, and otherwise answers
**`2025-11-25`** — which is also the answer when `protocolVersion` is missing.
That's the spec's rule: the same version if supported, another supported one if
not.

**The current MCP revision is `2026-07-28`, and it is a different protocol** — no
handshake, per-request `_meta`, a mandatory `server/discover`. Bounce implements
the legacy era deliberately, because that's what `mcp-remote` speaks.
`server/discover` returns `-32601`, which per the spec's compatibility matrix
makes a dual-era client correctly fall back to `initialize`.

The handshake result:

```json
{ "protocolVersion": "2025-11-25",
  "capabilities": { "tools": { "listChanged": false } },
  "serverInfo": { "name": "bounce", "title": "Bounce", "version": "1.0.0" },
  "instructions": "…" }
```

`resources` and `prompts` are absent because neither is served — advertising an
empty capability just invites a client to call `resources/list` and collect a
`-32601`. `listChanged: false` is honest rather than cautious: the endpoint
answers POSTs and holds nothing open, so there's no channel to push a change
notification down. `serverInfo.version` tracks *this MCP surface*, not the app, so
a stale cached `tools/list` can be spotted.

**Methods:** `initialize`, `ping` (empty result), `tools/list`, `tools/call`, and
**any** `notifications/*` — `initialized`, `cancelled`, and anything unrecognised
are all swallowed. Everything else gets `-32601`.

Two behaviours worth knowing:

- **It is stateless.** Nothing remembers that `initialize` happened, so
  `tools/list` and `tools/call` are answered whether or not a handshake preceded
  them. The auth gate decides who may call, not the handshake.
- **Notifications** — a message with no `id` — get **HTTP 202 with a completely
  empty body**, never a JSON-RPC response. Answering `notifications/initialized`
  with a result is the classic way to hang a client: it waits on a response id
  that will never come while holding one it never asked for.

### Results and errors

Every tool result is unstructured — one text content block, with `isError` always
present, on success too. There is **no `structuredContent` and no `outputSchema`**.

```json
{ "content": [ { "type": "text", "text": "…" } ], "isError": false }
```

What's *in* that text differs by tool. Pretty-printed JSON from
`list_recordings`, `search_recordings`, `get_summaries` and `list_action_items`;
**plain text** from `get_transcript` (a header block, then the timecoded
transcript with speaker names applied) and `ask`.

Errors split three ways, and the split is deliberate: protocol errors go to the
*client*, tool errors go to the *model* so it can correct itself.

**HTTP 401, and not a JSON-RPC envelope at all** — an unauthenticated request is
rejected by Gate 3 before the MCP layer ever parses the body, so you get the
server's ordinary error shape:

```json
{ "error": "Not paired with this iPhone." }
```

**This is deliberate, and it's the right layering.** Transport-level
authentication belongs at the transport level. The alternative — HTTP 200
carrying a JSON-RPC error — would disguise an authentication failure as a
successful HTTP exchange, which is worse for every client that has to
distinguish "your token is wrong" from "your call was wrong". An MCP client
speaking HTTP must check the status line first.

**HTTP 200 with a JSON-RPC `error` member** — the envelope was fine, the call
wasn't:

| Code | Cause |
|---|---|
| `-32601` | Unknown method, including `server/discover`, `resources/list`, `prompts/list` |
| `-32602` | Unknown tool (`Unknown tool: <name>`, the spec's own example for this case), missing or non-string `params.name`, non-object `params.arguments`, non-object `params` |
| `-32603` | Unexpected internal error |

**HTTP 400 with a JSON-RPC `error` member and a null `id`** — the body wasn't a
usable message:

| Code | Cause |
|---|---|
| `-32700` | Unparseable or empty body |
| `-32600` | Top-level array (**batching was removed from MCP in `2025-06-18`**), non-object message, missing or wrong `jsonrpc`, missing or empty `method` |

**HTTP 200, `isError: true`, no `error` member** — everything a model could fix,
or should simply be told. A missing recording (reported with the library's
recording count), an unknown category (reported with the known names), a
recording with no transcript or no summaries yet, a wrong argument type, an
unparseable `since`, a question over 500 characters — and **Apple Intelligence
being unavailable**, which comes back as the human-readable reason ("The
on-device model is still downloading…") rather than an error code, because a
model can act on that sentence and can't act on a `-32603`.

### The tools

**Everything is read-only, and that is the whole design.** No delete, no
re-transcribe, no delivery, no edit of any kind. The reasoning: the token that
reaches this endpoint is long-lived and sits in an agent's config file, and the
thing holding it is a language model acting on instructions that may themselves
have come out of a transcript. A confused or prompt-injected agent with a delete
tool costs the user their recordings; the same agent with only readers costs them
nothing it couldn't already read.

That's structural, not a promise. `MCPEndpoint` holds a narrow `MCPLibraryReading`
protocol rather than `AppModel`, so a write simply doesn't compile; the tool list
is an exhaustive enum switched in one place; and a tool can only return a
`String`.

Six tools. Every `inputSchema` is an object with `additionalProperties: false`,
so an unexpected argument is rejected rather than ignored.

| Tool | Parameter | Type | Required | Notes |
|---|---|---|---|---|
| `list_recordings` | `limit` | integer | no | 1–200, default **25**. Out-of-range values are **clamped, not rejected** |
| | `since` | string | no | ISO 8601 instant, **or** a bare `YYYY-MM-DD` read as midnight **UTC** — not local |
| | `category` | string | no | Category *name*, case-insensitive. An unknown name is a tool error listing the known ones |
| `get_transcript` | `id` | string | **yes** | |
| `search_recordings` | `query` | string | **yes** | Title-or-transcript substring, case-insensitive — the same predicate the Library screen uses |
| `get_summaries` | `id` | string | **yes** | |
| `list_action_items` | `open_only` | boolean | no | **Defaults to `true`** — open items only |
| `ask` | `question` | string | **yes** | `maxLength: 500` |
| | `id` | string | no | Omit to ask across the library |

What comes back:

| Tool | Returns |
|---|---|
| `list_recordings` | JSON: `total`, `returned`, and metadata rows. **Never transcript text** |
| `get_transcript` | Plain text: a header block (date, duration, category, tags, calendar event) then the timecoded transcript. Truncated at **200,000 characters** with a visible `[Truncated at …]` notice |
| `search_recordings` | JSON: at most **25** hits (alongside a `total` count), each with `matchedTitle` and a ~240-character `snippet` around the match |
| `get_summaries` | JSON: every generated summary, oldest first, with template name and text |
| `list_action_items` | JSON grouped by recording: `text`, `owner`, `due` **as spoken**, `atTimecode` |
| `ask` | Plain text: the answer, an `Answered from: <title> (<id>)` line, and a one-line caveat about the capped excerpt |

Notes that will save you a confused agent:

- **`list_recordings` returns metadata only** — id, title, date, duration,
  category, tags, word/speaker counts, which summaries exist, action-item counts.
  Get the id from here, then fetch the one recording you want.
- **A `category` that matches no category is an error, not an empty list**, and
  the error names the categories that do exist. "No recordings" and "no such
  category" lead a model to completely different next moves.
- **`due` is never resolved to a date.** It is the phrase as spoken — "by
  Friday" — because that phrase is all the evidence there is. Don't let an agent
  turn it into a calendar entry.
- **`ask` runs on the phone, and does not stream.** It collects the on-device
  model's output and returns one string. The calling agent may be a cloud model,
  but the answer is composed by Apple Intelligence on the iPhone over a capped
  excerpt, and **nothing is uploaded by `ask`** — every answer carries a line
  saying so. Requires Apple Intelligence; otherwise the tool fails with the
  reason as text.
- **Speaker labels are per recording.** `get_transcript` says so in its header
  when the transcript is diarized, because a model that assumes "Speaker 1" is
  the same person in two transcripts will attribute a quote to the wrong person.
- **A live preview is flagged.** Rows carry `isLivePreviewOnly` and transcripts
  carry a note, so a first draft isn't quoted as final.

To see exactly what your build exposes:

```bash
curl -k -X POST https://192.168.1.42:8080/mcp \
  -H "Authorization: Bearer $BOUNCE_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

### Claude Desktop configuration

Claude Desktop speaks MCP over stdio, so a remote HTTP endpoint needs a bridge.
`mcp-remote` is the usual one, and it's the client this endpoint was built
against — the legacy `initialize` handshake described above is what it speaks. It
needs two accommodations here: the bearer token, and the self-signed certificate.

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "bounce": {
      "command": "npx",
      "args": [
        "-y",
        "mcp-remote",
        "https://192.168.1.42:8080/mcp",
        "--header",
        "Authorization: Bearer ${BOUNCE_TOKEN}"
      ],
      "env": {
        "BOUNCE_TOKEN": "paste-your-token-here",
        "NODE_EXTRA_CA_CERTS": "/Users/you/.config/bounce/bounce.pem"
      }
    }
  }
}
```

Two notes on that block:

- **`NODE_EXTRA_CA_CERTS`** points at the certificate you saved with the
  `openssl s_client` command in [Deal with the certificate](#2-deal-with-the-certificate). This is the
  right way to do it: it trusts *that one* certificate rather than switching
  verification off globally, which is what `NODE_TLS_REJECT_UNAUTHORIZED=0`
  would do — for every server Node talks to, in every session.
- **The address is baked in.** When your phone's IP changes, this file and the
  pinned certificate both need updating. That is the cost of a server with no
  fixed name.

Restart Claude Desktop after editing. If the tools don't appear, the usual
causes in order: Bounce isn't running and on screen, the phone's IP changed, the
certificate wasn't trusted, or the token was revoked.

---

## Security notes

An honest account of what this does and doesn't protect.

### What the four gates defend against

**Gate 1, the `Host` allow-list, defends against DNS rebinding** — and this is
the non-obvious one. Without it, any website you visit can have its JavaScript
fetch `https://192.168.1.42:8080` from inside your own browser, carrying your
session cookie, and read your entire library back out to its own server. A token
does not stop this, because the browser attaches it automatically. Checking the
`Host` header does, because a malicious page can make your browser *connect*
somewhere but cannot make it *lie* about which host it asked for.

The allow-list deliberately does **not** accept any `.local` name by suffix. mDNS
names are claimed by whoever answers the multicast query, so a device on your
network could advertise `evil.local`, serve you a page, then re-point the name at
your phone — a rebind onto a host the check would have accepted. Only the real
Bonjour name is allowed, and it's added explicitly.

**Gate 2, the same-site check, defends against cross-site request forgery** —
specifically against a page you're visiting spending your pairing attempts. A
`text/plain` body makes a cross-origin POST a CORS "simple request", so there is
no preflight to block it, and five wrong guesses switches your server off. It
also stops a cross-origin page driving any write route.

**Gate 3, the credential, defends against everyone else on the network.**
Reaching the port is not the same as reading the library; the pairing code
requires physically holding the phone, and five wrong attempts stops the server
rather than merely locking out.

**Revocation has two shapes, and only one needed building.** Ordinary
request/response routes re-check the credential on every call — the keychain is
read per request with no cache — so they start refusing the instant a token is
revoked, with no bookkeeping anywhere. Long-lived SSE streams are the exception:
they're authenticated once, when they open, and never again. That's why each
stream is registered against the credential that opened it and revocation
explicitly closes it. A revocation control that leaves the revoked client still
receiving data isn't a control.

**Gates 1 and 2 still apply when you use a bearer token,** and that is not
redundancy for its own sake. The gates and the credential defend against
different attackers. A bearer token proves *the client knows a secret*; it says
nothing about *who is driving the client*. A web page you are browsing is a
client your browser will happily drive on someone else's behalf — with your
cookies attached automatically. The token doesn't change that, so removing
either gate would reopen exactly the hole it was built for.

### Why the MCP surface is read-only

An agent is a program that decides what to call based on text it read somewhere.
If some of that text came from a transcript, then **the transcript can influence
the call** — that's prompt injection, and a recording of a meeting is exactly the
kind of text a stranger can put words into. Read-only means the worst case is an
agent reading something it shouldn't have: bad, but bounded by what the token
already grants. Give the same agent a delete tool and the worst case is your
recordings.

The constraint is built into the types rather than left as a rule someone might
forget. `MCPEndpoint` is handed a two-property `MCPLibraryReading` protocol
instead of `AppModel`, so `delete` and `rename` don't exist to be called; the
tool list is an exhaustive enum, so a new tool won't compile until it's handled
everywhere; and a tool can only return a string. Adding a write tool would mean
widening that protocol first — a visible, deliberate act.

Tool descriptions do some steering too — `list_recordings` returns no transcript
text, `search_recordings` returns snippets, and the handshake `instructions` tell
the model not to page the library to build a copy of it. **None of that is
enforcement.** An agent with the token can read everything, one recording at a
time. That's what the token means, and it's why the section above says so
plainly.

The write routes still exist over plain HTTP for scripts you wrote yourself,
where you know what's issuing the request.

### What this is not proof against

- **An active attacker on your network.** TLS here is encryption without
  authentication. Someone who can redirect your traffic can present their own
  certificate, and your browser will show the same warning you've already
  learned to click past. Comparing the fingerprint by hand is the only defence,
  and it only works if you actually do it.
- **Anything running on your own machine.** A token in an environment variable
  is readable by every process running as you, and an agent's config file is a
  plain file on disk.
- **An agent you pointed at your own library.** Read-only bounds the damage to
  disclosure, not to nothing. Everything the token can reach, the agent can
  reach — and it may summarise a private meeting into a cloud model's context to
  answer a question you asked casually.
- **A compromised phone.** Everything above assumes the phone is trustworthy;
  the transcripts are sitting in its Documents directory either way.
- **You leaving it on.** The idle timeout and the foreground-only lifetime are
  there because a server left running on café wifi is the realistic failure, not
  a targeted attack. Switch it off when you're done.

---

## Related documents

- [`architecture.md`](architecture.md) — the desktop view's design, the threat
  model, and why the phone is the server.
- [`plans/desktop-web-view.md`](plans/desktop-web-view.md) — the original design
  of the server and client.
- [`plans/feedback-board-top-15.md`](plans/feedback-board-top-15.md) — Phase 5,
  which is where the API token and the MCP endpoint come from.
