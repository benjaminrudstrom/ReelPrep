# Porting ReelPrep to Adobe Premiere Pro

**Update 2026-11-13:** the Premiere export now exists: `FCP7XMLKit` writes the reel as Final Cut Pro 7 XML
from the same `FCPTimeline`, and the app's "Open in Editor" button picks Final Cut Pro, Premiere Pro or DaVinci
Resolve (`ReelMedia/Editor.swift`). What's left is the import test in Premiere and fixing what it shows: the
values to check are in DECISIONS.md (2026-11-13). The rest of this brief is how it was planned.

A brief for whoever (or whichever AI) makes a Premiere version. Read README.md (what the app does) and
DECISIONS.md (why, and what was measured) first.

## What stays as it is

Almost everything is editor-neutral:

- `ReelCore`: cut planning on the beats (`EditPlanner`), clip/song/logo models, reframing maths, beat editing.
- `ReelMedia`: reading clips (AVFoundation), beat detection (Accelerate), waveforms, proxies, the beat store.
- `ReelUI` and `ReelPrepApp`: the whole SwiftUI app (library, timeline, preview, export button).
- `FCPXMLKit/RationalTime.swift`: exact rational time, useful for any XML.

`FCPTimeline` (in `FCPXMLKit/Timeline.swift`) is in practice a neutral description of the reel: assets,
cuts (with source in-point, speed, transform, stabilization, muted audio, empty slots as gaps), logo
overlays and the song with beat markers. `ReelTimelineBuilder.timeline(...)` (in `ReelCore/EditPlanner.swift`)
produces it from the plan. A Premiere exporter can consume the same `FCPTimeline`.

## What is Final Cut-specific

- `FCPXMLKit/FCPXMLWriter.swift` and `FCPXMLValidator.swift`: FCPXML 1.14 output, checked against the DTD in
  Final Cut's app bundle.
- `ReelMedia/ReelExporter.swift`: opens the file in Final Cut, names the target Final Cut library, and works
  around Final Cut freezing on "%" in file names (`MediaLinks`, may not be needed for Premiere).
- `ReelMedia/FCPBeatGrid.swift`: reads beats Final Cut already detected from its library. Premiere has no
  equivalent to read; keep ReelPrep's own detector (the default when no Final Cut beats exist) plus the beat
  editor for corrections.
- Texts in the UI and README that say "Final Cut".

`ReelMedia/ReelRenderer.swift` (the Export Video button) renders the same timeline with AVFoundation and is
editor-neutral: it works as it is in a Premiere version.

## Suggested approach

1. Export a small real reel from Premiere as XML (File > Export > Final Cut Pro XML…) and use it as the
   reference for structure and versions. That is how the FCPXML side was done: match a real export rather
   than guessing.
2. Add a module (e.g. `PremiereXMLKit`) with a writer from `FCPTimeline` to the Final Cut Pro 7 XML that
   Premiere imports (`<xmeml>`): a sequence of 1080×1920 at 29.97 fps (timebase 30, ntsc TRUE), video
   track 1 with the cuts as `<clipitem>`s (in/out in source frames, start/end on the sequence), video track 2
   with the logo still (intro and outro), an audio track with the song, and sequence markers on the beats.
   Things to check against the reference export:
   - 50 % slow motion for 60 fps clips (a speed/time-remap filter on the clip item),
   - position and scale from the reframing (the Basic Motion filter; ReelPrep's `Reframe` has zoom on top of
     "fill" and an offset in output pixels),
   - clip audio muted, empty slots as gaps (just no clip item there),
   - file references (`<pathurl>`), and whether "%" in file names causes trouble there too.
   Stabilization (Warp Stabilizer) probably can't be set through XML; leave it for the editor to apply.
3. Make the export target a choice (Final Cut / Premiere) in `ReelExporter` and the export button, and open
   the result with Premiere (`open -a "Adobe Premiere Pro <version>" file.xml`).
4. Add tests like `Tests/FCPXMLKitTests`: build a small `FCPTimeline`, write the XML, assert the key values.
   There is no DTD to validate against, so import into Premiere is the real test.

## Building

Swift Package, macOS 14+, Command Line Tools are enough (no Xcode needed):

- `scripts/test.sh`: runs the tests (42).
- `scripts/make_app.sh`: builds `dist/ReelPrep.app`.
- `swift run reelprep --help`: the command-line version.
