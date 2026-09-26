import Foundation

/// What build this is, from the Info.plist keys app/build.sh writes.
public struct BuildMetadata: Equatable, Sendable {
    public let productName: String
    public let version: String
    public let build: String
    public let commit: String
    public let channel: String

    public init(productName: String, version: String, build: String, commit: String, channel: String) {
        self.productName = productName
        self.version = version
        self.build = build
        self.commit = commit
        self.channel = channel
    }

    public init(infoDictionary info: [String: Any]) {
        self.productName = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? "VirtualPhone"
        self.version = info["CFBundleShortVersionString"] as? String ?? "0.0.0"
        self.build = info["CFBundleVersion"] as? String ?? "0"
        self.commit = info["VPGitCommit"] as? String ?? "unknown"
        self.channel = info["VPReleaseChannel"] as? String ?? "dev"
    }

    public var shortCommit: String { String(commit.prefix(7)) }

    /// "VirtualPhone 0.1.0" / "Build abc1234"
    public var title: String { "\(productName) \(version)" }
    public var subtitle: String {
        channel == "stable" ? "Build \(shortCommit)" : "Build \(shortCommit) · \(channel)"
    }
}

/// Semantic version, for tag/version checks and ordering.
public struct SemanticVersion: Comparable, CustomStringConvertible, Sendable {
    public let major: Int, minor: Int, patch: Int
    public let prerelease: String?

    public init?(_ text: String) {
        var s = Substring(text)
        if s.hasPrefix("v") { s = s.dropFirst() }
        let parts = s.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let nums = parts.first?.split(separator: ".").map { Int($0) } ?? []
        guard nums.count == 3, let a = nums[0], let b = nums[1], let c = nums[2], a >= 0, b >= 0, c >= 0 else { return nil }
        major = a; minor = b; patch = c
        prerelease = parts.count > 1 ? String(parts[1]) : nil
        if let pre = prerelease, pre.isEmpty { return nil }
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.map { "-\($0)" } ?? "")
    }

    public static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) {
            return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
        }
        switch (a.prerelease, b.prerelease) {
        case (nil, nil): return false
        case (nil, _): return false
        case (_, nil): return true
        case let (x?, y?): return x < y
        }
    }
}
