import SwiftUI

/// The palette: greys, one amber, one red.
///
/// Deliberately narrow. Amber marks anything active or worth reading, grey is
/// everything at rest, red is live or broken. Nothing here is decorative — a
/// coloured pixel always means something.
///
/// **Green appears in one place only: the desk.** There it says *this camera is
/// next*, opposite red for *on air*, which is the oldest signal in a gallery and
/// worth keeping. Everywhere else — node matrix, status pages — green would be a
/// second meaning for "fine" competing with amber, so it is not used.
enum Theme {

    // Copic, monochrome amber
    static let orange = Color(hex: 0xF8980A)   // YR07 Cadmium Orange — active, accent
    static let yellow = Color(hex: 0xFED040)   // Y17  Golden Yellow  — emphasised values
    static let red    = Color(hex: 0xD81030)   // R29  Lipstick Red   — live, fault

    /// Tally, and the only place green exists.
    static let program = red
    static let preview = Color(hex: 0x2FBE6A)

    // Greys
    static let bg      = Color(hex: 0x0C0C0C)
    static let panel   = Color(hex: 0x161615)
    static let raised  = Color(hex: 0x1F1F1E)
    static let line    = Color(hex: 0x2E2E2C)
    static let lineHi  = Color(hex: 0x454440)
    static let fg      = Color(hex: 0xD8D6D0)   // light grey, primary text
    static let dim     = Color(hex: 0x8E8C86)
    static let faint   = Color(hex: 0x5E5C57)
    static let dead    = Color(hex: 0x333331)

    static func label(_ size: CGFloat = 10) -> Font {
        .system(size: size, weight: .semibold, design: .default)
    }
    static func value(_ size: CGFloat = 13) -> Font {
        .system(size: size, weight: .regular, design: .default).monospacedDigit()
    }
    static func big(_ size: CGFloat = 20) -> Font {
        .system(size: size, weight: .semibold, design: .default).monospacedDigit()
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue:  Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

/// A small uppercase caption, the way rack equipment is labelled.
struct SectionLabel: View {
    let text: String
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(text.uppercased())
                .font(Theme.label())
                .tracking(1.4)
                .foregroundStyle(Theme.faint)
            Rectangle()
                .fill(Theme.line)
                .frame(height: 1)
            if let trailing {
                Text(trailing.uppercased())
                    .font(Theme.label(9))
                    .tracking(1.2)
                    .foregroundStyle(Theme.faint)
            }
        }
    }
}
