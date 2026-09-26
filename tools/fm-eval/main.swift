// Foundation Models eval harness for Choreganize's room-vision features.
// Compiled together with Choreganize/RoomVision.swift (see run.sh), so it runs the
// exact instructions, schemas and photo preparation the app ships — on this Mac's
// on-device model. Photos stay local; nothing here is committed or uploaded.
//
//   tools/fm-eval/run.sh <photos-dir> [out-dir] [--only suggest|check] [--stream]
//
// For every image in <photos-dir> it runs "Snap a Room" (suggest). If the photo has
// a sidecar <name>.json with a "check" block, it also runs the photo check and scores
// the verdicts against the expected ones:
//
//   {
//     "rooms": ["Kitchen", "Bathroom"],
//     "existing": { "Kitchen": ["Wipe down counters"] },
//     "check": {
//       "room": "Kitchen",
//       "chores": ["Do the dishes", "Water the plants"],
//       "expect": { "Do the dishes": "not_done", "Water the plants": "cant_tell|not_done" }
//     }
//   }
//
// "expect" lists the acceptable verdicts (done / not_done / cant_tell, "|"-separated).
// A "done" where done isn't acceptable is a FALSE DONE — the failure that matters,
// since it would pre-check a chore that isn't done. The exit status is 1 if any occur.

import CoreGraphics
import Foundation

struct Sidecar: Decodable {
    var rooms: [String]?
    var existing: [String: [String]]?
    var check: Check?

    struct Check: Decodable {
        var room: String?
        var chores: [String]
        var expect: [String: String]?
    }
}

struct PhotoResult: Encodable {
    var photo: String
    var suggest: SuggestResult?
    var check: CheckResult?
    var error: String?
}

struct SuggestResult: Encodable {
    var seconds: Double
    var usage: RoomVisionUsage?
    var suggestion: RoomSuggestion
}

struct CheckResult: Encodable {
    var seconds: Double
    var usage: RoomVisionUsage
    var observations: String
    var rows: [Row]

    struct Row: Encodable {
        var chore: String
        var verdict: String
        var acceptable: [String]?
        var outcome: String   // ok | FALSE DONE | missed done | unscored
    }
}

// MARK: - Arguments

var args = Array(CommandLine.arguments.dropFirst())
let stream = args.contains("--stream")
var only: String?
if let i = args.firstIndex(of: "--only"), i + 1 < args.count {
    only = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
args.removeAll { $0 == "--stream" }
guard let photosPath = args.first else {
    print("usage: fm-eval <photos-dir> [out-dir] [--only suggest|check] [--stream]")
    exit(2)
}
let photosDir = URL(fileURLWithPath: photosPath, isDirectory: true)
let outDir = URL(fileURLWithPath: args.count > 1 ? args[1] : NSTemporaryDirectory() + "fm-eval", isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic"]
let photos = try FileManager.default.contentsOfDirectory(at: photosDir, includingPropertiesForKeys: nil)
    .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

guard #available(macOS 27.0, *) else {
    print("fm-eval needs macOS 27 (on-device Foundation Models with vision).")
    exit(2)
}
let availability = RoomVisionEngine.availability()
print("# Room vision eval — \(photos.count) photo(s), model: \(availability)\n")
guard availability == .available else { exit(2) }

// MARK: - Run

func acceptable(_ spec: String?) -> [String]? {
    spec.map { $0.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) } }
}

var results: [PhotoResult] = []
var falseDone = 0
var missedDone = 0
var scored = 0

for url in photos {
    let name = url.lastPathComponent
    var result = PhotoResult(photo: name)
    let sidecarURL = url.deletingPathExtension().appendingPathExtension("json")
    let sidecar = (try? Data(contentsOf: sidecarURL)).flatMap { try? JSONDecoder().decode(Sidecar.self, from: $0) }

    print("## \(name)")
    guard let image = RoomPhoto.prepare(contentsOf: url) else {
        result.error = "unreadable photo"
        print("- unreadable photo\n")
        results.append(result)
        continue
    }

    if only != "check" {
        let home = RoomVisionHomeContext(roomNames: sidecar?.rooms ?? [], choresByRoom: sidecar?.existing ?? [:])
        let start = Date()
        do {
            var suggestion: RoomSuggestion
            var usage: RoomVisionUsage?
            if stream {
                suggestion = RoomSuggestion(observations: "", roomName: "", chores: [])
                var snapshots = 0
                for try await snapshot in RoomVisionEngine.streamSuggestions(for: image, home: home) {
                    suggestion = snapshot
                    snapshots += 1
                }
                print("- streamed \(snapshots) snapshots")
            } else {
                (suggestion, usage) = try await RoomVisionEngine.suggestions(for: image, home: home)
            }
            let seconds = Date().timeIntervalSince(start)
            result.suggest = SuggestResult(seconds: seconds, usage: usage, suggestion: suggestion)
            print("- **Suggest** (\(String(format: "%.1f", seconds)) s\(usage.map { ", \($0.inputTokens) in / \($0.outputTokens) out tokens" } ?? "")): **\(suggestion.roomName)**")
            print("  - saw: \(suggestion.observations)")
            for chore in suggestion.chores {
                print("  - \(chore.name) — \(chore.cadence.rawValue)")
            }
        } catch {
            result.error = "suggest: \(error)"
            print("- **Suggest** failed: \(error)")
        }
    }

    if only != "suggest", let check = sidecar?.check {
        let start = Date()
        do {
            let (outcome, usage) = try await RoomVisionEngine.check(check.chores, roomName: check.room, in: image)
            let seconds = Date().timeIntervalSince(start)
            var rows: [CheckResult.Row] = []
            print("- **Check** (\(String(format: "%.1f", seconds)) s, \(usage.inputTokens) in / \(usage.outputTokens) out tokens)")
            print("  - saw: \(outcome.observations)")
            for (chore, verdict) in zip(check.chores, outcome.verdicts) {
                let allowed = acceptable(check.expect?[chore])
                var label = "unscored"
                if let allowed {
                    scored += 1
                    if allowed.contains(verdict.rawValue) {
                        label = "ok"
                    } else if verdict == .looksDone {
                        label = "FALSE DONE"
                        falseDone += 1
                    } else if allowed == ["done"] {
                        label = "missed done"
                        missedDone += 1
                    } else {
                        label = "mismatch"
                    }
                }
                rows.append(.init(chore: chore, verdict: verdict.rawValue, acceptable: allowed, outcome: label))
                let expected = allowed.map { " (expected \($0.joined(separator: "|")))" } ?? ""
                print("  - \(chore): \(verdict.rawValue)\(expected)\(label == "ok" || label == "unscored" ? "" : " ← \(label)")")
            }
            result.check = CheckResult(seconds: seconds, usage: usage, observations: outcome.observations, rows: rows)
        } catch {
            result.error = (result.error.map { $0 + "; " } ?? "") + "check: \(error)"
            print("- **Check** failed: \(error)")
        }
    }
    print("")
    results.append(result)
}

print("---\nScored verdicts: \(scored) · FALSE DONE: \(falseDone) · missed done: \(missedDone)")
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(results).write(to: outDir.appendingPathComponent("results.json"))
print("Results: \(outDir.appendingPathComponent("results.json").path)")
exit(falseDone > 0 ? 1 : 0)
