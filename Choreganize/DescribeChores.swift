import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// Describe Chores (CG-A2 / #106): type or dictate chores in your own words, and the
// on-device model turns them into scheduled chores. Model-facing only, like
// RoomVision.swift: tools/fm-eval compiles this file as-is, so the harness tunes the
// exact prompt and post-processing the app ships. No app types here; the add-flow
// mapping lives in DescribeChoresMapping.swift.
//
// The work is split: the model splits the text into chores, names them, and copies
// out the words that say when ("every other Saturday") and where. Plain code then
// reads the days and the interval from those words (ScheduleWords), because a small
// model is unreliable with numbers and day lists, and checks that every chore, time
// and room really comes from the text (DescribeChoresGrounding), so nothing is invented.
//
// Privacy: the text goes only to Apple's on-device model (never Private Cloud
// Compute) and isn't stored. Only the chores the user chooses to add are saved.

/// One chore read from the user's description.
struct DescribedChore: Equatable, Codable, Sendable {
    var name: String
    var cadence: ChoreCadence
    /// Weekdays, lowercased ("monday"), Sunday first; empty when the text names none.
    var days: [String]
    /// Repeat every this many weeks, months or years (1 = every one).
    var every: Int
    /// The room the text names for it, under the household's spelling when it has that
    /// room; "" when the text names none.
    var room: String
    /// The words that said when, as written ("every other Saturday"); "" if none.
    var when: String
}

// MARK: - Prompts

enum DescribeChoresPrompts {
    static let instructions = """
        You turn what someone writes about their household chores into a list of recurring chores.
        - List each chore the text names, once, in the order it names them. Never add a chore the text doesn't name. If it names none, the list is empty.
        - name: a short command that starts with a verb and keeps their wording, including small words like "the". Fix any typos.
        - when: copy the words from the text that say when or how often the chore happens. Leave it empty if the text doesn't say.
        - room: the room the text names for the chore. Leave it empty if the text doesn't name one.
        - cadence: how often it happens. If the text doesn't say, choose weekly.
        """

    /// The most text sent to the model. A few sentences need far less.
    static let maxTextLength = 1_000

    static func prompt(text: String, rooms: [String]) -> String {
        var lines: [String] = []
        let rooms = rooms.map(RoomVisionPrompts.clip).filter { !$0.isEmpty }.prefix(RoomVisionPrompts.maxRooms)
        if !rooms.isEmpty {
            lines.append("The household's rooms: \(rooms.joined(separator: ", ")).")
        }
        lines.append("What they wrote:")
        lines.append(clipText(text))
        return lines.joined(separator: "\n")
    }

    /// Trimmed and capped; line breaks are kept (a list reads better as one).
    static func clipText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > maxTextLength ? String(trimmed.prefix(maxTextLength)) : trimmed
    }
}

extension RoomVisionError {
    /// The same failures, worded for Describe Chores (there's no photo involved).
    var textMessage: String {
        switch self {
        case .unavailable, .busy:       return message
        case .declined:                 return "That can't be used. Try describing your chores differently."
        case .unreadablePhoto, .failed: return "Something went wrong reading that. Try again."
        }
    }
}

// MARK: - Reading a schedule phrase

/// Reads days, interval and cadence from the words that said when ("every other
/// Saturday", "Mon & Thu", "twice a week", "the first Sunday of every month").
/// English only; anything it doesn't recognize is left to the model's cadence.
enum ScheduleWords {
    struct Reading: Equatable {
        /// nil when the phrase doesn't settle it.
        var cadence: ChoreCadence?
        var days: [String] = []
        var every = 1
    }

    static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    private static let weekdayWords: [String: [String]] = {
        var map: [String: [String]] = [
            "weekend": ["saturday", "sunday"], "weekends": ["saturday", "sunday"],
            "weekday": ["monday", "tuesday", "wednesday", "thursday", "friday"],
            "weekdays": ["monday", "tuesday", "wednesday", "thursday", "friday"],
            "tues": ["tuesday"], "weds": ["wednesday"], "thur": ["thursday"], "thurs": ["thursday"],
        ]
        for day in weekdays {
            map[day] = [day]
            map[day + "s"] = [day]
            map[String(day.prefix(3))] = [day]
        }
        return map
    }()

    private static let numbers: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "couple": 2,
    ]

    private static let yearWords: Set<String> = ["year", "years", "yearly", "annual", "annually"]
    private static let seasonWords: Set<String> = [
        "spring", "summer", "fall", "autumn", "winter", "january", "february", "march", "april", "june",
        "july", "august", "september", "october", "november", "december",
    ]
    private static let monthWords: Set<String> = ["month", "months", "monthly"]
    private static let weekWords: Set<String> = ["week", "weeks", "weekly", "biweekly", "fortnight", "fortnightly"]
    private static let dailyWords: Set<String> = ["day", "days", "daily", "everyday", "nightly"]
    private static let timeOfDayWords: Set<String> = [
        "morning", "mornings", "night", "nights", "evening", "evenings", "afternoon", "afternoons",
    ]

    static func read(_ phrase: String) -> Reading {
        let words = phrase.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        var reading = Reading()

        var days = Set<String>()
        for word in words { days.formUnion(weekdayWords[word] ?? []) }
        reading.days = weekdays.filter(days.contains)

        // Which period: a word that names one wins ("first Sunday of every month",
        // "daily in summer"); then named weekdays (weekly); then a season or month of the
        // year ("every spring"); then a time of day ("every morning").
        let has = { (set: Set<String>) in words.contains(where: set.contains) }
        if has(monthWords) {
            reading.cadence = .monthly
        } else if has(yearWords) {
            reading.cadence = .yearly
        } else if has(weekWords) {
            reading.cadence = .weekly
        } else if has(dailyWords) && reading.days.isEmpty {
            reading.cadence = .daily
        } else if !reading.days.isEmpty {
            reading.cadence = .weekly
        } else if has(seasonWords) {
            reading.cadence = .yearly
        } else if has(timeOfDayWords) {
            reading.cadence = .daily
        }
        let timesPer = words.contains("twice") || words.contains("times")

        // "every other", "every second", "every 3 months", "biweekly". A count of times
        // ("twice a week", "3 times a month") is how often within the period, not a gap.
        for (index, word) in words.enumerated() where word == "every" || word == "each" {
            guard index + 1 < words.count else { continue }
            let next = words[index + 1]
            if next == "other" || next == "second" || next == "alternate" {
                reading.every = 2
            } else if let n = Int(next) ?? numbers[next], n > 1 {
                // "every 3 weeks", "every couple of months"
                var unit = index + 2
                if unit < words.count, words[unit] == "of" { unit += 1 }
                if unit < words.count, ["week", "weeks", "month", "months", "year", "years"].contains(words[unit]) {
                    reading.every = n
                }
            }
        }
        if words.contains("biweekly") || words.contains("fortnight") || words.contains("fortnightly")
            || words.contains("alternate") {
            reading.every = 2
        }
        if words.contains("quarterly") || words.contains("quarter") {
            reading.cadence = .monthly
            reading.every = 3
        }
        // Twice a year is every six months; twice a month, every other week.
        if timesPer, let per = words.firstIndex(where: { $0 == "a" || $0 == "per" }), per + 1 < words.count {
            let n = words.contains("twice") ? 2 : (words.compactMap { Int($0) ?? numbers[$0] }.first ?? 1)
            switch words[per + 1] {
            case "year" where n > 1 && 12 % n == 0:
                reading.cadence = .monthly
                reading.every = 12 / n
            case "month" where n == 2:
                reading.cadence = .weekly
                reading.every = 2
            default:
                break
            }
        }
        if reading.cadence == .daily { reading.every = 1 }   // "every other day" stays daily
        return reading
    }
}

// MARK: - Grounding: nothing that isn't in the text

enum DescribeChoresGrounding {
    /// Generic words that don't tie a chore to the text on their own.
    private static let generic: Set<String> = [
        "a", "an", "the", "and", "or", "to", "of", "in", "on", "up", "my", "our", "your",
        "do", "doing", "done", "make", "take", "clean", "cleaning", "get", "go", "chore", "chores",
    ]

    /// Common rooms, for rooms the household doesn't have yet: a new room is only
    /// created from words that name one ("the living room", "the garage"). A modifier
    /// ("laundry", "guest") only counts in front of a room word ("laundry room").
    private static let roomNouns: Set<String> = [
        "kitchen", "bathroom", "bath", "bedroom", "room", "den", "office", "garage", "basement", "attic",
        "hall", "hallway", "entry", "entryway", "foyer", "closet", "pantry", "nursery", "playroom", "mudroom",
        "study", "library", "yard", "backyard", "garden", "patio", "porch", "deck", "balcony", "shed", "loft",
        "sunroom", "gym", "workshop", "driveway", "pool",
    ]
    private static let roomModifiers: Set<String> = [
        "living", "family", "dining", "laundry", "guest", "master", "main", "kid", "kids", "upstair",
        "upstairs", "downstair", "downstairs", "powder", "front", "back", "spare", "utility", "home",
    ]

    /// The chore stays only if a meaningful word of its name appears in the text
    /// (typos forgiven): "Clean the kitchen" out of "Hello there!" is dropped.
    static func isGrounded(name: String, in text: String) -> Bool {
        let textWords = words(text)
        return words(name).filter { !generic.contains($0) }.contains { word in
            textWords.contains { similar($0, word) }
        }
    }

    /// The model's "when", kept only if at least half its words are in the text.
    static func groundedWhen(_ when: String, in text: String) -> String {
        let phrase = words(when)
        guard !phrase.isEmpty else { return "" }
        let textWords = words(text)
        let found = phrase.filter { word in textWords.contains { similar($0, word) } }.count
        return found * 2 >= phrase.count ? when.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    /// The model's room, kept only when `scope` (the chore's own words) names it: the
    /// household's room under its own spelling, or else a recognizable room, as
    /// written. "Living Room, Den" keeps its first room. When the model gave none,
    /// a room named in the chore's words is used ("the kids' bathroom").
    static func groundedRoom(_ room: String, scope: String, rooms: [String]) -> String {
        let first = room.components(separatedBy: CharacterSet(charactersIn: ",&/;"))
            .first?.components(separatedBy: " and ").first ?? room
        var candidate = first.trimmingCharacters(in: .whitespacesAndNewlines)
        for article in ["the ", "our ", "my ", "a "] where candidate.lowercased().hasPrefix(article) {
            candidate = String(candidate.dropFirst(article.count))
        }
        let candidateWords = words(candidate)
        let scopeWords = words(scope)
        let named = !candidateWords.isEmpty
            && candidateWords.allSatisfy { word in scopeWords.contains { similar($0, word) } }
        if named {
            if let own = rooms.first(where: { overlaps(words($0), candidateWords) }) { return own }
            if candidateWords.contains(where: roomNouns.contains) { return titleCased(candidate) }
        }
        return roomNamed(in: scope, rooms: rooms)
    }

    /// A room the phrase names: one of the household's rooms, or a room word with
    /// its modifiers ("upstairs bathroom" → "Upstairs Bathroom"); "" if none.
    static func roomNamed(in phrase: String, rooms: [String]) -> String {
        let phraseWords = words(phrase)
        let own = rooms.filter { overlaps(words($0), phraseWords, whole: false) }
            .max { words($0).count < words($1).count }
        if let own { return own }
        let raw = phrase.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let folded = raw.map { words($0).first ?? "" }
        guard let head = folded.firstIndex(where: roomNouns.contains) else { return "" }
        var start = head
        while start > 0, roomModifiers.contains(folded[start - 1]) { start -= 1 }
        var end = head
        while end + 1 < folded.count, roomNouns.contains(folded[end + 1]) { end += 1 }
        return titleCased(raw[start...end].joined(separator: " "))
    }

    private static func titleCased(_ text: String) -> String {
        text.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// Two room names refer to the same room: every word of the shorter one starts a
    /// word of the longer ("Kids Bath" / "kids bathroom").
    /// With `whole: false`, `a` (a room name) only has to appear inside `b` (a phrase).
    private static func overlaps(_ a: [String], _ b: [String], whole: Bool = true) -> Bool {
        let (short, long) = !whole || a.count <= b.count ? (a, b) : (b, a)
        guard !short.isEmpty else { return false }
        return short.allSatisfy { word in long.contains { $0 == word || $0.hasPrefix(word) || word.hasPrefix($0) } }
    }

    /// Lowercased words, "s" plurals folded (bathrooms → bathroom), apostrophes dropped.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map { $0.count > 3 && $0.hasSuffix("s") && !$0.hasSuffix("ss") ? String($0.dropLast()) : $0 }
    }

    /// Equal, or one typo apart for words of four letters or more ("vacum" ≈ "vacuum").
    static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard min(a.count, b.count) >= 4, abs(a.count - b.count) <= 1 else { return false }
        return editDistance(Array(a), Array(b)) <= 1
    }

    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        var previous = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var current = [i + 1]
            for (j, cb) in b.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (ca == cb ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }

    /// The part of the text a chore comes from: the sentence or clause holding most of
    /// its name's words (and its "when"), so a room named for one chore in a list
    /// ("laundry on Sundays, bathrooms on Saturdays") doesn't land on its neighbor.
    static func clause(for name: String, when: String, in text: String) -> String {
        let clauses = text.components(separatedBy: CharacterSet(charactersIn: ".;,!?\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let nameWords = words(name).filter { !generic.contains($0) }
        let whenWords = words(when)
        func score(_ clause: String) -> Int {
            let clauseWords = words(clause)
            let hits = { (list: [String]) in list.filter { word in clauseWords.contains { similar($0, word) } }.count }
            return hits(nameWords) * 2 + hits(whenWords)
        }
        guard let best = clauses.max(by: { score($0) < score($1) }), score(best) > 0 else { return text }
        return best
    }

    /// The model's raw chore → what the app gets: dropped if it isn't in the text; its
    /// days and interval read from its own "when" words; its room checked against the
    /// clause it comes from (or found there, when the model gave none).
    static func chore(name: String, when: String, room: String, cadence: ChoreCadence,
                      text: String, rooms: [String]) -> DescribedChore? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, isGrounded(name: name, in: text) else { return nil }
        let when = groundedWhen(when, in: text)
        let reading = ScheduleWords.read(when)
        let resolved = reading.cadence ?? cadence
        return DescribedChore(name: name, cadence: resolved,
                              days: resolved == .daily ? [] : reading.days,
                              every: resolved == .daily ? 1 : reading.every,
                              room: groundedRoom(room, scope: clause(for: name, when: when, in: text), rooms: rooms),
                              when: when)
    }
}

// MARK: - Engine (iOS / macOS 27)

#if canImport(FoundationModels)

@available(iOS 27.0, macOS 27.0, *)
@Generable(description: "The chores someone described")
struct DescribedChoresOutput {
    @Guide(description: "Each chore the text names, in order; empty if it names none", .maximumCount(20))
    var chores: [DescribedChoreOutput]
}

@available(iOS 27.0, macOS 27.0, *)
@Generable
struct DescribedChoreOutput {
    @Guide(description: "The chore as a short command that starts with a verb, spelled correctly")
    var name: String

    @Guide(description: "The words from the text that say when or how often, or empty")
    var when: String

    @Guide(description: "The room the text names for this chore, or empty")
    var room: String

    @Guide(description: "How often the chore repeats")
    var cadence: CadenceOutput
}

@available(iOS 27.0, macOS 27.0, *)
enum DescribeChoresEngine {
    // Greedy: the same words give the same chores (reproducible eval, stable retry).
    private static let options = GenerationOptions(samplingMode: .greedy)

    /// Streams the chores as they're read; the last element is the full list. A chore
    /// appears once all of its fields are complete.
    static func streamChores(from text: String, rooms: [String]) -> AsyncThrowingStream<[DescribedChore], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = LanguageModelSession(instructions: DescribeChoresPrompts.instructions)
                    let stream = session.streamResponse(
                        to: DescribeChoresPrompts.prompt(text: text, rooms: rooms),
                        generating: DescribedChoresOutput.self, options: options)
                    for try await snapshot in stream {
                        continuation.yield(chores(from: snapshot.content, text: text, rooms: rooms))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: RoomVisionEngine.mapError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One-shot variant (eval harness): the full list plus token usage.
    static func chores(from text: String, rooms: [String]) async throws -> ([DescribedChore], RoomVisionUsage) {
        do {
            let session = LanguageModelSession(instructions: DescribeChoresPrompts.instructions)
            let response = try await session.respond(
                to: DescribeChoresPrompts.prompt(text: text, rooms: rooms),
                generating: DescribedChoresOutput.self, options: options)
            let usage = response.usage
            let chores = response.content.chores.compactMap { output in
                DescribeChoresGrounding.chore(name: output.name, when: output.when, room: output.room,
                                              cadence: output.cadence.cadence, text: text, rooms: rooms)
            }
            return (chores, RoomVisionUsage(inputTokens: usage.input.totalTokenCount, outputTokens: usage.output.totalTokenCount))
        } catch {
            throw RoomVisionEngine.mapError(error)
        }
    }

    private static func chores(from partial: DescribedChoresOutput.PartiallyGenerated,
                               text: String, rooms: [String]) -> [DescribedChore] {
        (partial.chores ?? []).compactMap { chore in
            guard let name = chore.name, let when = chore.when, let room = chore.room,
                  let cadence = chore.cadence else { return nil }
            return DescribeChoresGrounding.chore(name: name, when: when, room: room, cadence: cadence.cadence,
                                                 text: text, rooms: rooms)
        }
    }
}

#endif
