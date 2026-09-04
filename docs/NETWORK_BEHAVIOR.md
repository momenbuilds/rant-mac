# Network behaviour

Every outbound request Rant is capable of making. If you find network traffic from
Rant that is not on this list, that is a bug — please file it.

## With default settings and no API key

**None.** Rant makes no network request at all. There is no license check, no
update ping, no analytics beacon, no crash upload. No analytics or crash-reporting
SDK is linked into the binary.

## Speech, when the AssemblyAI provider is selected

| When | Request | Carries |
|---|---|---|
| recording starts | `GET https://dictation.assemblyai.com/` | nothing — an unauthenticated throwaway to pre-open the TLS connection so the real request does not pay DNS+TCP+TLS. Discarded. |
| recording ends | `POST https://dictation.assemblyai.com/transcribe` | the recorded audio as raw 16 kHz mono PCM, plus a JSON `config` part |
| streaming enabled | `wss://streaming.assemblyai.com/v3/ws` | the same audio, framed live, for partial display |

The `config` part may contain, and **only** contain:

- `sample_rate`, `channels` — audio description
- `conversation_context` — your recent Rant dictations and the text immediately
  before the cursor, oldest first, capped at 4096 characters
- `word_boost` — your dictionary key terms, capped at 2048 characters
- `llm.instruction` — the cleanup instruction for the requested cleanup level

The application name, window title, focused-field label, selected text, clipboard,
OCR text and IDE symbols are used **on-device only** and are never placed in this
request. That boundary is enforced in one function, `OutboundContext.wireTurns`,
so it can be read and tested in one place.

Before anything is placed in `conversation_context` it passes through
`SecretRedactor`, which replaces credential-shaped strings (API keys, bearer
tokens, private key blocks, long random hex/base64 runs) with `[redacted]`.

## Speech, when the on-device engine is selected

**No network request, and nothing to download.** `AppleSpeechProvider` uses the
recogniser already present in macOS with `requiresOnDeviceRecognition` set, and the
provider checks that the recogniser genuinely supports on-device work for the language
before handing it any audio.

The important part is what happens when it does not: the request is **refused**. The
`Speech` framework would otherwise satisfy it over Apple's servers, and doing that
while the UI says "Audio stays on this Mac" would be a lie told by the app rather than
a limitation of the platform. You get
`onDeviceRecognitionUnavailable` instead, naming the language.

This engine holds no transport of any kind, which is the same reasoning
`LocalWhisperProvider` was written with: "makes no network request" is a claim best
kept by having nothing present that *could* make one.

## Speech, when a downloaded local model is selected

**No network request.** Audio does not leave the machine. Selecting "Local only"
disables cloud fallback entirely — a provider failure surfaces as an error rather
than silently reaching for the network.

Model weights are downloaded once, on explicit user action:

| When | Request | Carries |
|---|---|---|
| you press Download on a local model | `GET https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-*.bin` | nothing but the request itself — no key, no identifier, no telemetry |

The exact URL, the file size and the RAM the model needs are shown before the
download starts, and nothing is fetched until you press the button. The download is
verified by size and by GGML/GGUF magic bytes, which catches both a truncated
transfer and a captive portal's HTML page saved under a `.bin` name.

This is the only host Rant contacts that is not your chosen speech provider, and it
is contacted only when you ask for an offline model. Once downloaded, the local
provider makes no network requests at all.

## Enhancement, when enabled

| Provider | Endpoint | Carries |
|---|---|---|
| None (default) | — | — |
| Apple Foundation Models | on-device | nothing leaves |
| Ollama | `http://localhost:11434` (configurable) | transcript + prompt, to your machine |
| OpenAI-compatible | the base URL you enter | transcript + prompt + redacted context |

The last row is the only case where a remote party other than your chosen speech
provider sees your text. The UI labels it as such at the point of selection, not in
a help article.

## Listening, rather than sending: the local MCP server

Off by default. When you switch it on in Settings → Integrations, Rant opens a socket
so local MCP clients — Claude Code, Cursor, anything that speaks the protocol — can
query the data you have exposed.

| | |
|---|---|
| Direction | **inbound only.** Rant never dials out for this |
| Address | loopback, `127.0.0.1` by default |
| Reachable from another machine | **no** |
| Exposes | only the collections you tick, one at a time. Nothing is exposed by default |
| Exposes API keys | never — no tool reads the Keychain |
| Audit | every request is written to a local audit table you can read in Settings |

The loopback restriction is enforced by construction rather than by a setting.
`MCPBindAddress` refuses any host outside `127.0.0.0/8` and `::1` — including
`0.0.0.0` and `::`, the two spellings of "every interface" people reach for first —
and it throws before a socket is allocated, so a misconfiguration cannot become a
listening port on your network.

## Reading your calendar

`EventKitCalendar` reads a bounded window of events around the current time, through
EventKit, after you grant permission. It is a local database read: no request leaves
the machine, and the calendar is never uploaded. The event title and its join link are
used to name a meeting; nothing else is copied.

## Never

- No request contains an API key belonging to anyone but you.
- No request goes to a Rant-operated server. There is no Rant server.
- No update check unless you press "Check for updates".
- Calendar data, meeting audio, screen contents, clipboard and file paths are never
  uploaded by the dictation path.

## Verifying this yourself

```
# every URL literal in the engine
grep -rnoE 'https?://[^"]+' Sources/ | sort -u
```

`scripts/check.sh` runs an assertion that the set of hosts appearing in `Sources/`
is a subset of the hosts documented here, so this file cannot silently drift.
