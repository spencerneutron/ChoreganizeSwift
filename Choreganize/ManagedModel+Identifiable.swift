import CoreData

// Note: the generated managed-object classes already conform to Identifiable
// (Xcode synthesizes it from the `id` attribute), so no explicit conformance is
// needed here — `.sheet(item:)` and friends work out of the box.

#if DEBUG
import SwiftUI

/// Shared in-memory context for SwiftUI previews.
enum PreviewStack {
    static let context = CoreDataStack(inMemory: true).viewContext
}
#endif
