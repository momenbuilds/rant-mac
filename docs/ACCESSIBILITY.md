# Accessibility

Rant is a tool for people who would rather talk than type. Some of them cannot type
comfortably at all, which makes accessibility a core requirement rather than a
compliance exercise.

## What is built in

**Reduce Motion is honoured in one place.** `Theme.animation(_:reduceMotion:)` returns
`nil` when the setting is on, so every animated view gets the behaviour by asking
rather than by remembering. The recording pulse is the one piece of motion that
carries information — you need it to know the microphone is live — so with Reduce
Motion on it is replaced by a static ring instead of simply disappearing.

**The overlay is one VoiceOver element.** It announces what is happening
("Rant is listening. Release your dictation key to insert, or press Escape to
cancel."), not twenty-six waveform bars. `accessibilityElement(children: .ignore)`
plus an explicit label.

**Colour is never the only signal.** Every state in the overlay carries an icon and a
word alongside its colour: a green tick and "Inserted", a red triangle and
"Something went wrong".

**Nothing is trapped behind a permission.** Every onboarding step can be skipped. A
denied permission shows a button that opens the exact System Settings pane rather than
telling you to go and find it.

**Full keyboard operation.** The app is a standard `NavigationSplitView` with standard
controls, so tabbing and arrow keys work as they do everywhere else. Dictation itself
has menu commands (⇧⌘D start/stop, ⌥⇧⌘V paste last) so it never depends on the global
event tap being installed.

**Text scales.** No fixed font sizes in the main window; everything uses semantic text
styles, so Larger Text applies.

## Manual audit

Automated checks cannot tell you whether VoiceOver output is *comprehensible*. Run
this before a release.

### VoiceOver (⌘F5)

- [ ] The sidebar announces each destination and its selected state
- [ ] Home reads greeting, then statistics with their labels, then history
- [ ] Each history row reads its text, then when it was dictated, then which app
- [ ] The overlay announces state changes as they happen, without repeating itself
- [ ] The overlay does **not** steal VoiceOver focus from the app being dictated into
- [ ] Every button has a label that says what it does, not what it looks like
- [ ] Settings toggles announce their current state and their explanatory footer

### Keyboard only (no trackpad)

- [ ] Full Keyboard Access (System Settings → Keyboard) reaches every control
- [ ] Onboarding can be completed end to end — Tab, Space, Return
- [ ] A dictionary entry can be added and saved
- [ ] Focus is visible at every step
- [ ] Escape closes each sheet
- [ ] No control is reachable only by clicking

### Reduce Motion

- [ ] Nothing animates in the main window
- [ ] The overlay's recording indicator shows a static ring rather than a pulse
- [ ] The waveform still moves — it is data, not decoration — but does not spring

### Increase Contrast / Reduce Transparency

- [ ] The overlay stays readable when its material becomes opaque
- [ ] Card borders remain visible
- [ ] The accent colour keeps sufficient contrast in both light and dark

### Larger Text

- [ ] Home, History and Settings reflow without clipping at the largest size
- [ ] The overlay truncates the transcript preview rather than growing past its panel

### Colour vision

- [ ] Every success/error state is distinguishable in greyscale
      (`Display → Color Filters → Grayscale`)

## Known gaps

- **The floating overlay cannot be reached by keyboard**, deliberately: it is a
  non-activating panel, because taking focus would move the cursor away from the field
  you are dictating into. Everything it offers is also on the menu bar and in the
  Dictation menu, and Escape always cancels.
- Full Keyboard Access has not yet been audited on every Settings pane. Tracked in
  `TASKS.md` as RANT-067.
