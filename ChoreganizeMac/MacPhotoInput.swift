import AppKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// Getting a photo in on the Mac (#121). A Mac brings photos to the app rather than
// opening a camera: drag and drop (Photos, Finder, Safari, Messages), paste, Continuity
// Camera (File ▸ Import from iPhone ▸ Take Photo), the Photos picker, or Open….
// Every path ends in RoomPhoto.prepare, same as iPhone.

/// Opens a Mac photo flow, optionally with the photo already in hand (dropped or pasted).
struct MacPhotoRequest: Identifiable {
    let id = UUID()
    var photo: CGImage?
}

enum MacPhotoLoader {
    /// What a drop, a paste, or a Continuity Camera import may carry.
    static let acceptedTypes: [UTType] = [.image, .fileURL]

    /// The first readable photo among `providers`, prepared for the model.
    static func load(_ providers: [NSItemProvider]) async -> CGImage? {
        for provider in providers {
            // A real file first (Finder, and Photos drags, which arrive as file promises).
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = await fileURL(from: provider),
               let image = RoomPhoto.prepare(contentsOf: url) {
                return image
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                if let image = await imageFromFile(provider) { return image }
                if let data = await data(from: provider), let image = RoomPhoto.prepare(data) { return image }
            }
        }
        return nil
    }

    static func load(_ item: PhotosPickerItem) async -> CGImage? {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        return RoomPhoto.prepare(data)
    }

    /// A file chosen with Open… (sandbox: user-selected, read-only).
    static func load(_ url: URL) -> CGImage? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return RoomPhoto.prepare(contentsOf: url)
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    /// The image as a file: the temporary copy only lives inside the handler, so
    /// it's decoded there.
    private static func imageFromFile(_ provider: NSItemProvider) async -> CGImage? {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(for: .image, openInPlace: false) { url, _, _ in
                continuation.resume(returning: url.flatMap { RoomPhoto.prepare(contentsOf: $0) })
            }
        }
    }

    private static func data(from provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(for: .image) { data, _ in continuation.resume(returning: data) }
        }
    }
}

extension View {
    /// Takes a photo pasted (⌘V) or imported from an iPhone with Continuity Camera
    /// (File ▸ Import from iPhone) while this view's window is focused.
    func acceptsPhotoPasteAndImport(_ onPhoto: @escaping (CGImage?) -> Void) -> some View {
        onPasteCommand(of: MacPhotoLoader.acceptedTypes) { providers in
            Task { onPhoto(await MacPhotoLoader.load(providers)) }
        }
        .importsItemProviders([.image]) { providers in
            Task { onPhoto(await MacPhotoLoader.load(providers)) }
            return true
        }
    }
}

/// The photo slot of a Mac photo sheet before a photo arrives: a drop target with
/// Photos… and Open… buttons and a pointer to Continuity Camera.
struct MacPhotoDropZone: View {
    var prompt: String
    var onPhoto: (CGImage?) -> Void

    @State private var isTargeted = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var showImporter = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            Text(prompt)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Drop or paste a photo, or take one with your iPhone: File ▸ Import from iPhone ▸ Take Photo.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Text("Choose from Photos…")
                }
                .accessibilityIdentifier("roomvision.choosePhoto")
                Button("Open…") { showImporter = true }
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                              style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
        }
        .animation(.easeOut(duration: 0.15), value: isTargeted)
        .onDrop(of: MacPhotoLoader.acceptedTypes, isTargeted: $isTargeted) { providers in
            Task { onPhoto(await MacPhotoLoader.load(providers)) }
            return true
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { onPhoto(MacPhotoLoader.load(url)) }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            pickerItem = nil
            Task { onPhoto(await MacPhotoLoader.load(item)) }
        }
    }
}

/// A chosen photo, filling its column, with what the model saw beneath it.
struct MacPhotoPanel: View {
    let photo: CGImage
    var caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // A fixed box the photo fills: scaledToFill's own (wider) size must not
            // widen the column, so the image rides an overlay.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 260)
                .overlay {
                    Image(decorative: photo, scale: 1)
                        .resizable()
                        .scaledToFill()
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)
            if !caption.isEmpty {
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Label("Analyzed on this Mac. The photo isn't saved.", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
