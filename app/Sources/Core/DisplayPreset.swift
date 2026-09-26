import Foundation

/// The guest panel's resolution. Not a different device: the machine is always
/// an iPhone 11 (T8030); a smaller panel is simply less work for the emulated
/// cores.
///
/// A framebuffer row has to be a multiple of sixteen bytes, which is why the
/// iPhone 8 preset is 752 wide rather than 750 — at 750 the guest never
/// finishes booting (observed upstream in Inferno-iOS).
public enum DisplayPreset: String, Codable, CaseIterable, Sendable {
    case iphone11
    case iphone8
    case iphoneSE

    public var width: Int {
        switch self {
        case .iphone11: return 828
        case .iphone8: return 752
        case .iphoneSE: return 640
        }
    }

    public var height: Int {
        switch self {
        case .iphone11: return 1792
        case .iphone8: return 1336
        case .iphoneSE: return 1136
        }
    }

    /// Kept at two for all presets, so iOS uses the same @2x artwork.
    public var scale: Int { 2 }

    public var displayName: String {
        switch self {
        case .iphone11: return "iPhone 11"
        case .iphone8: return "iPhone 8"
        case .iphoneSE: return "iPhone SE"
        }
    }

    /// Bytes per row of an a8r8g8b8 frame.
    public var stride: Int { width * 4 }

    public static func rowIsAligned(width: Int) -> Bool {
        width > 0 && (width * 4) % 16 == 0
    }
}
