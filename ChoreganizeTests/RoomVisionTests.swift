import Testing
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
#if canImport(FoundationModels)
import FoundationModels
#endif
@testable import Choreganize

/// Coverage for the model-free parts of the room-vision engine (#105 / #107):
/// prompt building, the check's output keys, photo preparation, availability
/// hints, and error mapping. Prompt *quality* is measured by tools/fm-eval on
/// real photos, not here.
struct RoomVisionTests {

    // MARK: Check keys

    @Test func checkKeysAreIndexAlignedUniqueAndSafe() {
        let long = String(repeating: "Scrub ", count: 20)
        let keys = RoomVisionPrompts.checkKeys(for: [
            "Do the dishes", "do the dishes", "Say \"hi\" \\ now", "   ", "observations", long, "Line\nbreak",
        ])
        #expect(keys.count == 7)
        #expect(keys[0] == "Do the dishes")
        #expect(keys[1] == "do the dishes (2)")          // case-insensitive collision
        #expect(keys[2] == "Say hi  now")                 // quotes / backslashes dropped
        #expect(keys[3] == "Chore")                       // blank gets a placeholder
        #expect(keys[4] == "observations (2)")            // never collides with the reserved key
        #expect(keys[5].count == RoomVisionPrompts.maxNameLength)
        #expect(keys[6] == "Line break")
        #expect(Set(keys.map { $0.lowercased() }).count == keys.count)
    }

    // MARK: Prompts

    @Test func suggestPromptWithoutContextIsJustTheAsk() {
        #expect(RoomVisionPrompts.suggestPrompt(RoomVisionHomeContext())
                == "Suggest recurring chores for the room in this photo.")
    }

    @Test func suggestPromptListsRoomsAndExistingChores() {
        let home = RoomVisionHomeContext(
            roomNames: ["Kitchen", "Bathroom"],
            choresByRoom: ["Kitchen": ["Do the dishes", "Wipe down counters"], "Bathroom": [], "Garage": ["Sweep"]])
        let prompt = RoomVisionPrompts.suggestPrompt(home)
        #expect(prompt.contains("Rooms this household already has: Kitchen, Bathroom. If the photo shows one of them, use that exact name."))
        #expect(prompt.contains("- Kitchen: Do the dishes; Wipe down counters"))
        #expect(prompt.contains("- Garage: Sweep"))
        #expect(!prompt.contains("- Bathroom:"))          // rooms without chores aren't listed
    }

    @Test func suggestPromptCapsExistingChores() {
        let many = (1...200).map { "Chore \($0)" }
        let prompt = RoomVisionPrompts.suggestPrompt(RoomVisionHomeContext(choresByRoom: ["A": many, "B": many]))
        let listed = prompt.components(separatedBy: "Chore ").count - 1
        #expect(listed == RoomVisionPrompts.maxExistingChores)
    }

    @Test func checkPromptNamesTheRoomAndEachChore() {
        let prompt = RoomVisionPrompts.checkPrompt(roomName: "Kitchen", keys: ["Do the dishes", "Wipe down counters"])
        #expect(prompt == "Room: Kitchen\nChores to check:\n- Do the dishes\n- Wipe down counters")
        #expect(!RoomVisionPrompts.checkPrompt(roomName: nil, keys: ["X"]).contains("Room:"))
    }

    // MARK: Photo preparation

    @Test func photoPrepDownsizesAndBakesInOrientation() throws {
        // A 2000×1000 landscape image tagged "rotate 90° clockwise" (EXIF 6) must come
        // out upright (portrait) and no larger than the 1024 px cap.
        let data = try #require(Self.jpeg(width: 2000, height: 1000, orientation: 6))
        let image = try #require(RoomPhoto.prepare(data))
        #expect(image.width == 512)
        #expect(image.height == 1024)
    }

    @Test func photoPrepKeepsSmallImagesSmall() throws {
        let data = try #require(Self.jpeg(width: 300, height: 200, orientation: 1))
        let image = try #require(RoomPhoto.prepare(data))
        #expect(image.width == 300)
        #expect(image.height == 200)
    }

    @Test func unreadablePhotoIsNil() {
        #expect(RoomPhoto.prepare(Data("not an image".utf8)) == nil)
    }

    // MARK: Availability + errors

    @Test func availabilityHintsOnlyForFixableStates() {
        #expect(RoomVisionAvailability.available.hint == nil)
        #expect(RoomVisionAvailability.unsupported.hint == nil)
        #expect(RoomVisionAvailability.appleIntelligenceOff.hint != nil)
        #expect(RoomVisionAvailability.preparing.hint != nil)
        #expect(RoomVisionAvailability.appleIntelligenceOff.isOfferable)
        #expect(!RoomVisionAvailability.unsupported.isOfferable)
        #expect(!RoomVisionAvailability.preparing.isAvailable)
    }

    @Test func modelErrorsMapToFriendlyErrors() {
        #if canImport(FoundationModels)
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        func mapped(_ error: Error) -> RoomVisionError? { RoomVisionEngine.mapError(error) as? RoomVisionError }
        #expect(mapped(LanguageModelError.guardrailViolation(.init(debugDescription: "x"))) == .declined)
        #expect(mapped(LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "x"))) == .busy)
        #expect(mapped(LanguageModelError.contextSizeExceeded(.init(contextSize: 8192, tokenCount: 9000, debugDescription: "x"))) == .failed)
        #expect(mapped(LanguageModelSession.Error.concurrentRequests) == .busy)
        #expect(mapped(CocoaError(.fileReadUnknown)) == .failed)
        #expect(RoomVisionEngine.mapError(CancellationError()) is CancellationError)
        #endif
    }

    // MARK: Live model (opt-in)

    /// Runs one real suggest + check on this runtime's on-device model. Opt-in, since
    /// it needs Apple Intelligence and takes a few seconds:
    /// `TEST_RUNNER_CHOREGANIZE_LIVE_FM=1 xcodebuild test … -only-testing:ChoreganizeTests/RoomVisionTests/liveModelRoundTrip`
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CHOREGANIZE_LIVE_FM"] == "1"))
    func liveModelRoundTrip() async throws {
        #if canImport(FoundationModels)
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        try #require(RoomVisionAvailability.current == .available)
        let data = try #require(Self.jpeg(width: 1024, height: 768, orientation: 1))
        let image = try #require(RoomPhoto.prepare(data))
        let (suggestion, usage) = try await RoomVisionEngine.suggestions(for: image, home: RoomVisionHomeContext())
        #expect((5...8).contains(suggestion.chores.count))
        #expect(suggestion.chores.allSatisfy { !$0.name.isEmpty })
        #expect(usage.inputTokens > 0)
        let (check, _) = try await RoomVisionEngine.check(["Make the bed", "Water the plants"], roomName: "Bedroom", in: image)
        #expect(check.verdicts.count == 2)
        #endif
    }

    // MARK: Helpers

    /// A JPEG of a simple two-tone image with the given EXIF orientation.
    static func jpeg(width: Int, height: Int, orientation: Int) -> Data? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0.85, green: 0.8, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.3, green: 0.35, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 3))
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
