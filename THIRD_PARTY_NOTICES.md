# Third-party notices

Rant links no third-party runtime dependencies. It uses Apple system frameworks and
the system SQLite. This file records intellectual attribution, which is owed
regardless of whether code was copied.

## Blurt — MIT

<https://github.com/AssemblyAI/blurt> · Copyright (c) 2026 Alex Kroman

Rant's AssemblyAI dictation client implements the same HTTP contract that Blurt
documents: the `POST https://dictation.assemblyai.com/transcribe` endpoint, the
`audio` + `config` multipart framing, and the `sample_rate` / `channels` /
`conversation_context` / `word_boost` / `llm.instruction` config keys with the
`text` / `llm_response` / `llm_error` response shape.

That is a description of a third party's wire protocol rather than creative
expression, and Rant's implementation is independently written. The attribution is
recorded anyway because Blurt is where we learned it, and its MIT licence text is
reproduced below.

```
MIT License

Copyright (c) 2026 Alex Kroman

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## VoiceInk — GPLv3, NOT used

<https://github.com/Beingpax/VoiceInk>

VoiceInk is licensed GPLv3, which is incompatible with Rant's MIT licence in the
copy direction. **No VoiceInk source code, in original or translated form, is
present in this repository.** Its public documentation informed our understanding
of what features a modes-based dictation app should have. Ideas and observed
behaviour are not copyrightable; the code was not copied. See `docs/DECISIONS.md`
D-001 and the licence boundary section of `docs/COMPETITOR_AUDIT.md`.

## Wispr Flow, Superwhisper — proprietary, NOT used

No code, artwork, branding, icon, sound, string or layout from either product
appears in Rant. They were studied as products through their public marketing and
documentation only.

## Models

Local speech models (whisper.cpp GGUF weights) are downloaded by the user at
runtime from the source shown in the UI and are not redistributed with Rant. Their
own licences apply.
