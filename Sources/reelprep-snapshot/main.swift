import AppKit
import SwiftUI
import ReelCore
import ReelUI

// Renders ReelPrep's views to PNGs, for checking the UI without a window:
//   reelprep-snapshot beats <song> <out.png>
//   reelprep-snapshot app <out-prefix> <files…>     (start screen, then the editor after Continue)
let args = Array(CommandLine.arguments.dropFirst())

@MainActor func render<V: View>(_ view: V, size: CGSize, to path: String) {
    let r = ImageRenderer(content: view.frame(width: size.width, height: size.height))
    r.scale = 2
    if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
        print("Wrote \(path)")
    } else {
        print("Rendering failed: \(path)")
    }
}

func url(_ p: String) -> URL { URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }

MainActor.assumeIsolated {
    var finished = false
    Task { @MainActor in
        defer { finished = true }
        switch args.first {
        case "beats" where args.count == 3:
            let model = BeatEditorModel()
            await model.open(url(args[1]))
            if model.beats.times.count > 5 { model.beats.selection = [4] }
            model.playhead = min(3.3, model.duration)
            render(BeatEditorView(model: model, staticRender: true), size: CGSize(width: 1300, height: 420), to: args[2])
        case "app" where args.count >= 3:
            let project = ReelProject()
            project.add(args.dropFirst(2).map(url))
            render(RootView(project: project).background(Color(nsColor: .windowBackgroundColor)),
                   size: CGSize(width: 1400, height: 900), to: args[1] + "-start.png")
            await project.continueToEditor()
            if project.clips.count > 1 { project.selectedClip = project.clips[1].url }
            render(RootView(project: project).background(Color(nsColor: .windowBackgroundColor)),
                   size: CGSize(width: 1400, height: 900), to: args[1] + "-editor.png")
            print(project.notices.joined(separator: "\n"))
        case "export" where args.count >= 3:
            // Exercise the app's export: zoom/pan the first clip, slide the second one's window.
            let project = ReelProject()
            project.add(args.dropFirst(2).map(url))
            await project.continueToEditor()
            guard project.clips.count >= 2 else { print(project.notices); break }
            project.reframes[project.clips[0].url] = Reframe(zoom: 1.5, dx: 192, dy: 96)
            project.inPoints[project.clips[1].url] = 0.5
            project.export(to: url(args[1]), open: false)
            print(project.exportMessage ?? "")
        case "slots" where args.count >= 3:
            // Exercise empty slots: remove cut 2, fill it from the library, move cut 3 into a slot, export.
            let project = ReelProject()
            project.add(args.dropFirst(2).map(url))
            await project.continueToEditor()
            @MainActor func show(_ label: String) {
                let plan = project.plan, reel = project.reelClips
                print(label + ": " + plan.slots.map { s in "\(reel[s.clipIndex].name)(\(s.beats))" }.joined(separator: " "))
            }
            show("start")
            let second = project.reelClips[project.plan.slots[1].clipIndex].url
            project.removeFromReel(second)
            show("remove 2")
            let gap = project.selectedClip!
            let unused = project.clips.first { !$0.isPlaceholder && project.slot(for: $0.url, in: project.plan) == nil && !project.excluded.contains($0.url) }!
            project.fill(gap, with: unused.url)
            show("fill from library")
            let third = project.reelClips[project.plan.slots[2].clipIndex].url
            project.removeFromReel(project.reelClips[project.plan.slots[5].clipIndex].url)
            let gap2 = project.selectedClip!
            project.fill(gap2, with: third)
            show("cut 3 into slot 6")
            if let spare = project.clips.first(where: { !$0.isPlaceholder && project.slot(for: $0.url, in: project.plan) == nil }) {
                project.replace(project.reelClips[project.plan.slots[0].clipIndex].url, with: spare.url)
                show("replace 1 with \(spare.name)")
            }
            let eighth = project.reelClips[project.plan.slots[7].clipIndex].url
            project.replace(project.reelClips[project.plan.slots[3].clipIndex].url, with: eighth)
            show("replace 4 with cut 8")
            project.export(to: url(args[1]), open: false)
            print(project.exportMessage ?? "")
        default:
            print("usage: reelprep-snapshot beats <song> <out.png> | app <out-prefix> <files…>")
        }
    }
    while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
}
