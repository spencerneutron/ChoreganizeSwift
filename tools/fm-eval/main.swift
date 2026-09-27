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
//
// Describe Chores (#106) takes a cases file instead of a photos folder:
//
//   tools/fm-eval/run.sh tools/fm-eval/describe-cases.json [out-dir] --only describe
//
// Each case is some text (+ the household's rooms) and the chores it should yield,
// matched by keywords in the chore's name; cadence / room accept "|"-separated
// alternatives ("" allowed), days must match exactly, and any field left out isn't
// scored. A chore that matches no expected one is INVENTED: the failure that matters,
// since it adds something the user never asked for. The exit status is 1 if any occur.

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

// MARK: - Describe Chores (#106)

struct DescribeCase: Decodable {
    var text: String
    var rooms: [String]?
    var expect: [Expected]

    struct Expected: Decodable {
        var match: [String]
        var cadence: String?
        var days: [String]?
        var every: Int?
        var room: String?
    }
}

struct DescribeResult: Encodable {
    var text: String
    var seconds: Double
    var chores: [DescribedChore]
    var problems: [String]
}

/// Like the app's RoomVisionMapping.roomKey: case, spacing and punctuation don't matter.
func roomKey(_ name: String) -> String {
    name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0 != "the" }.joined()
}

func alternatives(_ spec: String) -> [String] {
    spec.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
}

if only == "describe" {
    guard #available(macOS 27.0, *) else {
        print("fm-eval needs macOS 27 (on-device Foundation Models).")
        exit(2)
    }
    let cases = try JSONDecoder().decode([DescribeCase].self, from: Data(contentsOf: URL(fileURLWithPath: photosPath)))
    let availability = RoomVisionEngine.availability(needsVision: false)
    print("# Describe Chores eval — \(cases.count) case(s), model: \(availability)\n")
    guard availability == .available else { exit(2) }

    var results: [DescribeResult] = []
    var fields = 0, fieldsOK = 0, invented = 0, missed = 0, extra = 0, perfect = 0
    var seconds = 0.0
    for (number, testCase) in cases.enumerated() {
        print("## \(number + 1). \(testCase.text)")
        let start = Date()
        var problems: [String] = []
        var chores: [DescribedChore] = []
        do {
            let usage: RoomVisionUsage
            (chores, usage) = try await DescribeChoresEngine.chores(from: testCase.text, rooms: testCase.rooms ?? [])
            let elapsed = Date().timeIntervalSince(start)
            seconds += elapsed
            print("- \(String(format: "%.1f", elapsed)) s, \(usage.inputTokens) in / \(usage.outputTokens) out tokens")
            for chore in chores {
                let days = chore.days.isEmpty ? "" : " on \(chore.days.joined(separator: ", "))"
                let every = chore.every > 1 ? " every \(chore.every)" : ""
                let room = chore.room.isEmpty ? "" : " · \(chore.room)"
                print("  - \(chore.name) — \(chore.cadence.rawValue)\(days)\(every)\(room)")
            }
            func matches(_ chore: DescribedChore, _ expected: DescribeCase.Expected) -> Bool {
                expected.match.allSatisfy { chore.name.lowercased().contains($0.lowercased()) }
            }
            var used = Set<Int>()
            for expected in testCase.expect {
                guard let index = chores.indices.first(where: { !used.contains($0) && matches(chores[$0], expected) }) else {
                    missed += 1
                    problems.append("MISSED \(expected.match.joined(separator: " "))")
                    continue
                }
                used.insert(index)
                let chore = chores[index]
                func score(_ field: String, ok: Bool, got: String, want: String) {
                    fields += 1
                    if ok { fieldsOK += 1 } else { problems.append("\(chore.name): \(field) \(got), want \(want)") }
                }
                if let cadence = expected.cadence {
                    score("cadence", ok: alternatives(cadence).contains(chore.cadence.rawValue),
                          got: chore.cadence.rawValue, want: cadence)
                }
                if let days = expected.days {
                    score("days", ok: Set(days) == Set(chore.days),
                          got: "[\(chore.days.joined(separator: ","))]", want: "[\(days.joined(separator: ","))]")
                }
                if let every = expected.every {
                    score("every", ok: every == chore.every, got: "\(chore.every)", want: "\(every)")
                }
                if let room = expected.room {
                    score("room", ok: alternatives(room).map(roomKey).contains(roomKey(chore.room)),
                          got: "\"\(chore.room)\"", want: "\"\(room)\"")
                }
            }
            for (index, chore) in chores.enumerated() where !used.contains(index) {
                if testCase.expect.contains(where: { matches(chore, $0) }) {
                    extra += 1
                    problems.append("extra: \(chore.name)")
                } else {
                    invented += 1
                    problems.append("INVENTED: \(chore.name)")
                }
            }
        } catch {
            problems.append("failed: \(error)")
        }
        for problem in problems { print("  ! \(problem)") }
        if problems.isEmpty { perfect += 1 }
        results.append(DescribeResult(text: testCase.text, seconds: Date().timeIntervalSince(start),
                                      chores: chores, problems: problems))
        print("")
    }
    print("---\nPerfect cases: \(perfect) / \(cases.count) · fields \(fieldsOK) / \(fields)"
          + " · INVENTED \(invented) · missed \(missed) · extra \(extra)"
          + " · avg \(String(format: "%.1f", seconds / Double(max(cases.count, 1)))) s")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(results).write(to: outDir.appendingPathComponent("describe-results.json"))
    print("Results: \(outDir.appendingPathComponent("describe-results.json").path)")
    exit(invented > 0 ? 1 : 0)
}

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

// The rooms offered to identifyRoom: every room any sidecar names, plus a few distractors.
let allRooms: [String] = {
    var names = Set(["Kitchen", "Bathroom", "Bedroom", "Living Room", "Garage", "Laundry Room", "Office", "Dining Room"])
    for url in photos {
        let sidecar = (try? Data(contentsOf: url.deletingPathExtension().appendingPathExtension("json")))
            .flatMap { try? JSONDecoder().decode(Sidecar.self, from: $0) }
        if let room = sidecar?.check?.room { names.insert(room) }
    }
    return names.sorted()
}()
var roomCorrect = 0
var roomScored = 0

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

    if only == "room" {
        let start = Date()
        do {
            let guess = try await RoomVisionEngine.identifyRoom(in: image, among: allRooms)
            let expected = sidecar?.check?.room
            let ok = expected == nil || guess == expected
            if expected != nil { roomScored += 1; if ok { roomCorrect += 1 } }
            print("- **Room** (\(String(format: "%.1f", Date().timeIntervalSince(start))) s): \(guess ?? "none")"
                  + (expected.map { " (expected \($0))\(ok ? "" : " ← wrong")" } ?? ""))
        } catch {
            print("- **Room** failed: \(error)")
        }
        print("")
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

if only == "room" { print("---\nRooms identified: \(roomCorrect) / \(roomScored)") }
print("---\nScored verdicts: \(scored) · FALSE DONE: \(falseDone) · missed done: \(missedDone)")
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(results).write(to: outDir.appendingPathComponent("results.json"))
print("Results: \(outDir.appendingPathComponent("results.json").path)")
exit(falseDone > 0 ? 1 : 0)
