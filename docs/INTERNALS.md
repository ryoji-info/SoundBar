# SoundBar internals

Install steps and everyday usage are in the top-level [README](../README.md); this document is the
technical deep-dive: how the audio capture, Touch Bar drawing and gesture reading actually work, and
the measurements behind the design decisions.

SoundBar is a single background agent that draws an audio visualiser on the Touch Bar while sound is
playing or a microphone is live, and hands the strip back to **BetterTouchTool** (or macOS) the rest
of the time. Everything happens in one app: no second menu bar icon, no window that flashes on screen.

- Source: `Sources/SoundBar/` (17 Swift files)
- Installed: `/Applications/SoundBar.app`
- Login agent: `~/Library/LaunchAgents/com.ryoji.SoundBar.plist`
- Log: `~/Library/Logs/SoundBar/SoundBar.log`

All measurements quoted in this document were taken on a 13-inch MacBook Pro (M2, 2022, Mac14,7);
absolute numbers will differ on the M1 model, the mechanisms will not.

## Why a process tap, not a loopback device

The traditional way for an app to hear the system mix is to install a loopback (BlackHole,
Soundflower) or build an aggregate device and **make it the system default output**. Aggregates expose
no volume control, so every visualiser built that way pays the same price while it runs:

- the F11/F12 keys and the menu bar volume slider do nothing;
- any in-app volume gesture writing to that same aggregate does nothing either;
- the user's default output device is silently switched back and forth.

SoundBar instead captures audio with a CoreAudio **process tap** (macOS 14.2+) carried by a *private*
aggregate device. Measured across a full cycle: default output stays `MacBook Pro Speakers (id 92)`
before, during and after. Nothing is switched, so the volume keys simply keep working, and no
third-party driver is ever installed.

Cost, measured: **~0 % CPU idle, 2.9–4.4 % while visualising** at the default 20 fps, ~46 MB — the
range covering the cheapest pattern (Spectrum Bars) and the dearest (Spectrum Blocks). Capture and the
render loop only exist while the visualiser is on screen, and a frame that would look identical to the
last one is skipped, so quiet passages cost nothing.

Three things were worth optimising, each measured rather than assumed:

- **Per-frame colour construction.** The renderer rebuilt 88 `NSColor`s and bridged each to `CGColor`
  every frame. Caching them by palette and count took Spectrum Bars from 4.0 % to 2.9 %.
- **The dot matrix.** One `fillEllipse` per dot was 835 calls a frame and **16 %** on its own. Batching
  those ellipses into one path per row made it *worse*, **41 %**, because filling a path of 167
  subpaths is expensive. Square pixels through the batched `fill(_ rects:)` API brought it to **3.9 %**
  — and square pixels read as an LED sign anyway, which is the look.
- **The analyser buffer.** At 4096 points, slicing an `Array` per FFT allocated 16 KB ~47 times a
  second and `removeFirst` was an O(n) memmove on every hop. Both are now index-based.

(An earlier single-pattern version drew with one `CALayer` per bar and cost 0.4–0.7 %. Patterns
with different geometry need real drawing; the cost turned out to be per-frame in AppKit's redisplay
path rather than per-pixel — halving the backing scale changed nothing, while frame rate scales it
almost linearly: 30 fps ≈ 4.9 %, 20 ≈ 3.2 %, 12 ≈ 2.1 %. Hence 20 as the default.)

## How it works

| Piece | File | Notes |
|---|---|---|
| Detects audio activity | `AudioActivityMonitor.swift` | Per-process CoreAudio objects, event-driven |
| Captures the audio | `SystemAudioTap.swift` | Global process tap in a private aggregate |
| Captures the mic | `MicrophoneCapture.swift` | Runs alongside the tap whenever `inputMode` calls for it |
| Turns audio into bars | `SpectrumAnalyzer.swift` | 4096-pt vDSP FFT, log-spaced 20 Hz–20 kHz bands |
| Draws the frame | `VisualizerView.swift` | Skips redraws when the picture is static |
| The eleven patterns | `VisualStyles.swift` | Spectrum ×7, waveform, VU ×3 |
| Colour ramps | `PaletteLibrary.swift` | Built-ins + imported AVTouchBar colour sets |
| Owns the Touch Bar | `TouchBarVisualizer.swift` | Private `NSTouchBar` presentation |
| Reads Touch Bar touches | `MultitouchTouchBarSource.swift` | Private MultitouchSupport, no permission |
| Recognises gestures | `TouchBarGestures.swift` | Tap, long press, slide-to-volume |
| Sets the volume | `VolumeController.swift` | Resolves through aggregates to real hardware |
| Decides when | `Coordinator.swift` | Debounce, minimum on-time, manual override |
| Checks BTT | `BTTController.swift` | Live `BTTTouchBarVisible` flag |

### Telling real playback from system sounds

Every alert, notification and UI sound on macOS is rendered by one helper, `systemsoundserverd`, which
appears in the audio process list only while the sound lasts. Measured:

```
0.09s OUT={com.apple.Music}
1.14s OUT={com.apple.Music, systemsoundserverd}   <- `beep`
1.42s OUT={com.apple.Music}
```

Excluding that one process separates alerts from media exactly, with no duration heuristics. The
device-level alternative cannot: on this Mac the default output and default *system* output are the
same device.

Microphone detection is judged per *device*, not per process, because the default input may well be a
virtual loopback (BlackHole, say) rather than the mic. A device counts as a real microphone only if it
has input channels and its transport is neither `virt` (a loopback) nor `grup` (an aggregate) — which
on a Touch Bar MacBook resolves to `MacBook Pro Microphone`.

### Three findings that cost real time, recorded so they are not rediscovered

1. **`CATapDescription.isExclusive` must not be set.** `initStereoGlobalTapButExcludeProcesses` sets it
   `true`, which is what makes `processes` an *exclude* list, i.e. "tap everything". Setting it `false`
   inverts the meaning to "tap only the listed processes" — and with an empty list that is nothing.
   The tap is created, the aggregate reports 2 input channels, and every sample is zero.
2. **The IOProc queue must be `nil`.** `AudioDeviceCreateIOProcIDWithBlock` accepts an explicit dispatch
   queue and returns `noErr`, but the block is then never invoked. Measured: 0 callbacks with a queue,
   ~93/s with `nil`.
3. **The aggregate must be private.** A *public* aggregate carrying the same tap reports 0 input
   channels and delivers silence. `kAudioAggregateDeviceIsPrivateKey` is load-bearing, not cosmetic —
   and it is also what guarantees the device can never become anyone's default output.

### Showing the microphone

A call is the case that matters: Zoom (or Meet, or FaceTime) holds an **output** stream open for the
whole call *and* uses the mic, so both read as active at once. The original rule — show the mic only
when nothing is playing — therefore never fired, and your own voice was never visible.

`inputMode` decides what happens when both are live:

| Mode | Behaviour |
|---|---|
| `off` | Never show the mic; always the system output |
| `auto` | Mic only when nothing is playing to the output (the original behaviour) |
| `mix` | **Default.** Blend the two whenever both are live |
| `input` | Mic wins whenever it is live, even over playback |

Pick it from **Behaviour ▸ Input Meter** in the menu. Switching applies immediately — the coordinator
re-syncs captures on a settings change rather than waiting for the next track.

Only the captures a mode actually needs are run: in `input`, the output tap is torn down while the mic
is live and restarted when it stops. Verified in the log — `tap: system audio tap running` →
`mic: capturing` + `tap: stopped and torn down` → mic released → `tap: system audio tap running`.

**Blending.** Spectrum bands and meter levels take the *louder* of the two rather than a sum: both are
already normalised 0…1, so adding them would peg the display whenever both sources were merely
present. The waveform is genuinely summed and then clamped, because that is what mixing two signals
does. A voice sits well below music in level, so `inputGain` is there to even the two up.

**A latent bug this exposed.** Levels are only ever written inside `analyse()`, and `appendSilence()`
was never called — so an analyser whose capture stopped kept its last frame *forever*. That was
invisible while exactly one source was ever read, but a blend would have mixed live audio with a frozen
ghost of whatever had stopped. Both captures now `reset()` their analyser on stop, and the reset is
ordered *after* `AudioDeviceStop`/`DestroyIOProcID` so it can never race a live IOProc.

**Migration.** `inputMode` supersedes the old `visualiseMicrophone` boolean. If that was explicitly set
to `false` before this existed, it still wins and resolves to `off`, so an existing preference is not
silently reversed by the upgrade; choosing any mode from the menu clears it.

### Visual patterns

Eleven patterns, cycled by a **two-finger tap** on the Touch Bar or picked from the menu:

| Pattern | What it shows |
|---|---|
| Spectrum Bars | Classic analyser, bars rising from the baseline |
| Spectrum Bars ×2 | The same, at twice the bands and a much tighter gap |
| Spectrum Mirror | The same spectrum mirrored about the centre line |
| Spectrum Mirror ×2 | The mirror, at twice the bands |
| Spectrum Blocks | Segmented LED ladder, five segments per bar |
| Spectrum Peaks | Dimmed bars with a cap that hangs at the recent maximum, then falls |
| Retro Dot LED | Dot-matrix panel of square pixels; unlit ones stay faintly visible, like lamps that are off |
| Waveform | Oscilloscope trace of the live signal |
| VU Meter | Left and right meters with held peaks and dB ticks at −30, −20, −12, −6 |
| VU Inward | Left channel on the left half, right on the right, each filling from its outer edge towards the centre |
| VU Outward | Same split, each channel filling from the centre out to its own edge |

The ×2 patterns ask the analyser for twice as many bands (88 rather than 44) and use their own slot
fill — at 88 bands each slot is only ~11 pt wide, so the normal 0.62 fill would leave hairlines. They
use 0.88, which puts a ~1.4 pt gap between bars.

The dot matrix uses its own square lattice rather than one column per frequency band: tying the columns
to `barCount` left 25 pt gaps between 4 pt dots, which read as specks instead of a panel.

The two symmetric meters carry no channel lettering: the split at the centre line already says which
half is which, and on a 30 pt strip the letters were clutter sitting on top of the meter. The stacked
**VU Meter** keeps a small L/R in its left gutter, where a stacked meter conventionally has it.

In the two symmetric meters the strip is split down the middle and **the left half is the left channel,
the right half is the right channel**, each using the full height. The centre is the boundary between
them rather than a shared origin both channels straddle: `outward` anchors each channel at that
boundary and grows towards its own outer edge, `inward` anchors each at its outer edge and grows
towards the boundary, so a loud passage closes in on the middle. The ramp always runs from a channel's
own zero point to its far end, so both halves read identically whichever way they travel.

The meters fill with a single `CGGradient` pass clipped to the level. Building the fill out of small
coloured slices instead — the obvious approach — leaves visible seams where each slice antialiases
against the next.

The VU meter is a real averaging meter, not a peak meter: the level integrates with a ~130 ms time
constant so it swings like a needle rather than flickering, and the white peak marker holds for 1.1 s
before sliding back. Its window is −42…−3 dBFS.

The choice persists, so the pattern you leave it on is the one you get next time.

`--render-preview` draws every pattern to a PNG without needing a Touch Bar, which is how the layouts
were checked (`--zoom 5` for a close look, `--ramp` for a clean left-to-right test signal).

### Shaping the response

Two knobs sit between the FFT and the bar heights, and they do different jobs.

**`frequencyTilt`** (dB per octave, default `3`) rotates the spectrum about a 1 kHz pivot before each
band is mapped onto a bar: bands above the pivot are lifted, bands below are cut. Music carries most of
its energy in the bass, so an untilted display leans heavily left and the treble end barely moves.
Measured on one passage, as the ratio of lit pixels in the right third of the strip to the left third:

| tilt | treble/bass |
|---|---|
| `0` | 0.27 |
| `3` | 0.75 |
| `6` | 1.59 |

`+6` is exactly *level × frequency* — each doubling of frequency doubles the amplitude — but it
overshoots flat into treble-dominance. `+3` measures closest to even, which is why it is the default.

**`levelBoost`** (dB, default `12`) is a flat lift that slides the whole display window down over the
signal, so quiet material fills more of the strip: mean bar height went 16 → 22 px of the 30 pt strip,
with peaks still short of the ceiling.

It deliberately does **not** apply to the VU styles. Their window is 37 dB against the bars' 54 and
they sit closer to the ceiling for ordinary music, so the same +12 pinned both channels at 100 % and
the meter stopped moving altogether. VU sensitivity is `vuFloor`'s job instead — and note its
direction: *lowering* it widens the scale and the meter reads fuller.

Both are cosmetic. Neither touches playback nor what is captured.

### Colours

Nine ramps are built in: Rainbow (the default), Green, Spectrum, Ice, Ember, Meter, Mono, Sakura, Fable
Computer — *Meter* is the classic green/amber/red ladder, which suits the VU; *Sakura* and *Fable
Computer* were originally AVTouchBar colour sets, hand-transcribed into `PaletteLibrary.builtIns` from
their decoded stops so they ship with the app rather than depending on an import. Beyond those, any
other AVTouchBar colour sets found in
`~/Downloads/AVTouchBar Custom Colors` are imported automatically and copied to
`~/Library/Application Support/SoundBar/Colors` so they survive Downloads being cleared.

AVTouchBar writes each set as JSON with `NSKeyedArchiver`-encoded colours. Unusually the archive keeps
the components in its `$top` dictionary rather than as an object, so the normal unarchiver returns
nothing — the sRGB triplet is read out of `$top["NSRGB"]` directly. Drop any further sets into either
folder and they appear on the next launch.

### Frequency range

The bands span **20 Hz to 20 kHz**, log-spaced, and the band edges are computed as frequencies and then
converted to FFT bins — not by log-spacing bin indices, which is what makes the range mean something in
Hz.

Reaching 20 Hz is why the FFT is **4096 points**. At 48 kHz that gives 11.7 Hz bins; the previous 1024
points gave 46.9 Hz bins and therefore had no data at all below ~47 Hz, whatever the band maths asked
for. The window is correspondingly longer (85 ms), with a half-window hop so a new spectrum still
arrives every ~43 ms — ahead of the 50 ms render at 20 fps.

At the very bottom the maths wants finer resolution than any FFT of this length has: the first few
bands come out under one bin wide, so they are clamped to advance by at least one bin and step 11.7 Hz
at a time instead of following the log curve exactly. The lowest band starts at the bin that *contains*
20 Hz (centre 23.4 Hz) rather than the one below it — bin 1 is centred at 11.7 Hz, and rumble and DC
leakage there would keep the first bar permanently lit.

Measured band starts, 44 bands at 48 kHz: 23, 35, 47, 59, 70 … 633 … 3551 … 17098 Hz, with the last
band running up to the top bin.

### The visible width is not 1085 pt

AppKit hands the touch bar item a **1085 pt** view — the full 2170 × 60 px panel at 2× — and reports
that width back. But the strip does not show all of it: the right-hand end is clipped.

This surfaced as "the L label appears but the R one never does". The R label was being drawn, 11 pt
from the right edge; it was simply off the visible area, while L at 3 pt from the left survived. (Those
labels have since been removed, but the clipping they exposed was the real problem.)

`--ruler` was added to measure it: a scale on the Touch Bar with a tick every 25 pt and numbers every
100. Measured on this machine — the `1000` label starts at x = 1002, and only the left half of its
first digit is visible. That puts the edge at roughly **1005 pt**, so about 80 pt — 7 % of the strip —
is not shown. `usableWidth` defaults to 1000, the round number safely inside that.

Every pattern now draws into that width instead of 1085, which matters beyond the label: without it the
top frequency bars, the outer end of the right meter, and any peak marker near full scale were all
being lost. The view is deliberately left at 1085 pt so it stays aligned with the left edge; the
unused strip at the right is painted black.

If a finer measurement ever shows more room, raise it — no rebuild needed:

```bash
defaults write com.ryoji.SoundBar usableWidth -float 1005
```

### Touch Bar gestures

The Touch Bar is a multi-touch digitiser separate from the trackpad, and it reports contacts even while
another app draws on the strip. Measured: family 176, **232.1 × 8.1 mm** (trackpad is family 113,
127.4 × 77.6 mm), so the device is chosen by aspect ratio rather than a hardcoded id. Reading it needs
**no permission at all**.

| Gesture | Condition | Action |
|---|---|---|
| One-finger tap | 1 finger, < 300 ms, ≤ 4 mm, no second tap follows | next colour |
| One-finger double tap | two such taps within 320 ms | mute / unmute |
| Two-finger tap | 2 fingers, < 300 ms, ≤ 4 mm | next pattern |
| Long press | 1 finger, ≥ 450 ms, ≤ 4 mm | stop the visualiser |
| Slide | 1 finger, > 5 mm of travel | volume, ±1 step per 14.5 mm |

Recognition works on *touch sessions* — from the first finger landing to the last one lifting — rather
than per contact. Deciding at the end of a session is what makes the one- and two-finger taps cleanly
separable, because only then is the highest simultaneous finger count known.

The gestures cannot collide: a tap must lift before 300 ms, a long press only fires after 450 ms, and
any real movement arms the slide and disqualifies both. A single tap is necessarily delayed by the
320 ms double-tap window, since it cannot fire until it is known no second tap is coming.

Only `x` is used — the digitiser has two sensor rows across 8.1 mm, so `y` is too coarse to threshold
on. Measured on a real finger: `single tap (67 ms, 0.2 mm) -> colour 'Ocean Blue'`.

## Permissions

| Permission | Needed for | Required? |
|---|---|---|
| Screen & System Audio Recording | The system audio tap | **Yes** — `coreaudiod` performs the check, not SoundBar; deny it and the tap delivers silent zeros. No screen content is ever read |
| Microphone | Visualising mic input, and the tap | **Yes** for the tap; also whenever `inputMode` is not `off` |
| Accessibility | — | Not needed |
| Input Monitoring | — | Not needed; MultitouchSupport does not require it |
| Automation | Naming BTT's Touch Bar group | Optional, cosmetic only |

`coreaudiod` was observed checking `kTCCServiceMicrophone`, `kTCCServiceScreenCapture` and
`kTCCServiceAudioCapture` against SoundBar when the tap is created. If the visualiser shows a flat line
while audio plays, that is the grant to check.

> **Rebuilding invalidates TCC grants.** The app is ad-hoc signed (no Developer ID), so its designated
> requirement is cdhash-only (`codesign -d -r- /Applications/SoundBar.app`) and grants are keyed to that
> exact code hash. Any build whose binary or `Info.plist` changed produces a new cdhash; a rebuild from
> unchanged sources is reproducible and keeps the grants. If a permission looks enabled but nothing
> works, remove `SoundBar` from the list with `−` and re-add it.

## Settings

Every tunable is a `defaults` key in `com.ryoji.SoundBar`, re-read live:

```bash
defaults write com.ryoji.SoundBar paletteName -string rainbow
```

| Key | Default | Meaning |
|---|---|---|
| `enabled` | `true` | Master switch; stays running but does nothing when off |
| `watchOutput` | `true` | React to playback |
| `watchInput` | `true` | React to microphones |
| `fullscreen` | `true` | Cover the whole strip (no control strip) |
| `startDelay` | `0.7` | Seconds of audio before starting |
| `stopDelay` | `3.0` | Seconds of silence before stopping — absorbs gaps between tracks |
| `minOnDuration` | `2.0` | Never show the visualiser for less than this |
| `ignoreSystemSounds` | `true` | Exclude `systemsoundserverd` and the MagSafe chime |
| `barCount` | `44` | Bars across the strip |
| `barWidthFraction` | `0.62` | Bar width vs gap |
| `fineBarWidthFraction` | `0.88` | Bar width vs gap for the ×2 patterns |
| `paletteName` | `Rainbow` | Any ramp from `--list-palettes` (case-insensitive) |
| `style` | `bars` | `bars`, `barsFine`, `mirror`, `mirrorFine`, `blocks`, `peaks`, `dots`, `wave`, `vu`, `vuInward`, `vuOutward` |
| `tapCyclesStyle` | `true` | Taps change colour (one finger) and pattern (two fingers) |
| `doubleTapMutes` | `true` | A one-finger double tap mutes |
| `keepTouchBarAwake` | `false` | Best-effort anti-dim; does not work on this macOS (see above) |
| `frequencyTilt` | `3` | dB per octave about a 1 kHz pivot, applied before a band becomes a bar (±12) |
| `levelBoost` | `12` | Flat cosmetic dB gain for the bars — **not** the VU (±24) |
| `vuFloor` | `-40` | dB the VU styles read as empty; the ceiling is fixed at −3 dBFS |
| `showMenuBarItem` | `true` | Show the menu bar icon |
| `frameRate` | `20` | Redraw rate while visualising (10–60) |
| `usableWidth` | `1000` | Visible width of the Touch Bar in points (the view is 1085 but clips at ~1005) |
| `inputMode` | `mix` | What a live mic shows: `off`, `auto`, `mix`, `input` (see below) |
| `inputGain` | `1.0` | Multiplies the mic's contribution before mixing (0.1–8) |
| `longPressStopsATB` | `true` | Long press stops the visualiser (legacy key name) |
| `longPressDuration` | `0.45` | Seconds |
| `longPressMaxDrift` | `4.0` | Millimetres still counted as a stationary press |
| `slideVolume` | `true` | Slide controls volume |
| `checkBTTAfterStop` | `true` | Verify BetterTouchTool got the strip back |
| `extraExcludedBundleIDs` | — | Apps whose audio should not count |
| `verboseLogging` | `false` | Debug detail in the log |

## The menu bar item

The icon shows state at a glance: solid while visualising, dim when idle, `waveform.slash` when
SoundBar is switched off, and a crossed-out speaker when the output is muted. Its tooltip names the
current pattern and colour.

The menu leads with the two things that change most — **Pattern ▸** and **Colour ▸**, each a submenu
with a checkmark on the current choice, and each colour carrying a swatch drawn from its own ramp.
Below that:

- **Turn SoundBar On / Off** (in bold) — the way back if the visualiser has been switched off, which
  matters because the Touch Bar long press can stop it and there should be a route back that does not
  involve the terminal.
- **Start / Stop Visualiser Now**, and **Mute Output**.
- **Behaviour ▸** — fullscreen, start on playback, start on microphone, and **Input Meter ▸** (Off /
  Auto / Mix / Input Only — see *Showing the microphone*).
- **Touch Bar Gestures ▸** — a reminder of what each gesture does, with a switch for each.
- Whatever is currently counted as playing, click-to-ignore.

Set `showMenuBarItem` to `false` if you would rather have no menu bar presence at all.

## App icon

`Resources/AppIcon.icns` — a Touch Bar–shaped pill with a row of dots pulsing across it, sized like
the app's own retro-LED pattern. Rendered as a real macOS icon (a proper squircle mask, not a
circular-arc rounded rect) natively at all ten sizes `iconutil` needs, rather than downsampled from
one master, so the pill's hairline rim stays crisp down to 32 pt.

The rendering source (`design/icon-render.swift`) is a standalone Core Graphics tool — it also
produced several other concepts and variations along the way, kept there in case the icon is
revisited:

```bash
cd design
swiftc -O -sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macos14.4 \
  -framework AppKit -framework CoreGraphics -framework CoreImage -o iconrender icon-render.swift
./iconrender .                       # writes SoundBar.iconset/ among other outputs
iconutil -c icns SoundBar.iconset -o ../Resources/AppIcon.icns
```

SoundBar is `LSUIElement`, so this icon never appears in the Dock while running — only in Finder,
Spotlight, and Get Info. `build.sh` copies it in and sets `CFBundleIconFile`.

## Building and diagnostics

```bash
cd ~/Developer/SoundBar
./scripts/build.sh            # build to ./build/SoundBar.app
./scripts/build.sh --install  # install to /Applications and (re)start the login agent
```

Command Line Tools only — no Xcode, no SwiftPM. Private APIs are declared in `Sources/SoundBar/Private.h`
and pulled in with `-import-objc-header`.

```bash
/Applications/SoundBar.app/Contents/MacOS/SoundBar --help
```

| Flag | Does |
|---|---|
| `--selftest` | 60 s interactive check of long press, slide-volume and mic detection |
| `--visualizer-test` | Test pattern on the Touch Bar (`--windowed`, `--seconds N`) |
| `--tap-test` | Capture system audio, print band levels, prove default output is untouched |
| `--watch-touches` | Print Touch Bar contacts (`--raw` for hex frames) |
| `--check-btt` | Ask whether BetterTouchTool has the Touch Bar |
| `--list-palettes` | List every colour ramp with a swatch |
| `--render-preview P` | Draw every pattern to PNG `P` (`--palette`, `--ramp`, `--zoom N`) |
| `--visualizer-test --cycle` | Tour every pattern on the Touch Bar |

## Touch Bar dimming (unresolved)

macOS dims the Touch Bar after ~60 s and switches it off ~15 s later. This is driven by **input**
idle — keyboard, trackpad, or strip touches — and *drawing* on the strip does not count as activity,
so the visualiser fades to black mid-song with your hands off the keyboard.

This could not be fixed from a user-space, ad-hoc-signed background agent. Everything below was built
and measured on this machine; none kept the strip lit:

| Approach | Result |
|---|---|
| `DFRFoundationPostEventWithMouseActivity` (Touch-Bar-local synthetic event) | strip dims on schedule |
| `IOHIDPostEvent` `NX_NULLEVENT` | resets system `HIDIdleTime` (127 s → 1.5 s) — strip still dims |
| `IOHIDPostEvent` `NX_MOUSEMOVED`, and `CGEvent` `.mouseMoved` | no effect on the strip |
| `DFRSetDimmingStep` / `DFRDSetDimmingStep` (every signature) | dimmed bezel stayed at 0.800 |
| A dimming preference | none exists in `com.apple.touchbar.agent` / `com.apple.TouchBarServer` |

`TouchBarServer` watches a hardware multitouch/HID activity path (its own state names it
`mtCounterDomain` / `_isUserActive`) that synthetic events from another process do not reach.
Defeating it would require disabling SIP, which is out of scope.

**BetterTouchTool can't do it either.** Checked exhaustively (its full predefined-action table, every
`BTTTouchBar*` preference key, its scripting dictionary, all localisation strings, and the binary's DFR
imports): BTT has no anti-dim setting, action, or preference, and imports no power-assertion / caffeinate
API. Its only strip-touching primitive is the same `DFRFoundationPostEventWithMouseActivity` poke proven
ineffective above, called only to synthesize taps — not on a keep-alive timer. And decisively,
TouchBarServer's client-callable RPC surface is exactly `ClientSetFlags`, `ClientSetSystemModal`,
`SetColorTemperature`, `SetFlags`, `ShmemMap` — the `disableDimming` / `dimToStep:` machinery is internal
to the server, callable by no client. The dim decision genuinely lives where no app can reach it.

The `keepTouchBarAwake` setting and its menu item remain, **off by default**. When on, the tick uses
only the Touch-Bar-local DFR post, which — unlike a system HID event — does **not** reset
`HIDIdleTime`, so it never keeps the display awake or blocks the screensaver. It simply doesn't defeat
the dimming today; it's left in so it starts working with no rebuild if a future macOS honours it.
(An earlier `CGEvent`-based attempt *did* have a display-sleep side effect with no benefit, and was
removed.)

While the option is off, nothing is posted at all: `Coordinator.settingsChanged` calls
`TouchBarVisualizer.refreshKeepAwake`, which tears the 25 s ticker down the moment the box is
unchecked rather than leaving it firing no-op ticks until the next present, and starts it again the
moment it is re-checked while the strip is up.

## Known limits

- **Apps that hold an output stream open while idle** keep the visualiser awake. There is no way to tell
  "stream open" from "audio audible" without measuring the signal; enable the menu bar item and use its
  click-to-ignore list, or add the bundle id to `extraExcludedBundleIDs`.
- **Private API.** The Touch Bar presentation (`NSTouchBar.presentSystemModalTouchBar:…`) and
  MultitouchSupport are both unofficial. Every entry point is probed before use and failure degrades to
  "no visualiser" rather than a crash, but a macOS update could break either.
- **The BetterTouchTool check is a weak signal.** BTT's `BTTTouchBarVisible` property does not move
  when SoundBar itself presents. Since SoundBar dismisses its own Touch Bar it already knows it
  released the strip, so the check is belt-and-braces rather than the primary signal.
- **`y` on the Touch Bar is unusable** for gestures (two sensor rows over 8.1 mm), so gestures are
  horizontal only.
