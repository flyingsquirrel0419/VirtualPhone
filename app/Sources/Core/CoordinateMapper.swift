import Foundation

/// A point in either space, independent of CoreGraphics so it builds on Linux.
public struct Point2D: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct Size2D: Equatable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
}

/// Maps a touch in the host view to a pixel of the guest framebuffer.
///
/// The guest picture is drawn aspect-fit and centred in the view, so there
/// may be bars on two sides; a touch on a bar is outside the guest. The
/// emulated panel wants absolute pixels — the finger where it is — not a
/// cursor moved toward it.
public struct CoordinateMapper: Equatable, Sendable {
    public let view: Size2D
    public let guest: Size2D

    public init(view: Size2D, guestWidth: Int, guestHeight: Int) {
        self.view = view
        self.guest = Size2D(width: Double(guestWidth), height: Double(guestHeight))
    }

    /// Guest pixels per view point.
    public var scale: Double {
        guard view.width > 0, view.height > 0, guest.width > 0, guest.height > 0 else { return 0 }
        return min(view.width / guest.width, view.height / guest.height)
    }

    /// Where the picture sits inside the view, in view points.
    public var contentRect: (origin: Point2D, size: Size2D) {
        let s = scale
        let size = Size2D(width: guest.width * s, height: guest.height * s)
        let origin = Point2D(x: (view.width - size.width) / 2, y: (view.height - size.height) / 2)
        return (origin, size)
    }

    /// nil when the point is outside the picture (on a letterbox bar).
    public func guestPixel(for point: Point2D) -> (x: Int32, y: Int32)? {
        let s = scale
        guard s > 0 else { return nil }
        let rect = contentRect
        let gx = (point.x - rect.origin.x) / s
        let gy = (point.y - rect.origin.y) / s
        guard gx >= 0, gy >= 0, gx < guest.width, gy < guest.height else { return nil }
        return (Int32(gx.rounded(.down)), Int32(gy.rounded(.down)))
    }

    /// Like `guestPixel`, but pins a point outside the picture to its edge.
    /// Used while a finger that started inside drags across a bar, so the
    /// guest sees the drag reach the edge instead of a lift.
    public func clampedGuestPixel(for point: Point2D) -> (x: Int32, y: Int32)? {
        let s = scale
        guard s > 0 else { return nil }
        let rect = contentRect
        let gx = min(max((point.x - rect.origin.x) / s, 0), guest.width - 1)
        let gy = min(max((point.y - rect.origin.y) / s, 0), guest.height - 1)
        return (Int32(gx.rounded(.down)), Int32(gy.rounded(.down)))
    }
}
