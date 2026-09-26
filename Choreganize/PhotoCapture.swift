#if os(iOS)
import PhotosUI
import SwiftUI
import UIKit

// Photo input shared by Snap a Room (#105) and photo check-off (#107): the camera,
// the system photo picker, and a DEBUG-only test photo for UI tests. Every path ends
// in RoomPhoto.prepare, so the model always gets the same kind of image.

/// "Take Photo" / "Choose from Photos". Hands back the prepared image, or nil when
/// the photo couldn't be read. Without a camera (Simulator), the picker is primary.
struct PhotoSourceButtons: View {
    var onPhoto: (CGImage?) -> Void

    @State private var showCamera = false
    @State private var pickerItem: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 12) {
            if CameraPicker.isAvailable {
                Button { showCamera = true } label: {
                    Label("Take Photo", systemImage: "camera.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("roomvision.takePhoto")

                picker.buttonStyle(.bordered)
            } else {
                picker.buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.large)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { data in onPhoto(RoomPhoto.prepare(data)) }
                .ignoresSafeArea()
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            pickerItem = nil
            Task { onPhoto(await PhotoInput.load(item)) }
        }
    }

    private var picker: some View {
        PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
            Label("Choose from Photos", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("roomvision.choosePhoto")
    }
}

enum PhotoInput {
    /// Loads a picked photo's full data (HEIC/JPEG) and prepares it for the model.
    static func load(_ item: PhotosPickerItem) async -> CGImage? {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        return RoomPhoto.prepare(data)
    }

    #if DEBUG
    /// UI tests and screenshots: a photo path handed in through the environment
    /// (`CHOREGANIZE_ROOM_PHOTO`), used in place of the camera or picker.
    static var testPhoto: CGImage? {
        guard let path = ProcessInfo.processInfo.environment["CHOREGANIZE_ROOM_PHOTO"], !path.isEmpty else { return nil }
        return RoomPhoto.prepare(contentsOf: URL(fileURLWithPath: path))
    }
    #endif
}

/// The system camera, returning JPEG data so the capture's orientation travels with
/// it (RoomPhoto.prepare applies it).
struct CameraPicker: UIViewControllerRepresentable {
    var onCapture: (Data) -> Void

    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker

        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
                parent.onCapture(data)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
#endif
