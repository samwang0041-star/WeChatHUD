import Foundation

/// Numeric `major.minor.patch` used to compare the running app with a GitHub release tag.
struct AppVersion: Equatable, Comparable, Hashable, Sendable, Codable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    /// True when the original tag carried a `-beta` / `-rc` suffix.
    /// A prerelease of the same numbers is older than the release.
    let isPrerelease: Bool

    init(major: Int, minor: Int, patch: Int, isPrerelease: Bool = false) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.isPrerelease = isPrerelease
    }

    /// Accepts `1.2.0`, `v1.2.0`, `1.2`, and records a trailing `-beta` / `+build` suffix.
    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.first == "v" || text.first == "V" {
            text.removeFirst()
        }
        let isPrerelease = text.contains("-")
        if let cutoff = text.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            text = String(text[..<cutoff])
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let major = parts.first.flatMap(Int.init), major >= 0 else { return nil }
        let minor = parts.dropFirst().first.flatMap(Int.init) ?? 0
        let patch = parts.dropFirst(2).first.flatMap(Int.init) ?? 0
        guard minor >= 0, patch >= 0 else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
        self.isPrerelease = isPrerelease
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        return lhs.isPrerelease && !rhs.isPrerelease
    }

    enum CodingKeys: String, CodingKey {
        case major, minor, patch, isPrerelease
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        major = try container.decode(Int.self, forKey: .major)
        minor = try container.decode(Int.self, forKey: .minor)
        patch = try container.decode(Int.self, forKey: .patch)
        isPrerelease = try container.decodeIfPresent(Bool.self, forKey: .isPrerelease) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(major, forKey: .major)
        try container.encode(minor, forKey: .minor)
        try container.encode(patch, forKey: .patch)
        try container.encode(isPrerelease, forKey: .isPrerelease)
    }
}
