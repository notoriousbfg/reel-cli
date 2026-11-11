# reel

Screen recordings for promo material, driven entirely from the command line, so
an agent can record, inspect and edit footage for Mac apps and websites.

- **Record** one app window with ScreenCaptureKit (no other apps, notifications or desktop).
- **Edit** with flags: trim, crop, zoom (fixed point, cursor-following or auto-on-click),
  speed, transitions, fades, padded backgrounds with rounded corners and shadow.
- **Inspect** with JSON metadata, single frames and timestamped contact sheets, so an agent
  can *look* at footage and the edit before exporting.

No ffmpeg. It uses only Apple frameworks (ScreenCaptureKit, AVFoundation, Core Image).

## Permissions

| Command | Needs |
|---|---|
| `edit`, `info`, `frame`, `sheet`, `changes`, `cursor`, `mark`, `run`*, `stop`, `doctor` | nothing |
| `record`, `windows` | Screen Recording (granted to your terminal) |
| `locate`, `act`, `record --ax-snapshots` | **optional:** Accessibility as well |

\* `run` needs whatever its scene's `record` step needs.

Recording and editing never need Accessibility, Input Monitoring or Automation;
only the three optional commands above do. Click/cursor
tracking polls the pointer state, which macOS allows without an event tap. Window
capture also keeps other apps out of frame. If you'd rather not grant Screen
Recording at all, record with ⌘⇧5 and use `reel` purely for editing (you lose
the click data that powers `--auto-zoom` and `@cursor`).

While recording, macOS shows a purple capture pill in place of the window's traffic
lights. Crop past the title bar with `--crop 0,56,<width>,<height − 56>` (sizes from `reel info`)
if you don't want it in shot.

## Install

```sh
swift build -c release
cp .build/release/reel ~/.local/bin/     # or any directory on your PATH
```

Requires macOS 15+.

## Workflow

```sh
# 1. Record (Ctrl-C, `reel stop`, --duration or --until-exit to finish)
reel record --app Grasmere --launch --no-cursor --countdown 3 --duration 25 -o raw.mov
reel record --app Safari --open http://localhost:3000 -o site.mov          # websites
reel record --app build/Debug/Grasmere.app --new-instance --env DEMO=1 \
  --args "-AppleLanguages (en)" --until-exit --quit-after -o raw.mov       # driven by a test harness
reel mark saved                          # from the harness, while recording

# 2. Look at it
reel info raw.mov                        # duration, size, clicks, markers (JSON)
reel sheet raw.mov --every 1 --grid -o sheet.png
reel sheet raw.mov --at 5.5,25.3 --crop 50%,0,50%,40% -o detail.png
reel changes raw.mov                     # when and where the picture changes

# 3. Check the edit as stills
reel edit raw.mov:1.2-22 --preset promo --cursor 1.8 \
  --zoom src:12.2-22.5:rect=0.28,0.1,0.48,0.5 --preview-at 3,8,12 -o check.png

# 4. Export
reel edit raw.mov:1.2-22 … -o promo.mp4

# Or describe the whole take once and re-run it
reel run scene.json                      # record + edit
reel run scene.json --edit-only --preview check.png
```

`reel help formats` documents every JSON file: the events sidecar, cursor
scripts, presets and scene files.

## Edit reference

| Flag | Meaning |
|---|---|
| `clip.mov:START-END` | trim (seconds; either side optional) |
| `--crop x,y,w,h` | source pixels, or `%`; `N=` targets clip N |
| `--zoom S-E:SCALE@X,Y` | zoom to a point (output time, normalized **output** coords) |
| `--zoom src:S-E:SCALE@X,Y` | the same in **source** time and source coords, so re-trimming needs no arithmetic |
| `--zoom src:S-E:rect=X,Y,W,H` | fit a source region (scale computed, max 3×), e.g. a box from `reel changes` |
| `--zoom mark-a..mark-b+0.5:SCALE@…` | between markers (source time) |
| `--zoom …@cursor` | follow the smoothed cursor |
| `--auto-zoom SCALE` | one zoom per burst of clicks |
| `--zoom-ease SEC` | ease in/out time (default 0.6). Zooms that touch pan instead of zooming out |
| `--transition KIND[:SEC]` | `cut crossfade fade slide-left/right/up/down wipe zoom`; `N=` targets join N |
| `--speed X` | playback speed; `N=` targets clip N |
| `--size WxH` | output canvas (default: cropped size + padding) |
| `--padding --background --corner-radius --shadow` | promo-style framing; two colors = gradient |
| `--cursor SCALE` | draw the real macOS cursor (arrow, I-beam, hand, crosshair) from the events, smoothly, with a halo on clicks (`--no-click-effect`). Record with `--no-cursor` so it isn't doubled |
| `--cursor-script moves.json` | author the cursor track instead of recording it (moves, clicks, drags, shapes; times can name markers) |
| `--events file.json` | use another events file; the recorded sidecar is never modified |
| `--preset NAME` | settings from `~/.config/reel/presets.json` or `./reel.json`; flags override |
| `--fade-in --fade-out` | to/from black |
| `--codec hevc\|h264` | output codec (default hevc) |
| `--preview-at T[,T…]` / `--preview-sheet` | render PNG(s) of the edit instead of exporting |
| `--dry-run` | print the resolved timeline as JSON |

Without `src:`, zoom and fade times are on the **output** timeline (after trims,
speed and transition overlaps). Use `--dry-run` to see `clipStarts`.

### Cursor scripts

When an app is driven by a test harness rather than the mouse, write the cursor
instead of generating thousands of samples:

```json
[
  {"at": 0, "move": [0.5, 0.6], "over": 0},
  {"at": "open-palette", "move": [0.435, 0.025], "over": 0.8},
  {"at": "open-palette+0.05", "click": true},
  {"at": 14.6, "drag": [[0.352, 0.37], [0.545, 0.37]], "over": 1.0},
  {"at": 15.8, "shape": "ibeam"}
]
```

Moves ease in and out and arrive at `at`; drags are linear with the button held.
Coordinates are 0–1, or `"640pt"` / `"1280px"`. `reel cursor raw.mov --script
moves.json` writes an events file you can inspect; `edit --cursor-script` uses it
directly.

### Optional: element lookup and real input (Accessibility)

```sh
reel locate --app Safari --label "Highlight" --role button   # frame + centre, 0–1 of the window
reel locate --window-id 22987 --list                         # every labelled element

reel record --app Safari --window-title "My app" --ax-snapshots -o raw.mov &
reel act --script demo.json        # performs the script for real on the recording's clock
reel stop
```

Script steps can name elements instead of coordinates:
`{"at": 2, "click": {"label": "Highlight", "role": "button"}}`. `reel act` finds
them live; drawing (`--cursor-script`) finds them in the snapshots `--ax-snapshots`
stored at the start and at each marker. `act` also understands `type`, `key`
(`"cmd+s"`), `scroll` and `"count": 2`. It takes over the pointer and **aborts the
moment you move the mouse or press Esc** (exit code 2), releasing any held button.

### Not supported

`--window-size` is left out on purpose: resizing another app's window needs
Accessibility permission. Size the window in the app (or its launch arguments)
instead.

## Library

`ReelKit` exposes the same pieces (`Recorder`, `Planner`, `Composer`, `Exporter`,
`Stills`, `Inspect`) for use from Swift.

## Agent skill

`skills/reel/SKILL.md` teaches a coding agent the look → edit → verify loop.
Copy it to `~/.claude/skills/reel/` (or a project's `.claude/skills/`).
