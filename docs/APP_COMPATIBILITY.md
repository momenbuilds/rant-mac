# Application compatibility

Text insertion is the part of Rant that cannot be fully automated, because it depends
on how each application implements Accessibility — and many implement it partially,
inconsistently, or not at all.

Rant tries two strategies in order:

1. **Accessibility** — set `AXSelectedText` on the focused element. Instant, no
   keystrokes synthesised, clipboard untouched.
2. **Clipboard + ⌘V** — save what you had copied, write the transcript, synthesise
   ⌘V, then restore after the paste has settled.

A ✅ in the *Direct* column means strategy 1 works. Strategy 2 works essentially
everywhere and is the reason there are no ❌ rows in *Works*.

## Matrix

Test with `bash scripts/smoke-test.sh`, which walks you through each app and records
the result. Please update this table when you find something new, including **how** it
misbehaves — "does not work" is not a bug report.

| Application | Works | Direct | Clipboard preserved | Notes |
|---|---|---|---|---|
| TextEdit | ⬜ | ⬜ | ⬜ | reference case for plain `NSTextView` |
| Notes | ⬜ | ⬜ | ⬜ | |
| Mail | ⬜ | ⬜ | ⬜ | |
| Messages | ⬜ | ⬜ | ⬜ | |
| Safari — plain input | ⬜ | ⬜ | ⬜ | |
| Safari — contenteditable | ⬜ | ⬜ | ⬜ | rich editors often refuse `AXSelectedText` |
| Chrome — plain input | ⬜ | ⬜ | ⬜ | |
| Chrome — Gmail compose | ⬜ | ⬜ | ⬜ | |
| Terminal | ⬜ | ⬜ | ⬜ | expect clipboard path; check no stray newline |
| iTerm2 | ⬜ | ⬜ | ⬜ | |
| Xcode editor | ⬜ | ⬜ | ⬜ | check identifier casing survives |
| VS Code | ⬜ | ⬜ | ⬜ | Electron; usually clipboard path |
| Cursor | ⬜ | ⬜ | ⬜ | check the AI chat input specifically |
| Slack | ⬜ | ⬜ | ⬜ | check it does not send on paste |
| Discord | ⬜ | ⬜ | ⬜ | |
| Notion | ⬜ | ⬜ | ⬜ | block editor; watch for lost leading space |
| Obsidian | ⬜ | ⬜ | ⬜ | |
| Figma | ⬜ | ⬜ | ⬜ | canvas app; text tool only |
| 1Password | 🚫 | 🚫 | — | **refused by design** — see below |

Legend: ✅ works · ⚠️ works with caveats · ❌ broken · 🚫 deliberately refused · ⬜ untested

## Deliberate refusals

Rant will not read from or type into a secure text field (`AXSecureTextField` /
`AXSecureTextArea`), and password managers are in the default context-exclusion list.
There is no setting to change this. If you find a way to make Rant type into a
password field, that is a security bug — see `SECURITY.md`.

## Known-hard categories

**Electron apps** (VS Code, Slack, Discord, Notion) usually expose a partial
Accessibility tree. Expect the clipboard path. The thing to check is not whether text
arrives, but whether your previous clipboard comes back afterwards.

**Rich-text and block editors** (Notion, Google Docs, contenteditable) often accept
the paste but apply their own spacing rules on top of ours. Watch for a doubled or
missing leading space.

**Terminals** are the case where cleanup matters more than insertion: a "helpfully"
added full stop turns a working command into a broken one. That is why Terminal mode
sets cleanup to `none`.

**Canvas apps** (Figma, games) have no text field to find. Rant should leave the text
on the clipboard and say so rather than appearing to succeed.

## If insertion fails

Rant never drops the text. On failure it stays on the clipboard and the overlay says
so — the transcript you just spoke is not worth losing to a misbehaving text field.
