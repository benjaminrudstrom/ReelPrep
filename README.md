# ReelPrep

Prepares vertical real-estate reels: clips cut on the beat of a song, logo intro and outro, slow motion
for 60 fps footage, stabilization, beat markers. It writes a project you open in your editor for the final
touches and the export (an FCPXML for Final Cut Pro, Final Cut Pro 7 XML for Premiere Pro or DaVinci Resolve),
or, for a reel that needs no grading, renders the video itself.

Status: **Step 3**: the app (start screen, clips, beats, cuts, reframing, export), plus the
command-line tool from Step 1.

## The app

```sh
scripts/make_app.sh                 # builds dist/ReelPrep.app
scripts/make_dmg.sh                 # dist/ReelPrep.dmg, Developer ID signed and notarized
open dist/ReelPrep.app
```

Needs macOS 14 or later on Apple Silicon and Xcode or the Command Line Tools (Swift 6); no other dependencies.
`scripts/make_dmg.sh` signs with your own Developer ID certificate when there is one, otherwise ad hoc.

To install: quit ReelPrep, then `ditto dist/ReelPrep.app /Applications/ReelPrep.app` (the build is ad-hoc signed,
for this Mac).

- **Drop** the clips, the song and the logo anywhere in the window, all at once or later, as files or
  folders. ReelPrep sorts them, fills the library and lays the clips on the timeline in capture order
  (later drops go to the end). It finds the beats and makes cached preview copies in place. The logo is
  remembered. "New Reel" starts over.
- **Library** (left): every clip; the badge is its cut. Right-click to leave a clip out, put it back, or
  remove it.
- **Timeline** (bottom), on one time scale:
  - **Logo layer:** the intro and outro logos. Drag their yellow edges to another beat; right-click to
    switch either off.
  - **Video track:** the cuts on the beats. Drag a cut's yellow right edge to snap it to another beat.
    Drag cuts to reorder, and drop library clips onto the track. ⌫ takes the selected cut out and leaves
    an empty slot; drop a clip into it (a cut dragged in from the timeline leaves an empty slot behind).
  - **Song:** half waveform with the beats.
  - **Controls:** drag the ruler or the red playhead to scrub, pinch to zoom, space to play the reel.
    ⌘Z undoes beat edits.
- **Selected cut** (middle): the clip's filmstrip with the yellow window to slide.
- **Preview** (right, 9:16): drag to pan, pinch to zoom, with the logo where it shows. Zoom and Tilt sliders sit under the clip in the centre. Tilt straightens
  a clip that is a degree or two off (slider, arrows in 0.1° steps, or rotate with two fingers; ±10°), with a
  level grid while tilting. The crop follows: the clip is scaled just enough that no corner shows.
  Effect: a slow zoom in or out over the whole cut (1-10 %, 3 % standard), played in the preview.
- **Open in Editor** (⌘E): writes the project (by default into the shoot folder) and opens it in the editor
  picked with the button's arrow (remembered): Final Cut Pro, Premiere Pro or DaVinci Resolve.
  - Final Cut Pro: an FCPXML, into the library you used last. Empty slots become gaps, the zoom effect is
    scale keyframes, every clip is stabilized.
  - Premiere Pro: a Final Cut Pro 7 XML, opened in the newest Premiere installed. Same cuts, slow motion,
    framing, zoom effect, logo, song and beat markers, but no stabilization (add Warp Stabilizer there).
    **Not yet tried in Premiere.**
  - DaVinci Resolve: the same XML; Resolve is started and the file shown, to bring in with
    File > Import > Timeline (Resolve doesn't import a file it is handed). **Not yet tried in Resolve.**
  - An editor that isn't installed: the file is written and shown in the Finder.
- **Export Video** (⇧⌘E): renders the reel to an .mp4 (1080×1920, 29.97 fps, H.264, SDR Rec. 709, the song
  fading over its last second) and shows it in the Finder. No stabilization or grading: that's what the editor
  is for. The command line does the same with `--render reel.mp4` (plus `--tilt` and `--zoom-effect`).

`open dist/ReelPrep.app --args <files…>` starts with those files, as if dropped.

## Beat editor

The song's waveform with its beats (corrected by hand, else Final Cut's Beat Detection, else ReelPrep's).
Space plays and pauses. T taps a beat at the playhead, snapped to the nearest attack. Click selects a
beat or moves the playhead, drag moves a beat, ⌥-click adds one, ⌫ deletes, ←/→ nudge 5 ms (⇧: one
frame), ⌘A then arrows shifts them all. Save (⌘S) stores the beats per song (by content, so renamed
copies count) in ~/Library/Application Support/ReelPrep/Beats; `reelprep` uses them from then on.
Revert goes back to the detected beats.

## Run it

Needs macOS 14+ and Swift (the Command Line Tools are enough). From this folder:

```sh
swift build -c release
.build/release/reelprep --clips ~/path/to/clips --song ~/path/to/song.mp3 --logo ~/path/to/logo.png --open
```

- `--clips` takes a folder (read one level deep) or clip files (.mov .mp4 .m4v). Clips are ordered
  by capture time. Other files are listed and left out.
- `--logo` is remembered, so you can leave it out next time.
- `--open` opens the result in Final Cut Pro, which imports it as a new event "ReelPrep" holding
  the project, into the library you used most recently (or `--library x.fcpbundle`, remembered),
  without asking which library. Without it the .fcpxml is written to the current folder (or `--out`).
- Cut lengths are fitted to the song so as many clips as possible get in: the beats left are shared
  over the clips left, each cut between about 1 s (`--min-cut`) and 4 beats (`-n`, remembered).
  `--fixed` cuts every exactly N beats instead. See `reelprep --help` for the rest:
  `--song-start-beat`, `--max-length`, `--intro-beats`, `--outro-beats`, `--beats`/`--write-beats`
  (correct the beat times by hand), `--no-stabilize`, and `--no-music`/`--no-logo`/`--no-retime`
  for tracking down import problems.
- Beats come from Final Cut Pro's own Beat Detection when it has run on the song (in any of your
  libraries; turn it on for the song in Final Cut once). Otherwise ReelPrep detects them itself
  (`--detect` forces that).
- Files with `%` in their names (some stock-music downloads have them) are handed to Final Cut as hard links
  with clean names in ~/Library/Application Support/ReelPrep/Links, because Final Cut freezes on
  `%`. Same file, no extra space, original untouched.

The CLI prints the clips it read (size, frame rate, date, device), the tempo, every cut and any
warnings, and validates the FCPXML against the DTD inside Final Cut Pro before writing.

## What the FCPXML contains

- Project 1080×1920, 29.97 fps, Rec. 709 (FCPXML 1.14, Final Cut Pro 12.4).
- The original files referenced in place. Nothing is copied or transcoded.
- Hard cuts on beats, with no transitions. Each clip's window is centred in the clip.
- 50/59.94/60 fps clips at 50 % speed (a `timeMap`), so a 1 s cut uses 0.5 s of footage. Other rates
  play at 100 % and Final Cut conforms 24/25 fps.
- Clips fill the frame (conform "fill"); position and scale come from the reframing (centred for now).
- Automatic stabilization on every clip. Clip sound muted (−96 dB).
- The song on its own lane from the first frame, trimmed to the reel, with a marker on every beat.
- The logo at 66 % of the frame width, centred: on screen from the first frame to the end of the
  first cut, and again from the start of the last cut to the end.

## Rules for the cuts (agreed 2026-11-10)

- A clip too short for its cut gets fewer whole beats. A clip that can't fill even one beat is
  skipped with a warning.
- The reel uses every clip until the song (or `--max-length`) runs out, and ends on the last full cut.
- Cuts can be as short as about 1 s so all clips fit (the user, 2026-11-10).
- The song starts at 0 s unless `--song-start-beat` says otherwise.

## Development

```sh
scripts/test.sh     # swift test (adds Swift Testing's path when only the Command Line Tools are installed)
scripts/make_app.sh # dist/ReelPrep.app (ad-hoc signed; the CLI goes in Contents/Helpers)
scripts/make_dmg.sh # dist/ReelPrep.dmg: signed with the Developer ID certificate (hardened runtime), notarized, stapled
.build/debug/reelprep-snapshot beats <song> out.png        # renders the beat editor to an image
.build/debug/reelprep-snapshot export out.fcpxml <files…>  # runs the app's export without a window
```

Modules: `FCPXMLKit` (FCPXML model, writer, DTD validation; no AVFoundation, no UI), `ReelCore` (cut
planning, beat editing), `ReelMedia` (metadata with AVFoundation, beat detection with Accelerate, Final
Cut's beats, the beat store, waveforms), `ReelUI` (SwiftUI views), `ReelPrepApp` (the app), `reelprep` (CLI).

## Licence

Copyright (C) 2026 Benjamin Rudström

ReelPrep is free software: you can redistribute it and/or modify it under the terms of the GNU General Public
License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any
later version. It is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the
implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See [LICENSE](LICENSE) for the full text.
