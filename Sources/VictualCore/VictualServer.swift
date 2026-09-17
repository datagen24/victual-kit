import Foundation

/// The location of a Victual instance and the path prefix its REST API lives under.
///
/// Victual is self-hosted, so there is no canonical origin: a front end always
/// asks the person using it where their instance lives. `VictualServer` turns
/// that answer into the absolute URL the generated client needs.
public struct VictualServer: Hashable, Sendable, Codable {
    /// The root URL of the instance, for example `https://victual.example.com`.
    public var instanceURL: URL

    /// The path the REST API is mounted at, relative to ``instanceURL``.
    ///
    /// Matches the `servers` entry in the normalized OpenAPI document.
    public var apiPathPrefix: String

    public init(instanceURL: URL, apiPathPrefix: String = "api") {
        self.instanceURL = instanceURL
        self.apiPathPrefix = apiPathPrefix
    }

    /// Builds a server from user-entered text, tolerating the shapes people
    /// actually type into a connection form.
    ///
    /// A bare host such as `victual.example.com` is promoted to `https`, and a
    /// trailing `/api` is folded into ``apiPathPrefix`` rather than being
    /// appended twice.
    public init(userEnteredText: String, apiPathPrefix: String = "api") throws {
        var text = userEnteredText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw VictualError.invalidServerURL(userEnteredText) }

        if !text.contains("://") {
            text = "https://" + text
        }
        while text.hasSuffix("/") {
            text.removeLast()
        }
        let suffix = "/" + apiPathPrefix
        if text.hasSuffix(suffix) {
            text.removeLast(suffix.count)
        }

        guard
            let components = URLComponents(string: text),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.host, !host.isEmpty,
            let url = components.url
        else {
            throw VictualError.invalidServerURL(userEnteredText)
        }

        self.init(instanceURL: url, apiPathPrefix: apiPathPrefix)
    }

    /// The absolute base URL for API requests.
    ///
    /// Never ends in a slash: the OpenAPI transport builds a request URL by
    /// appending the operation's path to this one textually, so a trailing
    /// slash here would send every request to a double-slashed path.
    public var baseURL: URL {
        var path = instanceURL.absoluteString
        while path.hasSuffix("/") { path.removeLast() }

        let prefix = apiPathPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !prefix.isEmpty { path += "/" + prefix }

        return URL(string: path) ?? instanceURL
    }
}
