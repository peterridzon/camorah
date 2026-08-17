import SwiftUI
import OrahKit

/// One item in a strip of choices.
///
/// There are two strips stacked at the top of the desk — which screen you are
/// on, and which multiview generator you are looking at — and they were drawn
/// in two different languages: one used a filled block with tiny tracked
/// capitals, the other an outlined pill with a lamp and a monospaced name. Two
/// rows of the same kind of control, an inch apart, disagreeing about what
/// "selected" looks like.
///
/// So both are built from this. Same height, same corner, same type, and one
/// meaning for amber: **this is the one that is live**. The only difference
/// left between them is the words, which is the only difference there should
/// ever have been.
@MainActor
struct StripButton: View {
    let title: String
    /// The quieter half — where a generator's picture goes, and how it is laid
    /// out. Absent on the mode switch, which has nothing to add.
    var detail: String? = nil
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(1.6)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(selected ? Color(hex: 0x3A2E14) : Theme.faint)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(selected ? Color(hex: 0x141417) : Theme.dim)
            .padding(.horizontal, 13).padding(.vertical, 8)
            .frame(height: 34)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? AnyShapeStyle(Theme.amberGradient)
                                   : AnyShapeStyle(Theme.raised))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Theme.amberGlow : Theme.line, lineWidth: 1)
            }
            .shadow(color: selected ? Theme.amber.opacity(0.35) : .clear, radius: 8)
        }
        .buttonStyle(.plain)
    }
}

/// The row the buttons sit in, so the two strips also share their spacing.
@MainActor
struct Strip<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 7) {
            content()
            Spacer(minLength: 0)
        }
    }
}
