import CoreGraphics

/// How each lens has to be turned to look right on a screen.
///
/// The Orah 4i carries four sensors on two SoCs, and the two boards face
/// opposite ways. The sensors are mounted portrait, so every frame arrives on
/// its side — and the pair on the second board arrives upside down relative to
/// the pair on the first. Seen plainly on the output monitor: the labels in
/// `0_0` and `0_1` read upside down while `1_0` and `1_1` read the right way up.
///
/// **This is display only.** What leaves for the stitcher must stay exactly as
/// the camera sent it: the calibration describes the lenses in the orientation
/// they arrive in, and turning the pixels would turn the seams with them.
public enum LensOrientation {

    /// Radians, clockwise-positive on screen.
    public static func displayRotation(forLens index: Int) -> CGFloat {
        switch index {
        case 0, 1: .pi / 2      // 0_0, 0_1 — the inverted board
        default:  -.pi / 2      // 1_0, 1_1
        }
    }

    /// The picture is portrait once it is the right way up.
    public static let displayAspect: CGFloat = 1440.0 / 1920.0
}
