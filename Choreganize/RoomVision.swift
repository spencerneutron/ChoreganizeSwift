import CoreGraphics
import Foundation
import ImageIO
#if canImport(FoundationModels)
import FoundationModels
#endif

// On-device "room vision" for Snap a Room (CG-A1 / #105) and photo check-off
// (CG-A3 / #107). Everything model-facing lives in this one file so the Mac eval
// harness (tools/fm-eval) compiles it as-is and tunes the exact prompts the app
// ships. It deliberately uses no app types — the add-flow / completion mapping
// lives in the app (RoomVisionMapping.swift).
//
// Privacy: a photo is decoded and downsized in memory, handed only to Apple's
// on-device model (never Private Cloud Compute), and never stored or synced.

// MARK: - Results (plain values, available on every OS the app supports)

/// How often a suggested chore should recur — the model's vocabulary, mapped onto
/// `isDaily` + `Frequency` by the app.
enum ChoreCadence: String, CaseIterable, Codable, Sendable {
    case daily, weekly, monthly, yearly
}

struct SuggestedChore: Equatable, Codable, Sendable {
    var name: String
    var cadence: ChoreCadence
}

/// A room read from one photo: what the model saw, the room it thinks it is, and
/// the chores it suggests for it.
struct RoomSuggestion: Equatable, Codable, Sendable {
    var observations: String
    var roomName: String
    var chores: [SuggestedChore]
}

/// Whether a chore looks done in a photo. The raw values are the literal choices
/// the model picks from. Only `.looksDone` is ever pre-selected, and nothing is
/// completed until the user confirms.
enum ChoreVerdict: String, CaseIterable, Codable, Sendable {
    case looksDone = "done"
    case notDone = "not_done"
    case cantTell = "cant_tell"
}

/// One photo checked against a room's open chores. `verdicts[i]` belongs to the
/// i-th chore that was passed in.
struct RoomCheck: Equatable, Codable, Sendable {
    var observations: String
    var verdicts: [ChoreVerdict]
}

/// Token accounting for one model request (debug / eval only).
struct RoomVisionUsage: Equatable, Codable, Sendable {
    var inputTokens: Int
    var outputTokens: Int
}

/// What the household already has, so suggestions reuse room names and skip
/// chores that already exist.
struct RoomVisionHomeContext: Equatable, Sendable {
    var roomNames: [String] = []
    /// Existing chore names keyed by room name.
    var choresByRoom: [String: [String]] = [:]
}

// MARK: - Availability

/// Whether the photo features can run here. Read it inside a view's `body`: on
/// iOS/macOS 27 it reads the observable `SystemLanguageModel`, so views refresh on
/// their own when Apple Intelligence is switched on or finishes downloading.
enum RoomVisionAvailability: Equatable, Sendable {
    case available
    /// Eligible device, but Apple Intelligence is off in Settings.
    case appleIntelligenceOff
    /// Apple Intelligence is on, but the model is still downloading or preparing.
    case preparing
    /// Older OS, ineligible device, a model without vision, or an unsupported
    /// language — the feature stays hidden.
    case unsupported

    static var current: RoomVisionAvailability {
        #if canImport(FoundationModels)
        if #available(iOS 27.0, macOS 27.0, *) {
            return RoomVisionEngine.availability()
        }
        #endif
        return .unsupported
    }

    var isAvailable: Bool { self == .available }

    /// Worth showing an entry point for, even if it has to be disabled for now.
    var isOfferable: Bool { self != .unsupported }

    /// Why a shown entry point is disabled; nil when it's usable (or hidden).
    var hint: String? {
        switch self {
        case .appleIntelligenceOff: return "Turn on Apple Intelligence in Settings to use this."
        case .preparing:            return "Apple Intelligence is still getting ready. Try again soon."
        case .available, .unsupported: return nil
        }
    }
}

// MARK: - Photo preparation

/// Photo decoding shared by the app and the eval harness so both hand the model
/// identical pixels: decode, apply the EXIF orientation, downsize.
enum RoomPhoto {
    /// The model encodes any photo of 1024 px or more at the same cost (~131 input
    /// tokens, measured 2026-09-22), so a larger source only costs memory.
    static let maxPixelSize = 1024

    static func prepare(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnail(from: source)
    }

    static func prepare(contentsOf url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return thumbnail(from: source)
    }

    private static func thumbnail(from source: CGImageSource) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // bake in EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

// MARK: - Errors

enum RoomVisionError: Error, Equatable, Sendable {
    /// The model became unavailable (turned off, locale, missing capability).
    case unavailable
    /// The photo couldn't be decoded.
    case unreadablePhoto
    /// The request was declined by the model's safety guardrails.
    case declined
    /// Another request is running, or the system is rate limiting.
    case busy
    /// Anything else (timeout, context overflow, malformed output).
    case failed

    var message: String {
        switch self {
        case .unavailable:     return "Apple Intelligence isn't available right now."
        case .unreadablePhoto: return "That photo couldn't be opened. Try another one."
        case .declined:        return "This photo can't be used. Try another angle of the room."
        case .busy:            return "Apple Intelligence is busy. Try again in a moment."
        case .failed:          return "Something went wrong reading the photo. Try again."
        }
    }
}

// MARK: - Prompts (plain strings, so tests and the harness can inspect them)

enum RoomVisionPrompts {
    static let suggestInstructions = """
        You help a household set up chores. You'll see one photo of a room in their home.
        Suggest the recurring chores most households actually do to keep a room like this clean and tidy, based on what's in the photo. For example: cleaning the sink and wiping counters in a kitchen, cleaning the toilet in a bathroom, or vacuuming and dusting in a living room.
        - Every chore must fit something you can see in the photo.
        - Skip walls, ceilings, and decorations unless they look dirty.
        - Write each chore as a short command of 2 to 5 words, like "Wipe down counters" or "Vacuum the rug". Vacuum rugs and carpets; sweep or mop hard floors.
        - Choose a realistic frequency: daily for things that get messy every day, weekly for regular cleaning, monthly or yearly for deep cleaning.
        - Don't suggest a chore the household already has, even if you'd word it differently.
        - Don't mention or describe any people in the photo.
        """

    static let checkInstructions = """
        You help a household check off chores. You'll see one photo of a room in their home and a list of chores for that room.
        For each chore, first say whether the thing it's about (like the sink, the bed, or the trash can) is visible in the photo. Then decide what the photo shows right now:
        - done: the photo clearly shows the chore's result. For example, an empty, clean sink for "Do the dishes", or a neatly made bed for "Make the bed".
        - not_done: the photo clearly shows the chore still needs doing. For example, dirty dishes in the sink, or an unmade bed.
        - cant_tell: the photo doesn't show enough to decide, or a photo can't show the chore, like "Water the plants", "Change the sheets", or "Take out the trash" when no trash can is visible.
        Only answer done when the photo clearly shows it. When in doubt, answer cant_tell.
        Don't mention or describe any people in the photo.
        """

    /// Caps that keep a large household's context well inside the 8K window.
    static let maxRooms = 30
    static let maxExistingChores = 120
    static let maxNameLength = 60

    static func suggestPrompt(_ home: RoomVisionHomeContext) -> String {
        var lines = ["Suggest recurring chores for the room in this photo."]
        let rooms = home.roomNames.map(clip).filter { !$0.isEmpty }.prefix(maxRooms)
        if !rooms.isEmpty {
            lines.append("Rooms this household already has: \(rooms.joined(separator: ", ")). "
                         + "If the photo shows one of them, use that exact name.")
        }
        var budget = maxExistingChores
        var existing: [String] = []
        for room in home.choresByRoom.keys.sorted() where budget > 0 {
            let chores = (home.choresByRoom[room] ?? []).map(clip).filter { !$0.isEmpty }.prefix(budget)
            guard !chores.isEmpty else { continue }
            budget -= chores.count
            existing.append("- \(clip(room)): \(chores.joined(separator: "; "))")
        }
        if !existing.isEmpty {
            lines.append("Chores they already have (don't suggest these again):")
            lines.append(contentsOf: existing)
        }
        return lines.joined(separator: "\n")
    }

    static func checkPrompt(roomName: String?, keys: [String]) -> String {
        var lines: [String] = []
        if let room = roomName.map(clip), !room.isEmpty { lines.append("Room: \(room)") }
        lines.append("Chores to check:")
        lines.append(contentsOf: keys.map { "- \($0)" })
        return lines.joined(separator: "\n")
    }

    /// Output property names for a check: the chore names themselves (so each
    /// verdict is generated right after its chore's name), made safe and unique.
    /// Index-aligned with `chores`.
    static func checkKeys(for chores: [String]) -> [String] {
        var used: Set<String> = [observationsKey]
        return chores.map { raw in
            var base = clip(raw.filter { $0 != "\"" && $0 != "\\" })
            if base.isEmpty { base = "Chore" }
            var key = base
            var n = 2
            while used.contains(key.lowercased()) {
                key = "\(base) (\(n))"
                n += 1
            }
            used.insert(key.lowercased())
            return key
        }
    }

    static let observationsKey = "observations"

    /// Single-line, trimmed, length-capped.
    static func clip(_ text: String) -> String {
        let flat = text.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > maxNameLength ? String(flat.prefix(maxNameLength)) : flat
    }
}

// MARK: - Engine (iOS / macOS 27)

#if canImport(FoundationModels)

@available(iOS 27.0, macOS 27.0, *)
@Generable(description: "Recurring chore suggestions for one room, based on a photo of it")
struct RoomSuggestionOutput {
    // Declared (and so generated) first: the model describes the photo before it
    // names the room or suggests anything — "look, then decide".
    @Guide(description: "One or two sentences on what the photo shows that matters for cleaning and upkeep")
    var observations: String

    @Guide(description: "A short name for the room, like Kitchen, Bathroom, or Garage")
    var roomName: String

    @Guide(description: "5 to 8 chores for this room, most useful first", .count(5...8))
    var chores: [SuggestedChoreOutput]
}

@available(iOS 27.0, macOS 27.0, *)
@Generable
struct SuggestedChoreOutput {
    @Guide(description: "The chore as a short command of 2 to 5 words, like \"Wipe down counters\"")
    var name: String

    @Guide(description: "How often the chore should be done")
    var cadence: CadenceOutput
}

@available(iOS 27.0, macOS 27.0, *)
@Generable
enum CadenceOutput {
    case daily, weekly, monthly, yearly

    var cadence: ChoreCadence {
        switch self {
        case .daily:   return .daily
        case .weekly:  return .weekly
        case .monthly: return .monthly
        case .yearly:  return .yearly
        }
    }
}

@available(iOS 27.0, macOS 27.0, *)
enum RoomVisionEngine {
    static func availability(of model: SystemLanguageModel = .default) -> RoomVisionAvailability {
        switch model.availability {
        case .available:
            guard model.capabilities.contains(.vision), model.supportsLocale() else { return .unsupported }
            return .available
        case .unavailable(.appleIntelligenceNotEnabled):
            return .appleIntelligenceOff
        case .unavailable(.modelNotReady):
            return .preparing
        default:
            return .unsupported
        }
    }

    // Greedy sampling: the same photo gets the same answer, which keeps the eval
    // harness reproducible and the UI predictable on retry.
    private static let options = GenerationOptions(samplingMode: .greedy)

    // MARK: Suggest (Snap a Room)

    /// Streams progressively complete suggestions; the last element is the full
    /// result. A chore only appears once its name and cadence are both complete.
    static func streamSuggestions(for image: CGImage,
                                  home: RoomVisionHomeContext) -> AsyncThrowingStream<RoomSuggestion, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = LanguageModelSession(instructions: RoomVisionPrompts.suggestInstructions)
                    let stream = session.streamResponse(generating: RoomSuggestionOutput.self, options: options) {
                        Attachment(image)
                        RoomVisionPrompts.suggestPrompt(home)
                    }
                    for try await snapshot in stream {
                        continuation.yield(suggestion(from: snapshot.content))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: mapError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One-shot variant (eval harness): the full suggestion plus token usage.
    static func suggestions(for image: CGImage,
                            home: RoomVisionHomeContext) async throws -> (RoomSuggestion, RoomVisionUsage) {
        do {
            let session = LanguageModelSession(instructions: RoomVisionPrompts.suggestInstructions)
            let response = try await session.respond(generating: RoomSuggestionOutput.self, options: options) {
                Attachment(image)
                RoomVisionPrompts.suggestPrompt(home)
            }
            let output = response.content
            let result = RoomSuggestion(
                observations: output.observations,
                roomName: output.roomName,
                chores: output.chores.map { SuggestedChore(name: $0.name, cadence: $0.cadence.cadence) })
            return (result, usage(response.usage))
        } catch {
            throw mapError(error)
        }
    }

    private static func suggestion(from partial: RoomSuggestionOutput.PartiallyGenerated) -> RoomSuggestion {
        RoomSuggestion(
            observations: partial.observations ?? "",
            roomName: partial.roomName ?? "",
            chores: (partial.chores ?? []).compactMap { chore in
                guard let name = chore.name, let cadence = chore.cadence else { return nil }
                return SuggestedChore(name: name, cadence: cadence.cadence)
            })
    }

    // MARK: Check (photo check-off)

    /// Judges each chore against the photo. The output schema is built at runtime
    /// with one property per chore (named after the chore) — the model can't skip a
    /// chore or invent one. Each chore first records whether its subject is visible,
    /// then a verdict constrained to the three choices; a chore whose subject isn't
    /// visible is always "can't tell", whatever verdict follows.
    static func check(_ chores: [String], roomName: String?,
                      in image: CGImage) async throws -> (RoomCheck, RoomVisionUsage) {
        guard !chores.isEmpty else { return (RoomCheck(observations: "", verdicts: []), RoomVisionUsage(inputTokens: 0, outputTokens: 0)) }
        let keys = RoomVisionPrompts.checkKeys(for: chores)
        do {
            let verdict = DynamicGenerationSchema(name: "Verdict", anyOf: ChoreVerdict.allCases.map(\.rawValue))
            let choreCheck = DynamicGenerationSchema(name: "ChoreCheck", properties: [
                .init(name: "visible",
                      description: "Whether the thing this chore is about can be seen in the photo",
                      schema: DynamicGenerationSchema(type: Bool.self)),
                .init(name: "verdict", schema: DynamicGenerationSchema(referenceTo: "Verdict")),
            ])
            var properties = [DynamicGenerationSchema.Property(
                name: RoomVisionPrompts.observationsKey,
                description: "One or two sentences on what the photo shows about these chores",
                schema: DynamicGenerationSchema(type: String.self))]
            properties += keys.map {
                DynamicGenerationSchema.Property(name: $0, schema: DynamicGenerationSchema(referenceTo: "ChoreCheck"))
            }
            let schema = try GenerationSchema(
                root: DynamicGenerationSchema(name: "RoomCheck", properties: properties),
                dependencies: [verdict, choreCheck])

            let session = LanguageModelSession(instructions: RoomVisionPrompts.checkInstructions)
            let response = try await session.respond(schema: schema, options: options) {
                Attachment(image)
                RoomVisionPrompts.checkPrompt(roomName: roomName, keys: keys)
            }
            let content = response.content
            let observations = (try? content.value(String.self, forProperty: RoomVisionPrompts.observationsKey)) ?? ""
            let verdicts = keys.map { key -> ChoreVerdict in
                // Anything missing, unexpected, or not visible is "can't tell" — never done.
                guard let check = try? content.value(GeneratedContent.self, forProperty: key),
                      (try? check.value(Bool.self, forProperty: "visible")) == true,
                      let raw = try? check.value(String.self, forProperty: "verdict"),
                      let verdict = ChoreVerdict(rawValue: raw) else { return .cantTell }
                return verdict
            }
            return (RoomCheck(observations: observations, verdicts: verdicts), usage(response.usage))
        } catch {
            throw mapError(error)
        }
    }

    // MARK: Helpers

    private static func usage(_ usage: LanguageModelSession.Usage) -> RoomVisionUsage {
        RoomVisionUsage(inputTokens: usage.input.totalTokenCount, outputTokens: usage.output.totalTokenCount)
    }

    static func mapError(_ error: Error) -> Error {
        if error is RoomVisionError || error is CancellationError { return error }
        if let error = error as? LanguageModelError {
            switch error {
            case .guardrailViolation, .refusal:
                return RoomVisionError.declined
            case .rateLimited:
                return RoomVisionError.busy
            case .unsupportedCapability, .unsupportedLanguageOrLocale:
                return RoomVisionError.unavailable
            default:
                return RoomVisionError.failed
            }
        }
        if let error = error as? LanguageModelSession.Error, error == .concurrentRequests {
            return RoomVisionError.busy
        }
        // iOS 27 reports model failures as LanguageModelError; the deprecated
        // GenerationError (and anything else) lands in the generic case.
        return RoomVisionError.failed
    }
}

#endif
