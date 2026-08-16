import Foundation

nonisolated enum ListeningDimension: String, CaseIterable, Identifiable, Codable, Sendable {
    case artists = "Artists"
    case genres = "Genres"
    case albums = "Albums"
    case songs = "Songs"

    var id: String { rawValue }
}

nonisolated enum TimestampQuality: String, Codable, Sendable {
    case exact
    case partial
}

/// A literal observation of one track's play-count state when My Pod read the iPod.
/// Observations are preserved even when only one exact timestamp is available for
/// several newly reported plays, so future tooling can reinterpret the original
/// evidence without inventing history today.
nonisolated struct ListeningObservation: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let schemaVersion: Int
    let sessionID: UUID
    let observedAt: Date
    let deviceID: String
    let trackDBID: UInt64
    let trackID: UInt32
    let title: String
    let artist: String
    let album: String
    let genre: String
    let durationMS: Int
    let playCount: Int
    let recentPlayCount: Int
    let playCountDelta: Int
    let lastPlayedAt: Date?
    let exactTimestampCount: Int
    let untimestampedPlayCount: Int
}

/// One exact, provider-submittable listen reconstructed from the iPod.
nonisolated struct ListenRecord: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let schemaVersion: Int
    let sessionID: UUID
    let harvestedAt: Date
    let playedAt: Date
    let source: String
    let deviceID: String
    let trackDBID: UInt64
    let trackID: UInt32
    let title: String
    let artist: String
    let album: String
    let genre: String
    let durationMS: Int
    let timestampQuality: TimestampQuality
}

nonisolated enum ScrobbleProviderKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case lastFM = "lastfm"
    case listenBrainz = "listenbrainz"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lastFM: "Last.fm"
        case .listenBrainz: "ListenBrainz"
        }
    }

    var systemImage: String {
        switch self {
        case .lastFM: "dot.radiowaves.left.and.right"
        case .listenBrainz: "brain.head.profile"
        }
    }
}

nonisolated struct ProviderDeliveryRecord: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let schemaVersion: Int
    let listenID: UUID
    let provider: ScrobbleProviderKind
    let deliveredAt: Date
}

nonisolated struct ListeningHistoryManifest: Codable, Sendable {
    let schemaVersion: Int
    let exportedAt: Date
    let application: String
    let observationCount: Int
    let listenCount: Int
    let deliveryCount: Int
}

nonisolated struct DistributionBucket: Identifiable, Sendable, Equatable {
    let id: String
    let label: String
    let count: Int
    let colorIndex: Int

    func percentage(of total: Int) -> Int {
        guard total > 0 else { return 0 }
        return Int((Double(count) / Double(total) * 100).rounded())
    }
}

nonisolated struct ScrobbleActivityRow: Identifiable, Sendable, Equatable {
    let id: String
    let date: Date
    let artist: String
    let track: String
    let provider: String
    let status: String
    let statusKind: StatusKind

    nonisolated enum StatusKind: String, Sendable, Equatable {
        case archived
        case queued
        case submitted
        case failed
    }
}

nonisolated struct TrackPlayWatermark: Codable, Sendable, Equatable {
    var playCount: Int
    var lastPlayedAt: Date?
}
