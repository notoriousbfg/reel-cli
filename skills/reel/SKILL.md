---
name: reel
description: Record and edit polished screen recordings of Mac apps or websites with the `reel` CLI (window capture, trim, crop, zoom, transitions, styled backgrounds). Use when the user wants a demo video, promo clip, or screen recording edited.
---

# Making screen recordings with `reel`

`reel` prints JSON on stdout and progress on stderr. Run `reel <cmd> --help` for every flag.

## 1. Record

- Check `reel doctor` first. If `screenRecording` is false, ask the user to grant
  Screen Recording to their terminal, or to record with ⌘⇧5 and give you the file.
- `reel windows --app <name>` lists candidate windows.
- `reel record --app <name|bundle id> [--launch] [--open URL] --countdown 3 --duration N -o raw.mov`
  - The user usually performs the actions. Tell them what to do and when it starts.
  - For open-ended takes, run it in the background without `--duration`, then `reel stop`.
  - A `raw.events.json` sidecar (cursor + clicks) is written next to the video. Keep it with the file.
  - For promo footage, record with `--no-cursor` and add `--cursor 1.8` at edit time: the real
    macOS cursor, larger and smooth, with click halos. The captured cursor is tiny on Retina.
  - Pass the `.app` path to record that exact build (e.g. an Xcode Debug build) even when another
    copy is running. `--new-instance --env K=V --args "…" --until-exit --quit-after` let a test
    harness drive the take; the JSON result includes `pid` and `windowID`.
  - If you control the harness, call `reel mark <step-name>` as each step happens. Markers become
    time references everywhere (`"at": "step+0.2"`, `--zoom step-a..step-b:1.7@…`).

## 2. Look before editing

You cannot watch video, so look at images:

- `reel info raw.mov` gives duration, size and `events.clicks` (source time, normalized x/y).
- `reel sheet raw.mov --every 1 --grid -o sheet.png`, then read the PNG. Clicks are circled
  red. The yellow grid is in 10% steps, so you can read coordinates off it.
- `reel frame raw.mov --at 4.2 --crop 50%,0,50%,40% -o f.png` to read small text.
- `reel sheet raw.mov --at 5.5,25.3 -o s.png` for exact moments.
- `reel changes raw.mov` lists when and where the screen changes (start/end, box). Use it to
  time cursor scripts and zooms instead of guessing; a `box` drops straight into `rect=`.

Find dead time at the start and end (to trim), UI chrome to crop (title bars, the
Dock), and the moments worth zooming into.

While a window is being captured, macOS replaces its traffic lights with a purple
capture pill (usually from the second frame on). Crop past the title bar, e.g.
`--crop 0,56,<width>,<height − 56>` (numbers from `reel info`) in source pixels, unless you want the window chrome in shot.

## 3. Draft the edit as stills

Iterate with `--preview-sheet --grid` (or `--preview-at T`) instead of exporting:

```sh
reel edit raw.mov:1.5-20 --crop … --zoom 3-6:2@0.72,0.18 \
  --padding 96 --background '#0f2027,#2c5364' --corner-radius 24 --shadow \
  --fade-in 0.4 --fade-out 0.6 --preview-sheet --every 0.5 --grid -o check.png
```

Prefer source-relative zooms; they survive re-trimming:
`--zoom src:12.2-15:rect=0.28,0.1,0.48,0.5` (fit a region) or `--zoom src:4-8:2@0.7,0.3`.

When the app was driven by a harness (no real mouse), write a cursor script
(`reel help formats`) and pass `--cursor-script moves.json --cursor 1.8`. Use
`"shape": "ibeam"` over text fields. Warnings about overlapping steps mean a move
was delayed; fix the times.

Optional, needs Accessibility (`reel doctor` shows `accessibility`):
- `reel locate --app X --label "Save" --role button` gives element centres for scripts and zooms.
- `{"label": "Save"}` works anywhere a script takes `[x, y]`; record with `--ax-snapshots` so
  drawing can resolve it.
- `reel act --script s.json` during `reel record` performs the script with real input (true hover,
  selection and drag states). Ask the user first: it takes over their pointer, and it aborts if
  they touch the mouse.

Batches: put shared styling in `./reel.json` presets (`--preset promo`), or a whole
take in a scene file and iterate with `reel run scene.json --edit-only --preview check.png`.

Rules that avoid common mistakes:
- Without `src:`, zoom/fade times are on the **output** timeline. After trimming `raw.mov:1.5-20`, the
  source moment t=4.0 is output t=2.5. Use `--dry-run` to confirm `clipStarts`.
- Zoom X,Y are normalized to the **output** frame. Read them from a preview sheet
  (with padding/crop applied), not from the raw sheet.
- `--crop` is in **source** pixels (or %).
- Prefer `--auto-zoom 1.8` or `@cursor` when there is click data. Keep scale 1.5–2.2
  and zooms at least 1.5s long. Back-to-back zooms that touch pan smoothly.
- Corner radius ≈ 1–2% of output width looks native. Window captures may have dark
  corners, so `--corner-radius` with `--padding` hides them.

## 4. Export and verify

`reel edit … -o promo.mp4` (add `--h264` for maximum compatibility, e.g. some web
players or social uploads). Then `reel sheet promo.mp4 --every 1` and look at it
before reporting back to the user.
