import Foundation

/// What one camera's picture is doing before it reaches the mix.
///
/// The cameras do not match each other — different units, different ages, and
/// no two of them expose the same. So a grade belongs to a camera, never to the
/// programme bus, and it follows that camera wherever it is switched.
///
/// It rides the **live path only**. The nodes record by stream copy, so nothing
/// here can reach the master; that is a property of the architecture rather
/// than a setting anybody can get wrong. And none of it reaches the camera
/// either — the Orah protocol has no exposure or gamma control at all, so every
/// value below is applied on this machine, in the same Metal pass as the
/// dissolve.
///
/// One consequence worth keeping in mind on a rig day: because the sensor is
/// never touched, a blown highlight or a crushed black cannot be recovered
/// here. Exposure is an install-day job; this is for matching what was
/// captured, not for rescuing what was not.
public struct ColourGrade: Codable, Sendable, Equatable {

    /// A three-channel plus master control, as on every shading panel.
    public struct Trio: Codable, Sendable, Equatable {
        public var r: Float
        public var g: Float
        public var b: Float
        /// Moves all three together. Kept separate so the wheel and the master
        /// wheel do not fight over the same numbers.
        public var y: Float

        public init(r: Float = 0, g: Float = 0, b: Float = 0, y: Float = 0) {
            self.r = r; self.g = g; self.b = b; self.y = y
        }
        public static let zero = Trio()
        public static let one  = Trio(r: 1, g: 1, b: 1, y: 1)
    }

    // The two controls under the operator's hand on an RCP.
    /// Exposure lever. −1 closed, 0 as shot, +1 open.
    public var exposure: Float = 0
    /// Puck, left to right: bends the mid-tones.
    public var gamma: Float = 0
    /// Puck, up and down: where the blacks sit.
    public var black: Float = 0

    // Trim.
    public var lift = Trio.zero
    public var gammaRGB = Trio.zero
    public var gain = Trio.one

    public var contrast: Float = 50        // 0…100, 50 = untouched
    public var pivot: Float = 0.5          // 0…1
    public var saturation: Float = 50      // 0…100, 50 = untouched
    public var lumMix: Float = 100         // 0…100
    public var hue: Float = 180            // 0…360, 180 = untouched
    public var tint: Float = 0             // −50…50

    public init() {}

    /// Whether this grade would change a single pixel.
    ///
    /// Checked on every frame: a neutral grade skips the GPU pass entirely, and
    /// on a normal show most cameras are neutral most of the time. Comparing
    /// against a fresh value is cheap and cannot drift out of step with the
    /// fields the way a hand-written list of comparisons would.
    public var isNeutral: Bool { self == ColourGrade() }

    /// Sixteen floats in the order the shader reads them.
    ///
    /// Packed here rather than in the renderer so the layout has exactly one
    /// definition. If a field is added, this is the only place that has to know.
    public var packed: [Float] {
        [exposure, gamma, black,
         lift.r + lift.y, lift.g + lift.y, lift.b + lift.y,
         gammaRGB.r + gammaRGB.y, gammaRGB.g + gammaRGB.y, gammaRGB.b + gammaRGB.y,
         gain.r * gain.y, gain.g * gain.y, gain.b * gain.y,
         (contrast - 50) / 50, pivot,
         saturation / 50,
         (hue - 180) / 180 + tint / 200]
    }
}
