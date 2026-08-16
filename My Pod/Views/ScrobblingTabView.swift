import AppKit
import Charts
import SwiftUI

struct ScrobblingTabView: View {
    @Bindable var store: ScrobbleStore
    @State private var dimension: ListeningDimension = .artists
    @State private var providerToConfigure: ScrobbleProviderKind?
    @State private var showAddService = false
    @State private var transientMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        serviceArea
                            .frame(minWidth: 520, maxWidth: .infinity, alignment: .topLeading)
                        distributionCard
                            .frame(width: 470)
                    }
                    VStack(spacing: 14) {
                        serviceArea
                        distributionCard
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        historyCard
                            .frame(maxWidth: .infinity)
                        behaviorCard
                            .frame(maxWidth: .infinity)
                    }
                    VStack(spacing: 14) {
                        historyCard
                        behaviorCard
                    }
                }

                activityCard
            }
            .padding(16)
        }
        .safeAreaInset(edge: .bottom) {
            footer
        }
        .sheet(isPresented: $showAddService) {
            AddScrobbleServiceSheet(
                configured: Set(store.configuredProviders),
                onChoose: { kind in
                    showAddService = false
                    providerToConfigure = kind
                }
            )
        }
        .sheet(item: $providerToConfigure) { kind in
            ProviderConfigurationSheet(kind: kind, store: store)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 28))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Scrobbling")
                    .font(.title2.bold())
                Text("Capture iPod listening history locally, then submit exact listens to connected services.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Enable Scrobbling", isOn: $store.enabled)
                .toggleStyle(.switch)
        }
    }

    private var serviceArea: some View {
        DashboardCard(title: "Connected Services", systemImage: "network") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Providers consume the local journal; the journal remains the source of truth.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showAddService = true
                    } label: {
                        Label("Add Service", systemImage: "plus")
                    }
                    .controlSize(.small)
                }

                let configured = store.configuredProviders
                if configured.isEmpty {
                    ContentUnavailableView {
                        Label("No Scrobble Services", systemImage: "dot.radiowaves.left.and.right")
                    } description: {
                        Text("History is still archived locally. Add Last.fm or ListenBrainz when you're ready to submit it.")
                    } actions: {
                        Button("Add Service…") { showAddService = true }
                    }
                    .frame(minHeight: 160)
                } else if configured.count == 1, let provider = configured.first {
                    ProviderCard(
                        kind: provider,
                        pending: store.pendingCount(for: provider),
                        submitted: store.submittedCount(for: provider),
                        accountLabel: store.accountName(for: provider),
                        onManage: { providerToConfigure = provider },
                        onDisconnect: { store.disconnect(provider) }
                    )
                } else {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(configured) { provider in
                            ProviderCard(
                                kind: provider,
                                pending: store.pendingCount(for: provider),
                                submitted: store.submittedCount(for: provider),
                                accountLabel: store.accountName(for: provider),
                                onManage: { providerToConfigure = provider },
                                onDisconnect: { store.disconnect(provider) }
                            )
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    private var distributionCard: some View {
        DashboardCard(title: "Listening Distribution", systemImage: "chart.pie.fill") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Distribution", selection: $dimension) {
                    ForEach(ListeningDimension.allCases) { dimension in
                        Text(dimension.rawValue).tag(dimension)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                let buckets = store.distribution(dimension)
                let total = buckets.reduce(0) { $0 + $1.count }

                if buckets.isEmpty {
                    ContentUnavailableView {
                        Label("No Plays This Session", systemImage: "chart.donut")
                    } description: {
                        Text("Connect and play an iPod, then reopen or refresh it to harvest new play-count data.")
                    }
                    .frame(minHeight: 250)
                } else {
                    HStack(alignment: .center, spacing: 18) {
                        ZStack {
                            Chart(buckets) { bucket in
                                SectorMark(
                                    angle: .value("Plays", bucket.count),
                                    innerRadius: .ratio(0.62),
                                    angularInset: 1.5
                                )
                                .cornerRadius(3)
                                .foregroundStyle(color(for: bucket.colorIndex))
                            }
                            .chartLegend(.hidden)
                            .frame(width: 210, height: 210)

                            VStack(spacing: 1) {
                                Text("\(total)")
                                    .font(.system(size: 34, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                Text("unique plays")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(dimension.rawValue.dropLast(dimension == .songs ? 1 : 1))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("Plays")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("%")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 34, alignment: .trailing)
                            }
                            ForEach(buckets) { bucket in
                                HStack(spacing: 7) {
                                    Circle()
                                        .fill(color(for: bucket.colorIndex))
                                        .frame(width: 8, height: 8)
                                    Text(bucket.label)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(bucket.count)")
                                        .monospacedDigit()
                                    Text("\(bucket.percentage(of: total))%")
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                        .frame(width: 34, alignment: .trailing)
                                }
                                .font(.caption)
                            }
                        }
                    }

                    Text("Current iPod import session. Categories are derived from the exact timestamped listens preserved in the local journal.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var historyCard: some View {
        DashboardCard(title: "Local History Journal", systemImage: "externaldrive.badge.timemachine") {
            VStack(alignment: .leading, spacing: 10) {
                Text("My Pod stores the original play-count evidence locally before any provider sees it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                InfoRow(label: "Archive path", value: store.archivePathText)
                InfoRow(label: "Observations", value: "\(store.observations.count)")
                InfoRow(label: "Exact listens", value: "\(store.listens.count)")
                InfoRow(label: "Current session", value: "\(store.currentSessionListens.count) exact")
                InfoRow(label: "Timestamp policy", value: "Exact only; ambiguity preserved")

                HStack {
                    Button("Export History…") { exportHistory() }
                    Button("Import History…") { importHistory() }
                    Button("Reveal in Finder") { store.revealArchive() }
                }
                .controlSize(.small)

                if let transientMessage {
                    Text(transientMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var behaviorCard: some View {
        DashboardCard(title: "Behavior", systemImage: "gearshape") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Scan play history when iPod connects", isOn: $store.scanOnConnect)
                Toggle("Submit automatically when online", isOn: $store.autoSubmit)
                Toggle("Keep failed submissions queued for retry", isOn: $store.retryFailures)
                Toggle("Never fabricate timestamps for ambiguous plays", isOn: .constant(true))
                    .disabled(true)
                Text("When an iPod reports several new plays but only one last-played timestamp, My Pod archives the full count delta and submits only the one timestamp it can prove.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var activityCard: some View {
        DashboardCard(title: "Pending & Recent Activity", systemImage: "clock.arrow.circlepath") {
            let rows = store.recentActivity(limit: 18)
            if rows.isEmpty {
                ContentUnavailableView("No listening history yet", systemImage: "music.note.list")
                    .frame(minHeight: 150)
            } else {
                Table(rows) {
                    TableColumn("Time") { row in
                        Text(row.date, format: .dateTime.month().day().hour().minute())
                    }
                    .width(min: 130, ideal: 160)
                    TableColumn("Artist", value: \.artist)
                    TableColumn("Track", value: \.track)
                    TableColumn("Provider", value: \.provider)
                    TableColumn("Status") { row in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(statusColor(row.statusKind))
                                .frame(width: 7, height: 7)
                            Text(row.status)
                        }
                    }
                    .width(min: 90, ideal: 110)
                }
                .frame(minHeight: 210)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(store.lastError == nil ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text("\(store.configuredProviders.reduce(0) { $0 + store.pendingCount(for: $1) }) pending")
            Text("•").foregroundStyle(.tertiary)
            Text("\(store.listens.count) archived listens")
            if let last = store.lastSubmitAt {
                Text("•").foregroundStyle(.tertiary)
                Text("Last submit: \(last.formatted(.relative(presentation: .numeric)))")
            }
            if let error = store.lastError {
                Text("•").foregroundStyle(.tertiary)
                Text(error)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            Spacer()
            if store.isHarvesting {
                ProgressView()
                    .controlSize(.small)
                Text("Reading iPod history…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await store.submitNow() }
            } label: {
                Label(store.isSubmitting ? "Submitting…" : "Submit Now", systemImage: "arrow.up.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isSubmitting || store.configuredProviders.isEmpty)
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private func exportHistory() {
        let panel = NSOpenPanel()
        panel.title = "Choose Export Destination"
        panel.prompt = "Export Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        do {
            let exported = try store.exportArchive(to: directory)
            transientMessage = "Exported to \(exported.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([exported])
        } catch {
            transientMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importHistory() {
        let panel = NSOpenPanel()
        panel.title = "Choose My Pod History Archive"
        panel.prompt = "Import"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        do {
            try store.importArchive(from: directory)
            transientMessage = "Imported history from \(directory.lastPathComponent)"
        } catch {
            transientMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    private func color(for index: Int) -> Color {
        switch index % 6 {
        case 0: .blue
        case 1: .red
        case 2: .orange
        case 3: .green
        case 4: .purple
        default: .gray
        }
    }

    private func statusColor(_ status: ScrobbleActivityRow.StatusKind) -> Color {
        switch status {
        case .archived: .secondary
        case .queued: .orange
        case .submitted: .green
        case .failed: .red
        }
    }
}

private struct DashboardCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
        )
    }
}

private struct ProviderCard: View {
    let kind: ScrobbleProviderKind
    let pending: Int
    let submitted: Int
    let accountLabel: String?
    let onManage: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: kind.systemImage)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.displayName).font(.headline)
                    Label(
                        accountLabel.map { "Connected as \($0)" } ?? "Connected",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.green)
                }
                Spacer()
                Button("Manage", action: onManage)
                    .controlSize(.small)
                Button("Disconnect", role: .destructive, action: onDisconnect)
                    .controlSize(.small)
            }
            HStack {
                Stat(label: "Pending", value: pending)
                Divider().frame(height: 36)
                Stat(label: "Submitted", value: submitted)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(NSColor.windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
        )
    }

    private struct Stat: View {
        let label: String
        let value: Int
        var body: some View {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text("\(value)").font(.title3.bold()).monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).monospacedDigit().textSelection(.enabled)
        }
        .font(.caption)
    }
}

private struct AddScrobbleServiceSheet: View {
    let configured: Set<ScrobbleProviderKind>
    let onChoose: (ScrobbleProviderKind) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Scrobble Service")
                .font(.title2.bold())
            Text("Services receive copies of your exact listening events. My Pod keeps the canonical history locally.")
                .foregroundStyle(.secondary)

            ForEach(ScrobbleProviderKind.allCases) { kind in
                Button {
                    onChoose(kind)
                } label: {
                    HStack {
                        Image(systemName: kind.systemImage)
                            .font(.title2)
                            .frame(width: 34)
                        VStack(alignment: .leading) {
                            Text(kind.displayName).font(.headline)
                            Text(configured.contains(kind) ? "Already configured" : providerDescription(kind))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                }
                .buttonStyle(.plain)
                .disabled(configured.contains(kind))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 470)
    }

    private func providerDescription(_ kind: ScrobbleProviderKind) -> String {
        switch kind {
        case .lastFM: "Submit historical scrobbles to Last.fm."
        case .listenBrainz: "Import exact listens into ListenBrainz."
        }
    }
}

private struct ProviderConfigurationSheet: View {
    let kind: ScrobbleProviderKind
    @Bindable var store: ScrobbleStore
    @Environment(\.dismiss) private var dismiss
    @State private var listenBrainzToken = ""
    @State private var isOpeningLastFMAuth = false
    @State private var isWaitingForLastFM = false
    @State private var lastFMAuthURL: URL?
    @State private var lastFMConnectTask: Task<Void, Never>?
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Configure \(kind.displayName)", systemImage: kind.systemImage)
                .font(.title2.bold())

            switch kind {
            case .listenBrainz:
                Text("Paste your ListenBrainz user token. It is stored in My Pod's local preferences and never exported with your history.")
                    .foregroundStyle(.secondary)
                SecureField("User token", text: $listenBrainzToken)
                    .textFieldStyle(.roundedBorder)
            case .lastFM:
                lastFMConfiguration
            }

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Disconnect", role: .destructive) {
                    cancelLastFMAuthorization()
                    store.disconnect(kind)
                    dismiss()
                }
                .disabled(!store.isConfigured(kind))
                Spacer()
                Button("Cancel") {
                    cancelLastFMAuthorization()
                    dismiss()
                }
                if kind == .listenBrainz {
                    Button("Save") { saveListenBrainz() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear(perform: loadStoredCredentials)
        .onChange(of: store.credentialRevision) { _, _ in
            if kind == .lastFM, store.isConfigured(.lastFM) {
                dismiss()
            }
        }
        .onDisappear {
            lastFMConnectTask?.cancel()
        }
    }

    @ViewBuilder
    private var lastFMConfiguration: some View {
        if store.isConfigured(.lastFM) {
            Label(
                store.accountName(for: .lastFM).map { "Connected as \($0)" } ?? "Connected to Last.fm",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)

            Text("My Pod stores only your Last.fm session in local app preferences. The application API credentials belong to My Pod and are supplied at build time; users never enter them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                beginLastFMAuthorization()
            } label: {
                Label(
                    isOpeningLastFMAuth || isWaitingForLastFM ? "Connecting…" : "Reconnect in Browser",
                    systemImage: "safari"
                )
            }
            .disabled(isOpeningLastFMAuth || isWaitingForLastFM)

            if isWaitingForLastFM {
                lastFMWaitingPanel
            }
        } else if LastFMProvider.isApplicationConfigured {
            Text("Connect your Last.fm account in your web browser. My Pod supplies its own application credentials; your API key and shared secret are never requested.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                beginLastFMAuthorization()
            } label: {
                Label(
                    isOpeningLastFMAuth || isWaitingForLastFM ? "Connecting…" : "Connect Last.fm",
                    systemImage: "safari"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(isOpeningLastFMAuth || isWaitingForLastFM)

            if isWaitingForLastFM {
                lastFMWaitingPanel
            }
        } else {
            Label("Last.fm is not enabled in this build", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("The My Pod maintainer must supply one application API key and shared secret at build time. End users never enter either value.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var lastFMWaitingPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for Last.fm authorization…")
                    .font(.callout.weight(.medium))
            }
            Text("Approve My Pod in the browser, then you can close that tab. My Pod checks the desktop authorization token here and finishes the connection automatically — the browser will not relaunch the app.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if let lastFMAuthURL {
                    Button("Open Last.fm Again") {
                        NSWorkspace.shared.open(lastFMAuthURL)
                    }
                }
                Button("Cancel Connection") {
                    cancelLastFMAuthorization()
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    private func loadStoredCredentials() {
        if kind == .listenBrainz {
            listenBrainzToken = LocalCredentialStore.get(account: ListenBrainzProvider.tokenAccount) ?? ""
        }
    }

    private func saveListenBrainz() {
        do {
            guard !listenBrainzToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ScrobbleProviderError.notConfigured("Enter a ListenBrainz token.")
            }
            try store.configureListenBrainz(token: listenBrainzToken)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func beginLastFMAuthorization() {
        cancelLastFMAuthorization()
        errorText = nil
        isOpeningLastFMAuth = true

        lastFMConnectTask = Task {
            do {
                Log.scrobble.info("Last.fm desktop auth: requesting token")
                let authorization = try await LastFMProvider.beginDesktopAuthorization()
                try Task.checkCancellation()

                lastFMAuthURL = authorization.authorizeURL
                guard NSWorkspace.shared.open(authorization.authorizeURL) else {
                    throw ScrobbleProviderError.serviceError("macOS could not open the Last.fm authorization page.")
                }

                isOpeningLastFMAuth = false
                isWaitingForLastFM = true
                Log.scrobble.info("Last.fm desktop auth: browser opened; waiting for authorization")

                let session = try await LastFMProvider.waitForDesktopAuthorization(token: authorization.token)
                try Task.checkCancellation()

                try store.configureLastFM(username: session.username, sessionKey: session.sessionKey)
                isWaitingForLastFM = false
                lastFMAuthURL = nil
                Log.scrobble.info("Last.fm connected as \(session.username)")

                if store.autoSubmit {
                    Task { await store.submitNow() }
                }
                dismiss()
            } catch is CancellationError {
                isOpeningLastFMAuth = false
                isWaitingForLastFM = false
                lastFMAuthURL = nil
            } catch {
                isOpeningLastFMAuth = false
                isWaitingForLastFM = false
                lastFMAuthURL = nil
                errorText = error.localizedDescription
                Log.scrobble.error("Last.fm authorization failed: \(error.localizedDescription)")
            }
            lastFMConnectTask = nil
        }
    }

    private func cancelLastFMAuthorization() {
        lastFMConnectTask?.cancel()
        lastFMConnectTask = nil
        isOpeningLastFMAuth = false
        isWaitingForLastFM = false
        lastFMAuthURL = nil
    }
}
