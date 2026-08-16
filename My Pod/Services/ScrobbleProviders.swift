import CryptoKit
import Foundation

nonisolated enum ScrobbleProviderError: LocalizedError, Sendable {
    case notConfigured(String)
    case invalidResponse(String)
    case serviceError(String)
    case lastFM(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let message): message
        case .invalidResponse(let message): message
        case .serviceError(let message): message
        case .lastFM(let code, let message): "Last.fm error \(code): \(message)"
        }
    }
}

/// Small persistent credential store backed by this app's UserDefaults.
///
/// This deliberately does NOT use macOS Keychain. Last.fm's user session and
/// the optional ListenBrainz token are ordinary local app preferences so My Pod
/// never triggers a Keychain access prompt. They are not included in listening-
/// history exports.
///
/// The values are local to this macOS user account and are not encrypted at
/// rest. My Pod's Last.fm application API key/shared secret remain build-time
/// configuration and are not written here.
@MainActor
enum LocalCredentialStore {
    private static let defaults = UserDefaults.standard

    static func set(_ value: String, account: String) throws {
        defaults.set(value, forKey: account)
    }

    static func get(account: String) -> String? {
        defaults.string(forKey: account)
    }

    static func delete(account: String) {
        defaults.removeObject(forKey: account)
    }
}

nonisolated struct ListenBrainzProvider: Sendable {
    static let tokenAccount = "scrobble.listenbrainz.token"
    let token: String

    func submit(_ listens: [ListenRecord]) async throws {
        guard !listens.isEmpty else { return }
        guard let url = URL(string: "https://api.listenbrainz.org/1/submit-listens") else {
            throw ScrobbleProviderError.invalidResponse("Invalid ListenBrainz URL.")
        }

        let payload: [[String: Any]] = listens.map { listen in
            var metadata: [String: Any] = [
                "artist_name": listen.artist,
                "track_name": listen.title,
            ]
            if !listen.album.isEmpty { metadata["release_name"] = listen.album }
            if listen.durationMS > 0 {
                metadata["additional_info"] = ["duration_ms": listen.durationMS]
            }
            return [
                "listened_at": Int(listen.playedAt.timeIntervalSince1970),
                "track_metadata": metadata,
            ]
        }

        let body: [String: Any] = [
            "listen_type": "import",
            "payload": payload,
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ScrobbleProviderError.invalidResponse("ListenBrainz returned no HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw ScrobbleProviderError.serviceError("ListenBrainz: \(message)")
        }
    }
}

nonisolated struct LastFMProvider: Sendable {
    static let sessionKeyAccount = "scrobble.lastfm.session-key"
    static let usernameAccount = "scrobble.lastfm.username"

    // Previous development builds used these preference keys while the
    // configuration UI was evolving. Keep the names so stale local preference
    // values can be removed without touching macOS Keychain.
    static let legacyAPIKeyAccount = "scrobble.lastfm.api-key"
    static let legacyAPISecretAccount = "scrobble.lastfm.api-secret"

    nonisolated struct DesktopAuthorization: Sendable {
        let token: String
        let authorizeURL: URL
    }

    nonisolated struct AuthorizedSession: Sendable {
        let username: String
        let sessionKey: String
    }

    private nonisolated struct ApplicationCredentials: Sendable {
        let apiKey: String
        let sharedSecret: String
    }

    private let apiKey: String
    private let sharedSecret: String
    let sessionKey: String

    init(sessionKey: String) throws {
        let credentials = try Self.applicationCredentials()
        let cleanedSession = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedSession.isEmpty else {
            throw ScrobbleProviderError.notConfigured("Last.fm session key is missing.")
        }
        self.apiKey = credentials.apiKey
        self.sharedSecret = credentials.sharedSecret
        self.sessionKey = cleanedSession
    }

    /// True when this particular build of My Pod contains its app-level
    /// Last.fm API credentials. These are supplied by the app maintainer at
    /// build time; individual users never type an API key or shared secret.
    static var isApplicationConfigured: Bool {
        (try? applicationCredentials()) != nil
    }

    /// Begin Last.fm's desktop authentication flow. Unlike the web-app flow,
    /// desktop auth deliberately has no callback URL: Last.fm gives My Pod a
    /// temporary request token, the user authorizes that token in the browser,
    /// and My Pod later exchanges the same token for a Web Services session.
    static func beginDesktopAuthorization() async throws -> DesktopAuthorization {
        let credentials = try applicationCredentials()
        let signed = [
            "api_key": credentials.apiKey,
            "method": "auth.getToken",
        ]
        let response = try await authCall(signed, secret: credentials.sharedSecret)
        guard let token = response["token"] as? String, !token.isEmpty else {
            throw ScrobbleProviderError.invalidResponse("Last.fm did not return an authorization token.")
        }

        guard var components = URLComponents(string: "https://www.last.fm/api/auth/") else {
            throw ScrobbleProviderError.invalidResponse("Invalid Last.fm authorization URL.")
        }
        components.queryItems = [
            URLQueryItem(name: "api_key", value: credentials.apiKey),
            URLQueryItem(name: "token", value: token),
        ]
        guard let url = components.url else {
            throw ScrobbleProviderError.invalidResponse("Could not create the Last.fm authorization URL.")
        }

        return DesktopAuthorization(token: token, authorizeURL: url)
    }

    /// Wait for the browser authorization to complete without using a custom
    /// URL callback. Last.fm reports error 14 while the request token has not
    /// yet been authorized; polling stops immediately for every other error.
    /// The five-minute local wait is intentionally much shorter than Last.fm's
    /// token lifetime so a forgotten browser window does not leave a task
    /// running indefinitely.
    static func waitForDesktopAuthorization(token: String) async throws -> AuthorizedSession {
        let maximumAttempts = 150
        for attempt in 0..<maximumAttempts {
            try Task.checkCancellation()

            do {
                return try await finishDesktopAuthorization(token: token)
            } catch ScrobbleProviderError.lastFM(let code, _) where code == 14 {
                guard attempt + 1 < maximumAttempts else {
                    throw ScrobbleProviderError.serviceError(
                        "Timed out waiting for Last.fm authorization. Click Connect and try again."
                    )
                }
                try await Task.sleep(for: .seconds(2))
            }
        }

        throw ScrobbleProviderError.serviceError(
            "Timed out waiting for Last.fm authorization. Click Connect and try again."
        )
    }

    private static func finishDesktopAuthorization(token: String) async throws -> AuthorizedSession {
        let requestToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestToken.isEmpty else {
            throw ScrobbleProviderError.invalidResponse("Last.fm authorization token is missing.")
        }

        let credentials = try applicationCredentials()
        let signed = [
            "api_key": credentials.apiKey,
            "method": "auth.getSession",
            "token": requestToken,
        ]
        let response = try await authCall(signed, secret: credentials.sharedSecret)
        guard let session = response["session"] as? [String: Any],
              let username = session["name"] as? String,
              let sessionKey = session["key"] as? String,
              !username.isEmpty,
              !sessionKey.isEmpty else {
            throw ScrobbleProviderError.invalidResponse("Last.fm did not return a usable session.")
        }
        return AuthorizedSession(username: username, sessionKey: sessionKey)
    }

    func submit(_ listens: [ListenRecord]) async throws {

        guard !listens.isEmpty else { return }


        // The direct Last.fm diagnostic proved that this account, API key,

        // shared secret, session, MD5 signing algorithm and POST endpoint all

        // work when a single unindexed scrobble is sent. Keep production on

        // that same request shape.

        guard listens.count == 1, let listen = listens.first else {

            throw ScrobbleProviderError.invalidResponse(

                "Last.fm provider requires exactly one listen per request."

            )

        }


        guard let url = URL(string: "https://ws.audioscrobbler.com/2.0/") else {

            throw ScrobbleProviderError.invalidResponse("Invalid Last.fm URL.")

        }


        let artist = listen.artist.trimmingCharacters(in: .whitespacesAndNewlines)

        let track = listen.title.trimmingCharacters(in: .whitespacesAndNewlines)

        let album = listen.album.trimmingCharacters(in: .whitespacesAndNewlines)


        guard !artist.isEmpty else {

            throw ScrobbleProviderError.invalidResponse(

                "Cannot scrobble a listen with an empty artist."

            )

        }

        guard !track.isEmpty else {

            throw ScrobbleProviderError.invalidResponse(

                "Cannot scrobble a listen with an empty track title."

            )

        }


        var signed: [String: String] = [

            "api_key": apiKey,

            "artist": artist,

            "method": "track.scrobble",

            "sk": sessionKey,

            "timestamp": String(Int(listen.playedAt.timeIntervalSince1970)),

            "track": track,

        ]


        if !album.isEmpty {

            signed["album"] = album

        }

        if listen.durationMS > 0 {

            signed["duration"] = String(listen.durationMS / 1000)

        }


        var transmitted = signed

        transmitted["api_sig"] = Self.signature(for: signed, secret: sharedSecret)

        transmitted["format"] = "json"


        var request = URLRequest(url: url)

        request.httpMethod = "POST"

        request.setValue(

            "application/x-www-form-urlencoded; charset=utf-8",

            forHTTPHeaderField: "Content-Type"

        )

        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        request.httpBody = Self.lastFMFormBody(transmitted)


        let (data, response) = try await URLSession.shared.data(for: request)


        guard let http = response as? HTTPURLResponse else {

            throw ScrobbleProviderError.invalidResponse(

                "Last.fm returned no HTTP response."

            )

        }


        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]


        if let object, let rawError = object["error"] {

            let code = (rawError as? NSNumber)?.intValue

                ?? Int(String(describing: rawError))

                ?? -1

            let message = object["message"] as? String ?? "Error \(code)"

            throw ScrobbleProviderError.lastFM(code: code, message: message)

        }


        guard (200..<300).contains(http.statusCode) else {

            let body = String(data: data, encoding: .utf8)?

                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if body.isEmpty {

                throw ScrobbleProviderError.serviceError(

                    "Last.fm HTTP \(http.statusCode) with an empty response body."

                )

            }

            throw ScrobbleProviderError.serviceError(

                "Last.fm HTTP \(http.statusCode): \(String(body.prefix(500)))"

            )

        }


        guard object != nil else {

            throw ScrobbleProviderError.invalidResponse(

                "Last.fm returned unreadable JSON after accepting the request."

            )

        }

    }


    private static func lastFMFormBody(_ params: [String: String]) -> Data {

        let body = params

            .sorted { $0.key < $1.key }

            .map { lastFMFormEncode($0.key) + "=" + lastFMFormEncode($0.value) }

            .joined(separator: "&")

        return Data(body.utf8)

    }


    private static func lastFMFormEncode(_ value: String) -> String {

        var output = ""

        output.reserveCapacity(value.utf8.count)


        for byte in value.utf8 {

            switch byte {

            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39,

                 0x2D, 0x2E, 0x5F, 0x7E:

                output.append(Character(UnicodeScalar(byte)))

            case 0x20:

                output.append("+")

            default:

                output += String(format: "%%%02X", byte)

            }

        }


        return output

    }

    private static func applicationCredentials() throws -> ApplicationCredentials {
        let apiKey = (Bundle.main.object(forInfoDictionaryKey: "LASTFM_API_KEY") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = (Bundle.main.object(forInfoDictionaryKey: "LASTFM_SHARED_SECRET") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !apiKey.isEmpty, !secret.isEmpty else {
            throw ScrobbleProviderError.notConfigured(
                "Last.fm support is not configured in this build of My Pod. "
                    + "The app maintainer must supply My Pod's application credentials at build time; users never enter them."
            )
        }
        return ApplicationCredentials(apiKey: apiKey, sharedSecret: secret)
    }

    private static func authCall(_ signed: [String: String], secret: String) async throws -> [String: Any] {
        var params = signed
        params["api_sig"] = signature(for: signed, secret: secret)
        params["format"] = "json"

        guard var components = URLComponents(string: "https://ws.audioscrobbler.com/2.0/") else {
            throw ScrobbleProviderError.invalidResponse("Invalid Last.fm API URL.")
        }
        components.queryItems = params
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else {
            throw ScrobbleProviderError.invalidResponse("Could not build the Last.fm API request.")
        }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ScrobbleProviderError.invalidResponse("Last.fm returned no HTTP response.")
        }

        // Last.fm may return an HTTP error status *and* a useful Web Services
        // JSON error body. Desktop auth in particular can report API error 14
        // ("token has not been authorized") as HTTP 403 while the user is still
        // approving the token in the browser. Parse the API body before treating
        // the HTTP status as terminal so the caller can recognize error 14 and
        // continue polling.
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

        if let object, let rawError = object["error"] {
            let code = (rawError as? NSNumber)?.intValue ?? Int(String(describing: rawError)) ?? -1
            let message = object["message"] as? String ?? "Error \(code)"
            throw ScrobbleProviderError.lastFM(code: code, message: message)
        }

        guard (200..<300).contains(http.statusCode) else {
            throw ScrobbleProviderError.serviceError("Last.fm HTTP \(http.statusCode).")
        }

        guard let object else {
            throw ScrobbleProviderError.invalidResponse("Last.fm returned unreadable JSON.")
        }

        return object
    }

    private static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "My Pod/\(version) (studio.rischio.mypod)"
    }

    private static func signature(for params: [String: String], secret: String) -> String {
        let canonical = params.keys.sorted().map { key in key + (params[key] ?? "") }.joined() + secret
        let digest = Insecure.MD5.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
