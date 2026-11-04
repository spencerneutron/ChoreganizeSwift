#if os(iOS)
import SwiftUI

// iPhone Duo support (iOS 27.1+). Everything here degrades to "horizontal bars" on
// older systems and on devices without a vertical bar, so callers never branch on
// availability themselves. See .claude-work/current/PLAN-iphone-duo.md.

/// Hands `content` whether the system lays this hierarchy's bars out vertically
/// (iPhone Duo: the outer display, and the inner display in landscape). Always
/// `false` before iOS 27.1.
struct VerticalBarReader<Content: View>: View {
    @ViewBuilder let content: (_ isVertical: Bool) -> Content

    var body: some View {
        if #available(iOS 27.1, *) {
            VerticalBarEdgeReader(content: content)
        } else {
            content(false)
        }
    }
}

@available(iOS 27.1, *)
private struct VerticalBarEdgeReader<Content: View>: View {
    @Environment(\.toolbarVerticalEdge) private var verticalEdge
    let content: (Bool) -> Content

    var body: some View { content(verticalEdge != nil) }
}
#endif
