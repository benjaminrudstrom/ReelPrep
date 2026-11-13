# Decisions

Newest at the end.

## 2026-11-10 — Step 1, CLI proof of concept

Answers from the user:
- Final Cut Pro 12.4. No reference FCPXML yet, so the output is FCPXML 1.14 (the newest DTD in FCP 12.4),
  validated against `FCPXMLv1_14.dtd` read in place from the app bundle. Match it to an exported reel
  project once one is available.
- Timeline 29.97 fps (not exactly 30): iPhone and DJI footage is 29.97/59.94. 50/59.94/60 fps play at 50 %.
  24/25 fps play at 100 % and Final Cut conforms them.
- Intro logo to the end of the first cut; outro logo from the start of the last cut (overridable in beats).
- A clip too short for its cut is shortened to fewer whole beats, or skipped if it can't fill one.
- Song from 0 s, with an option to start on a chosen beat. The reel is as long as the clips and the song allow.
- Clip sound is always muted (−96 dB on every clip; it stays there to raise in FCP).

Choices made here:
- Video cuts go in the primary storyline. The song is connected to the first cut on lane −1 and runs
  the whole reel. Beat markers sit on the song clip (song time), so they move with the music.
  Logos are connected stills on lane 1.
- Retime: a two-point `timeMap` from the asset start, so (start, start) → (start + duration/speed,
  start + duration). The clip's `start` is in retimed time. This follows how Final Cut exports retimes,
  as far as known without a reference file. **It's the first thing to check in the import test**, along
  with the vertical format name `FFVideoFormat1080x1920p2997`.
- Asset start = the file's timecode (first tmcd sample) when it has one, so in-points match Final Cut's clip time.
- Beat tracking: spectral flux onsets (vDSP FFT), tempo from autocorrelation weighted towards 120 BPM,
  dynamic programming with a Gaussian-smoothed local score. Tightness 1600: at the textbook 100 it slipped
  to the off-beat around section changes (4–8 bad intervals per song on four sample songs). At 400 one song
  still slipped once; at 1600 none did. Produced music keeps one tempo, and hand correction (Step 2) covers the rest.
- Tests use Swift Testing. Without Xcode its framework path has to be passed, which `scripts/test.sh` does.

## 2026-11-10 — First import test, fitted cut lengths

- The first real import (14 iPhone 17 Pro 4K60 HLG clips) froze Final Cut Pro at "importing remote
  resources". The song's file name contained a literal `%20`, giving `%2520` in the URL. With the song
  renamed it imported fine, and the user says it looks good. So the retime, vertical format, logo and
  markers work as written. The CLI now refuses file names with `%` and asks for a rename.
- The 15 s song preview fades out from ~9.5 s, and the tracker stopped at 10.8 s (22 beats). Beats now
  continue at the tracked tempo before the first and after the last tracked beat while the audio is above
  2 % of the song's median RMS (about -34 dB): 30 beats, to 14.8 s.
- With 4-beat cuts only 5 of 14 clips fitted. The user: cuts can be down to about 1 s. Default is now
  fitted: each cut gets the beats left shared over the clips left, between ceil(0.9 × 1 s / beat) beats and
  N (default 4). The first cut starts at frame 1, not on a beat, so it is checked in seconds too.
  `--fixed` keeps the old every-N behaviour. That shoot: all 14 clips, 1.0–1.5 s each, 14.8 s.

## 2026-11-10 — Final Cut's beats, "%" file names

- The user: beat detection wasn't great on the first shoot's song (cuts slightly early or late). Final Cut's
  Beat Detection (which the user finds decent) says 88.8 BPM, beats every 0.676 s from 0 s; ReelPrep said
  118.8 BPM, a 4:3 mismatch, so its grid drifted in and out of the music.
- FCPXML 1.14 has nothing for beats (no element, no import option), and Final Cut's detector is a private
  framework inside its bundle (MusicUnderstandingEmbedded), not something to load. But Final Cut keeps the
  results per media file in the library: `__.fcpdata.apple.com/media_metadata/<id>/<id>_beatDetectionResults.dat`,
  a keyed archive of {time, timescale, type} (1 beat, 2 bar, 4 section, 8 tempo). The event's
  `CurrentVersion.fcpevent` stores "Original Media/<name>" next to the id. "Original Media" holds a symlink
  (or a copy) per file. ReelPrep finds the song there by file identity (device + inode, so links count) or
  name + size for copies, reads the id from the database bytes (never opened as a database), and uses those
  beats. Its own detector is the fallback (`--detect` forces it). The newest analysis wins if several
  libraries have one. This layout is Final Cut Pro 12.4's, not documented, so it could change.
- With those beats (0.676 s), about 1 s minimum means 2-beat (1.35 s) cuts: 11 of 14 clips in 14.9 s.
- The user: "%" file names should just work. Final Cut freezes on them (`%2520` in the URL), so they go to
  Final Cut as hard links with decoded names in ~/Library/Application Support/ReelPrep/Links/<hash of path>/
  (copies for small files on other drives). Final Cut's sandbox reads any path (absolute-path exception "/").

## 2026-11-10 — Import straight into a library

- Final Cut asked "Which library do you want to import … into?" on every import, with an empty recent
  list. The FCPXML now wraps the event in `<library location="file:///…/x.fcpbundle/">`, so Final Cut
  imports into that library without asking. Default: the most recently modified library (found as for
  the beat grid); `--library` picks one and is remembered. The user judged v3 (Final Cut's beats, 2-beat
  cuts, 11 of 14 clips) "ace".
- A test crash (signal 11 in the timeline test) was a stale incremental debug build after the timeline type
  grew a field; `swift package clean` fixed it.

## 2026-11-10 — Step 2: beat editor

- Hand-corrected beats are stored per song by content hash (SHA-256 of the file) in
  ~/Library/Application Support/ReelPrep/Beats, so renamed or copied songs find them and the CLI and app
  share them. Beat source order: --beats file, corrected, Final Cut's Beat Detection, ReelPrep's detector.
- Tapping (T) snaps to the strongest onset within 80 ms, since taps land late. Nudge is 5 ms, or one
  29.97 frame with ⇧. Beats closer than 50 ms are one beat.
- The app is built with SwiftPM and the Command Line Tools (no Xcode): scripts/make_app.sh assembles
  dist/ReelPrep.app by hand. Two traps: "reelprep" and "ReelPrep" are the same name on APFS, so the CLI
  lives in Contents/Helpers; and a path after the program name is taken by AppKit as an "open file"
  event, after which SwiftUI opens no window at all. NSTreatUnknownArgumentsAsOpen = NO fixes that.

## 2026-11-10 — Step 3: the app

- Phases: start screen (gate), loading (metadata, beats, proxies), editor. Overrides are kept per clip URL,
  so reordering keeps them. In-points are clamped to fit when cut lengths change. Settings (N, minimum cut,
  fixed) are remembered. The app shares UserDefaults with the CLI (bundle id com.reelprep.ReelPrep), so the
  logo is remembered across both.
- Reframing: zoom on top of Final Cut's "fill" (1–3×), pan clamped so the clip always covers the frame.
  Exported as adjust-transform: scale = zoom, position = offset / frame height × 100, y up. (The percent-of-
  height unit is how FCPXML positions work as far as known. Check in Final Cut that an exported pan matches
  the preview.)
- Proxies: AVAssetExportPreset960x540 H.264 in ~/Library/Caches/ReelPrep/Proxies, three at a time, about
  4 s per 10 s 4K clip. Preview only: the FCPXML always uses the originals.
- Library discovery is Spotlight only. Walking ~/Pictures took minutes in the photo archive, and in the app
  even a two-level walk hung on a macOS privacy prompt (TCC) for another folder.
- ImageRenderer can't draw AppKit-backed views (lists, scroll and split views, AVPlayerLayer), so UI checks
  launch the app (`--continue`) and capture its window with `screencapture -l`.

## 2026-11-10 — Editor reworked with the user

- One timeline: logo layer, video track and half waveform on one time scale. Cuts snap to beats: an edge
  drag sets the cut's length in beats (planner `beatCounts`), and the cuts after it re-share the rest.
  Space plays the reel and the preview follows the playhead. Scrub on the ruler, pinch to zoom (1–16×).
  ⌘Z undoes beat edits (a drag is one step).
- Empty slots are placeholder clips in the clip order (URL scheme reelprep-gap), so ordering, lengths and
  selection work as for clips. ⌫ leaves one where a cut was. They export as <gap>, which can carry the
  anchored song and logos.
- No start screen: the app opens to the empty editor, and drops anywhere load incrementally (logo, song and
  beats, new clips at the end in capture order, proxies). The logo can be switched off per end; intro and
  outro edges snap to beats (settings introBeats / outroBeats).
- Pitfalls met: SwiftUI aborts when observed state changes while a view draws (the thumbnail cache's pending
  set is @ObservationIgnored now). An incremental debug build can link stale objects after a signature
  change (swift package clean).

## Tilt with auto-crop (2026-11-11)

- The user: clips are sometimes a degree or two off; rotate and autocrop. `Reframe.angle` (degrees,
  counter-clockwise like Final Cut, ±10°). The auto-crop is exact, not a margin: the frame's half-extent along
  the tilted clip's axes is (W|cos|+H|sin|)/2 by (W|sin|+H|cos|)/2, the clip is scaled to cover that
  (`cropScale`, 2° on a portrait clip is about +6 %, set by the width), and zoom 1 means that size, so tilting back undoes the
  crop. Offsets are clamped in the clip's own axes, so a tilted, panned clip still covers the frame (tested on
  the frame's edge with the preview's own transform).
- Exported as `rotation` on the clip's `adjust-transform`, with the crop in its scale; editable in Final Cut.
  Not yet checked by import that Final Cut applies position after rotation the same way as the preview.

## Zoom effect and Export Video (2026-11-11)

- The user: a tiny zoom in or out (2-4 %) over a single clip; tilt stays a correction. `Reframe.push` in
  percent, signed. It never goes below the framing (zoom in starts at it, zoom out ends at it), so the
  auto-crop keeps every frame covered. In the FCPXML: `<param name="scale">` with two linear keyframes in
  the clip's local time (DTD-valid; no Final Cut export with keyframes was at hand to match, so the import is
  the check). 3 % standard, the amount remembered.
- The user: a basic export for reels that need no grading. `ReelRenderer` renders the same `FCPTimeline`
  the FCPXML comes from (so the two can't drift apart): one composition video track, one instruction per
  cut with its transform (a ramp for the zoom effect), black gaps, the logo through the Core Animation
  tool, the song with a 1 s fade-out (the FCPXML has none; a posted file ending mid-bar sounded cut off).
  SDR Rec. 709 out (iPhone HLG converted by AVFoundation), AVAssetExportPresetHighestQuality: H.264 about
  10.6 Mbit/s. A 14-cut test shoot, 14.9 s: 6.5 s to render. Frames checked by eye: upright, filled, logo
  on intro and outro. No stabilization (Final Cut's own; nothing comparable without writing one).
- Pitfall: an AVURLAsset released before the export makes insertTimeRange fail with -11800/-12780; the
  renderer keeps its assets.

## 2026-11-13 — Open in Editor: Premiere Pro and DaVinci Resolve through Final Cut Pro 7 XML

- The user asked for a format every editor reads. None of them imports one file with everything: EDL loses
  the framing, logo and markers; OpenTimelineIO isn't imported by Final Cut or Premiere; AAF is for Avid.
  FCPXML (Final Cut, and Resolve) plus Final Cut Pro 7 XML (`xmeml`, Premiere and Resolve) covers all three, so
  ReelPrep writes one or the other from the same `FCPTimeline`. Resolve gets the FCP7 XML too: its FCPXML import
  may not take 1.14, and the XML is the same one Premiere gets, so one import test covers more.
- `FCP7XMLKit` (separate module, 10 tests): xmeml version 4; one sequence at 1080×1920, timebase 30 NTSC; cuts on
  video track 1, logo stills on track 2, the song on audio track 1, beats as sequence markers (the ones inside the
  reel). Everything in sequence frames. Clip sound left out (muted in Final Cut anyway). No stabilization: there's
  no XML for Warp Stabilizer or Resolve's stabilizer.
- Written from the format as documented and as Premiere exports it, without a reference file, so these are the
  things to check on the first Premiere import (a tester checks it in Premiere, 2026-11-13):
  - **Slow motion:** Time Remap speed 50, with in/out in the retimed clip's frames (2 s into the file = 120 frames,
    out − in = the length on the timeline). If Premiere plays the wrong part, in/out are in file frames instead.
  - **Scale:** 100 = the file at its own pixel size, so "fill" is folded in (a 4K portrait iPhone clip is about
    50 %). If clips come in too large or small, Premiere's "Scale to frame size" preference may be applying on top.
  - **Centre:** a share of the frame width/height from the middle, y down. **Rotation:** degrees clockwise
    (ReelPrep's tilt is counter-clockwise, so the sign flips). Both untested; a tilted, panned clip shows both.
  - **Zoom effect:** scale keyframes at the in and out frame (`when` in the clip's frames, not the sequence's).
  - **Paths:** `file://localhost/…`, percent-encoded. "%" in file names isn't worked around (that was Final Cut's freeze).
- The app: the export button is now "Open in Editor", a split button: the main part exports (⌘E), the arrow picks
  the editor, remembered in the defaults ("editor"). The newest Premiere in /Applications (or one folder down,
  "Adobe Premiere Pro 2025/…") is opened with the file. Resolve doesn't import a file it's opened with, so it is
  started and the file shown in the Finder. An editor that isn't installed: the file is shown in the Finder.
  The CLI has `--editor finalcut|premiere|resolve`.
