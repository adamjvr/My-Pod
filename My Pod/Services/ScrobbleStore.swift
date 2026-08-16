import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class ScrobbleStore {
    private(set) var observations: [ListeningObservation] = []
    private(set) var listens: [ListenRecord] = []
    private(set) var deliveries: [ProviderDeliveryRecord] = []
    private(set) var currentSessionID: UUID?
    private(set) var currentSessionListenIDs: Set<UUID> = []
    private(set) var isHarvesting = false
    private(set) var isSubmitting = false
    private(set) var lastError: String?
    private(set) var lastSubmitAt: Date?
    private(set) var credentialRevision = 0

    var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Keys.enabled) }
    }
    var scanOnConnect: Bool {
        didSet { defaults.set(scanOnConnect, forKey: Keys.scanOnConnect) }
    }
    var autoSubmit: Bool {
        didSet { defaults.set(autoSubmit, forKey: Keys.autoSubmit) }
    }
    var retryFailures: Bool {
        didSet { defaults.set(retryFailures, forKey: Keys.retryFailures) }
    }

    private let defaults = UserDefaults.standard
    private let fm = FileManager.default
    private var watermarks: [String: TrackPlayWatermark] = [:]

    private enum Keys {
        static let enabled = "scrobble.enabled"
        static let scanOnConnect = "scrobble.scan-on-connect"
        static let autoSubmit = "scrobble.auto-submit"
        static let retryFailures = "scrobble.retry-failures"
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init() {
        self.enabled = UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? true
        self.scanOnConnect = UserDefaults.standard.object(forKey: Keys.scanOnConnect) as? Bool ?? true
        self.autoSubmit = UserDefaults.standard.object(forKey: Keys.autoSubmit) as? Bool ?? true
        self.retryFailures = UserDefaults.standard.object(forKey: Keys.retryFailures) as? Bool ?? true
        prepareStorage()
        loadStorage()
        migrateLegacyLastFMCredentials()
    }

    var historyDirectory: URL {
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("My Pod", isDirectory: true)
            .appendingPathComponent("History", isDirectory: true)
    }

    var archivePathText: String {
        historyDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    var currentSessionListens: [ListenRecord] {
        listens.filter { currentSessionListenIDs.contains($0.id) }
    }

    var configuredProviders: [ScrobbleProviderKind] {
        _ = credentialRevision
        return ScrobbleProviderKind.allCases.filter(isConfigured)
    }

    func isConfigured(_ kind: ScrobbleProviderKind) -> Bool {
        switch kind {
        case .listenBrainz:
            return !(LocalCredentialStore.get(account: ListenBrainzProvider.tokenAccount) ?? "").isEmpty
        case .lastFM:
            return LastFMProvider.isApplicationConfigured
                && !(LocalCredentialStore.get(account: LastFMProvider.sessionKeyAccount) ?? "").isEmpty
        }
    }

    private func migrateLegacyLastFMCredentials() {
        let hadUserAPIKey = !(LocalCredentialStore.get(account: LastFMProvider.legacyAPIKeyAccount) ?? "").isEmpty
        let hadUserSecret = !(LocalCredentialStore.get(account: LastFMProvider.legacyAPISecretAccount) ?? "").isEmpty
        guard hadUserAPIKey || hadUserSecret else { return }

        // Sessions created by the development UI were tied to whichever API
        // account the user pasted. They cannot safely be reused with My Pod's
        // application API account, so force one clean browser re-authorization.
        LocalCredentialStore.delete(account: LastFMProvider.legacyAPIKeyAccount)
        LocalCredentialStore.delete(account: LastFMProvider.legacyAPISecretAccount)
        LocalCredentialStore.delete(account: LastFMProvider.sessionKeyAccount)
        LocalCredentialStore.delete(account: LastFMProvider.usernameAccount)
        Log.scrobble.info("removed legacy user-entered Last.fm API credentials; browser reconnect required")
    }

    func configureListenBrainz(token: String) throws {
        try LocalCredentialStore.set(token.trimmingCharacters(in: .whitespacesAndNewlines), account: ListenBrainzProvider.tokenAccount)
        credentialRevision += 1
    }

    func configureLastFM(username: String, sessionKey: String) throws {
        try LocalCredentialStore.set(
            username.trimmingCharacters(in: .whitespacesAndNewlines),
            account: LastFMProvider.usernameAccount
        )
        try LocalCredentialStore.set(
            sessionKey.trimmingCharacters(in: .whitespacesAndNewlines),
            account: LastFMProvider.sessionKeyAccount
        )
        // Clean up credentials written by the earlier development UI. App-level
        // credentials now come from the build, never from an end user.
        LocalCredentialStore.delete(account: LastFMProvider.legacyAPIKeyAccount)
        LocalCredentialStore.delete(account: LastFMProvider.legacyAPISecretAccount)
        credentialRevision += 1
    }

    func accountName(for kind: ScrobbleProviderKind) -> String? {
        _ = credentialRevision
        switch kind {
        case .listenBrainz:
            return nil
        case .lastFM:
            let username = LocalCredentialStore.get(account: LastFMProvider.usernameAccount)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return username.isEmpty ? nil : username
        }
    }

    func disconnect(_ kind: ScrobbleProviderKind) {
        switch kind {
        case .listenBrainz:
            LocalCredentialStore.delete(account: ListenBrainzProvider.tokenAccount)
        case .lastFM:
            LocalCredentialStore.delete(account: LastFMProvider.sessionKeyAccount)
            LocalCredentialStore.delete(account: LastFMProvider.usernameAccount)
            LocalCredentialStore.delete(account: LastFMProvider.legacyAPIKeyAccount)
            LocalCredentialStore.delete(account: LastFMProvider.legacyAPISecretAccount)
        }
        credentialRevision += 1
    }

    func harvest(deviceInfo: DeviceInfo?, device: IPodDevice?) async {
        guard enabled, scanOnConnect, !isHarvesting, let device else { return }
        isHarvesting = true
        defer { isHarvesting = false }
        lastError = nil

        let info: DeviceInfo?
        if let deviceInfo {
            info = deviceInfo
        } else {
            info = await device.deviceInfo()
        }
        let deviceID = info?.uuid?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? info?.mountpoint.lastPathComponent
            ?? device.mountpoint.lastPathComponent
        let tracks = await device.tracks()
        let sessionID = UUID()
        let observedAt = Date()
        var newListenIDs = Set<UUID>()
        var newListenCount = 0
        var changedTrackCount = 0

        for track in tracks {
            let stableTrack = track.dbid != 0 ? track.dbid : UInt64(track.id)
            let key = "\(deviceID)|\(stableTrack)"
            let previous = watermarks[key]

            let delta: Int
            if let previous {
                delta = track.playCount >= previous.playCount
                    ? track.playCount - previous.playCount
                    : max(track.recentPlayCount, 0)
            } else {
                // On first contact, only the iPod's "since last sync" counter is
                // evidence of new plays. The lifetime count becomes our baseline.
                delta = max(track.recentPlayCount, 0)
            }

            let lastAdvanced: Bool = {
                guard let last = track.lastPlayed else { return false }
                guard let previousLast = previous?.lastPlayedAt else { return true }
                return last > previousLast
            }()

            if delta > 0 || (track.recentPlayCount > 0 && lastAdvanced) {
                changedTrackCount += 1
                let hasExactTimestamp = track.lastPlayed != nil && lastAdvanced
                let observation = ListeningObservation(
                    id: UUID(),
                    schemaVersion: 1,
                    sessionID: sessionID,
                    observedAt: observedAt,
                    deviceID: deviceID,
                    trackDBID: stableTrack,
                    trackID: track.id,
                    title: track.title,
                    artist: track.artist,
                    album: track.album,
                    genre: track.genre,
                    durationMS: track.durationMS,
                    playCount: track.playCount,
                    recentPlayCount: track.recentPlayCount,
                    playCountDelta: delta,
                    lastPlayedAt: track.lastPlayed,
                    exactTimestampCount: hasExactTimestamp ? 1 : 0,
                    untimestampedPlayCount: max(delta - (hasExactTimestamp ? 1 : 0), 0)
                )
                observations.append(observation)
                try? appendLine(observation, to: observationsURL)

                if hasExactTimestamp, let playedAt = track.lastPlayed {
                    let listen = ListenRecord(
                        id: UUID(),
                        schemaVersion: 1,
                        sessionID: sessionID,
                        harvestedAt: observedAt,
                        playedAt: playedAt,
                        source: "ipod",
                        deviceID: deviceID,
                        trackDBID: stableTrack,
                        trackID: track.id,
                        title: track.title,
                        artist: track.artist,
                        album: track.album,
                        genre: track.genre,
                        durationMS: track.durationMS,
                        timestampQuality: delta > 1 ? .partial : .exact
                    )
                    listens.append(listen)
                    newListenIDs.insert(listen.id)
                    newListenCount += 1
                    try? appendLine(listen, to: listensURL)
                }
            }

            watermarks[key] = TrackPlayWatermark(playCount: track.playCount, lastPlayedAt: track.lastPlayed)
        }

        currentSessionID = sessionID
        currentSessionListenIDs = newListenIDs
        persistWatermarks()
        Log.scrobble.info("history harvest: device=\(deviceID) tracks=\(tracks.count) changed=\(changedTrackCount) exact=\(newListenCount)")

        if autoSubmit, newListenCount > 0, !configuredProviders.isEmpty {
            await submitNow()
        }
    }

    func distribution(_ dimension: ListeningDimension) -> [DistributionBucket] {
        let session = currentSessionListens
        guard !session.isEmpty else { return [] }
        var counts: [String: Int] = [:]
        for listen in session {
            let label: String
            switch dimension {
            case .artists:
                label = listen.artist.nilIfBlank ?? "Unknown Artist"
            case .genres:
                label = listen.genre.nilIfBlank ?? "Unknown Genre"
            case .albums:
                label = listen.album.nilIfBlank ?? "Unknown Album"
            case .songs:
                label = listen.title.nilIfBlank ?? "Unknown Track"
            }
            counts[label, default: 0] += 1
        }

        let sorted = counts.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
        }
        if sorted.count <= 6 {
            return sorted.enumerated().map { index, pair in
                DistributionBucket(id: pair.key, label: pair.key, count: pair.value, colorIndex: index)
            }
        }
        let head = Array(sorted.prefix(5))
        let other = sorted.dropFirst(5).reduce(0) { $0 + $1.value }
        var buckets = head.enumerated().map { index, pair in
            DistributionBucket(id: pair.key, label: pair.key, count: pair.value, colorIndex: index)
        }
        buckets.append(DistributionBucket(id: "__other__", label: "Other", count: other, colorIndex: 5))
        return buckets
    }

    func pendingCount(for kind: ScrobbleProviderKind) -> Int {
        let delivered = Set(deliveries.lazy.filter { $0.provider == kind }.map(\.listenID))
        return listens.reduce(into: 0) { count, listen in
            if !delivered.contains(listen.id) { count += 1 }
        }
    }

    func submittedCount(for kind: ScrobbleProviderKind) -> Int {
        deliveries.reduce(into: 0) { count, record in
            if record.provider == kind { count += 1 }
        }
    }

    func submitNow() async {
        guard enabled, !isSubmitting else { return }
        let providers = configuredProviders
        guard !providers.isEmpty else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        lastError = nil

        for kind in providers {
            let delivered = Set(deliveries.lazy.filter { $0.provider == kind }.map(\.listenID))
            let pending = listens.filter { !delivered.contains($0.id) }
            guard !pending.isEmpty else { continue }

            let batchSize = kind == .lastFM ? 1 : 100
            for batch in pending.chunked(into: batchSize) {
                do {
                    try await submit(batch, to: kind)
                    for listen in batch {
                        let record = ProviderDeliveryRecord(
                            id: UUID(),
                            schemaVersion: 1,
                            listenID: listen.id,
                            provider: kind,
                            deliveredAt: Date()
                        )
                        deliveries.append(record)
                        try? appendLine(record, to: deliveriesURL)
                    }
                    lastSubmitAt = Date()
                    Log.scrobble.info("submitted \(batch.count) listens to \(kind.displayName)")
                } catch {
                    lastError = error.localizedDescription
                    Log.scrobble.error("\(kind.displayName) submission failed: \(error.localizedDescription)")
                    if !retryFailures { break }
                    // Stop this provider for now; the durable queue remains intact.
                    break
                }
            }
        }
    }

    func recentActivity(limit: Int = 24) -> [ScrobbleActivityRow] {
        let providers = configuredProviders
        var rows: [ScrobbleActivityRow] = []
        let recent = listens.sorted { $0.playedAt > $1.playedAt }.prefix(limit)
        for listen in recent {
            if providers.isEmpty {
                rows.append(ScrobbleActivityRow(
                    id: "\(listen.id)-local",
                    date: listen.playedAt,
                    artist: listen.artist,
                    track: listen.title,
                    provider: "Local journal",
                    status: "Archived",
                    statusKind: .archived
                ))
                continue
            }
            for provider in providers {
                let delivered = deliveries.contains { $0.listenID == listen.id && $0.provider == provider }
                rows.append(ScrobbleActivityRow(
                    id: "\(listen.id)-\(provider.rawValue)",
                    date: listen.playedAt,
                    artist: listen.artist,
                    track: listen.title,
                    provider: provider.displayName,
                    status: delivered ? "Submitted" : "Queued",
                    statusKind: delivered ? .submitted : .queued
                ))
            }
        }
        return Array(rows.prefix(limit))
    }

    func exportArchive(to parentDirectory: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let destination = parentDirectory.appendingPathComponent("My-Pod-History-\(formatter.string(from: Date()))", isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        for (source, name) in [
            (observationsURL, "observations.jsonl"),
            (listensURL, "listens.jsonl"),
            (deliveriesURL, "deliveries.jsonl"),
        ] where fm.fileExists(atPath: source.path) {
            try fm.copyItem(at: source, to: destination.appendingPathComponent(name))
        }

        let manifest = ListeningHistoryManifest(
            schemaVersion: 1,
            exportedAt: Date(),
            application: "My Pod",
            observationCount: observations.count,
            listenCount: listens.count,
            deliveryCount: deliveries.count
        )
        try Self.encoder.encode(manifest).write(to: destination.appendingPathComponent("manifest.json"), options: .atomic)
        let readme = """
        My Pod Listening History Archive

        Schema version: 1

        observations.jsonl  Raw iPod play-count observations. These preserve play-count deltas and uncertainty.
        listens.jsonl       Exact timestamped listens reconstructed from those observations.
        deliveries.jsonl    Records of listens successfully submitted to external services.
        manifest.json       Archive metadata and record counts.

        JSONL means one UTF-8 JSON object per line. Credentials and service tokens are never exported.
        """
        try Data(readme.utf8).write(to: destination.appendingPathComponent("README.txt"), options: .atomic)
        return destination
    }

    func importArchive(from directory: URL) throws {
        let incomingObservations: [ListeningObservation] = try loadLines(from: directory.appendingPathComponent("observations.jsonl"))
        let incomingListens: [ListenRecord] = try loadLines(from: directory.appendingPathComponent("listens.jsonl"))
        let incomingDeliveries: [ProviderDeliveryRecord] = try loadLines(from: directory.appendingPathComponent("deliveries.jsonl"))

        var observationIDs = Set(observations.map(\.id))
        for item in incomingObservations where observationIDs.insert(item.id).inserted {
            observations.append(item)
            try appendLine(item, to: observationsURL)
        }
        var listenIDs = Set(listens.map(\.id))
        for item in incomingListens where listenIDs.insert(item.id).inserted {
            listens.append(item)
            try appendLine(item, to: listensURL)
        }
        var deliveryIDs = Set(deliveries.map(\.id))
        for item in incomingDeliveries where deliveryIDs.insert(item.id).inserted {
            deliveries.append(item)
            try appendLine(item, to: deliveriesURL)
        }
    }

    func revealArchive() {
        NSWorkspace.shared.activateFileViewerSelecting([historyDirectory])
    }

    private func submit(_ batch: [ListenRecord], to kind: ScrobbleProviderKind) async throws {
        switch kind {
        case .listenBrainz:
            guard let token = LocalCredentialStore.get(account: ListenBrainzProvider.tokenAccount), !token.isEmpty else {
                throw ScrobbleProviderError.notConfigured("ListenBrainz token is missing.")
            }
            try await ListenBrainzProvider(token: token).submit(batch)
        case .lastFM:
            guard let sessionKey = LocalCredentialStore.get(account: LastFMProvider.sessionKeyAccount),
                  !sessionKey.isEmpty else {
                throw ScrobbleProviderError.notConfigured("Last.fm session is missing.")
            }
            let provider = try LastFMProvider(sessionKey: sessionKey)
            try await provider.submit(batch)
        }
    }

    private var observationsURL: URL { historyDirectory.appendingPathComponent("observations.jsonl") }
    private var listensURL: URL { historyDirectory.appendingPathComponent("listens.jsonl") }
    private var deliveriesURL: URL { historyDirectory.appendingPathComponent("deliveries.jsonl") }
    private var watermarksURL: URL { historyDirectory.appendingPathComponent("watermarks.json") }

    private func prepareStorage() {
        try? fm.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
    }

    private func loadStorage() {
        observations = (try? loadLines(from: observationsURL)) ?? []
        listens = (try? loadLines(from: listensURL)) ?? []
        deliveries = (try? loadLines(from: deliveriesURL)) ?? []
        if let data = try? Data(contentsOf: watermarksURL),
           let decoded = try? Self.decoder.decode([String: TrackPlayWatermark].self, from: data) {
            watermarks = decoded
        }
        lastSubmitAt = deliveries.map(\.deliveredAt).max()
    }

    private func persistWatermarks() {
        guard let data = try? Self.encoder.encode(watermarks) else { return }
        try? data.write(to: watermarksURL, options: .atomic)
    }

    private func appendLine<T: Encodable>(_ value: T, to url: URL) throws {
        var data = try Self.encoder.encode(value)
        data.append(0x0A)
        if fm.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    private func loadLines<T: Decodable>(from url: URL) throws -> [T] {
        guard fm.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return data.split(separator: 0x0A).compactMap { line in
            try? Self.decoder.decode(T.self, from: Data(line))
        }
    }
}

private extension String {
    nonisolated var nilIfEmpty: String? { isEmpty ? nil : self }
    nonisolated var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Array {
    nonisolated func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { start in
            Array(self[start..<Swift.min(start + size, count)])
        }
    }
}
