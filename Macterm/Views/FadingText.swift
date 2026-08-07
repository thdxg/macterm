import SwiftUI

/// A one-line text that handles overflow by fading out at its trailing edge
/// instead of truncating — in narrow slots (sidebar rows, split segments) an
/// ellipsis burns several characters that could still be read.
///
/// Two copies of the text, because the fade needs glyphs the layout system
/// would otherwise truncate, yet the layout must never see their full width:
/// the LAYOUT element is a normal truncating `Text` rendered invisibly, so
/// the view stays exactly as compressible as the `Text` it replaces (a
/// `fixedSize` text in the layout would make every container demand the full
/// text width — equal-width siblings stop re-balancing, and an overflowing
/// text gets hard-clipped by its row's edge outside its own mask). The
/// VISIBLE copy draws at intrinsic width inside a layout-neutral overlay,
/// clipped to the slot by the mask, whose gradient ramp only engages when
/// the text actually overflows — a short text masked unconditionally would
/// fade its own last letters.
struct FadingText: View {
    private let text: String
    private let fadeWidth: CGFloat
    @State
    private var textWidth: CGFloat = 0
    @State
    private var containerWidth: CGFloat = 0

    /// - Parameter fadeWidth: width of the fade-out ramp at the trailing edge.
    init(_ text: String, fadeWidth: CGFloat = 18) {
        self.text = text
        self.fadeWidth = fadeWidth
    }

    private var overflows: Bool { textWidth > containerWidth + 0.5 }

    var body: some View {
        Text(text)
            .lineLimit(1)
            .opacity(0)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
            .overlay(alignment: .leading) {
                // Color.clear adopts exactly the slot's size, so the mask —
                // and with it the clip — is bound to the slot, not to the
                // rigid text.
                Color.clear
                    .overlay(alignment: .leading) {
                        Text(text)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
                    }
                    .mask(alignment: .leading) {
                        if overflows {
                            HStack(spacing: 0) {
                                Rectangle()
                                LinearGradient(
                                    gradient: Gradient(colors: [.black, .clear]),
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(width: fadeWidth)
                            }
                        } else {
                            Rectangle()
                        }
                    }
            }
    }
}
