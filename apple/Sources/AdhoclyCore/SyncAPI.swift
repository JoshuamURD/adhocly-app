import Foundation

public struct AppFailure: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

struct HTTPFailure: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? {
        status == 401 ? "The server rejected the API token. Update it in Connection settings." : "HTTP \(status): \(message)"
    }
    var needsReview: Bool { [400, 404, 409, 422].contains(status) }
}

struct SyncAPI {
    let baseURL: URL
    let token: String
    let session: URLSession

    static func validatedURL(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: trimmed),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.scheme == "https" || (parts.scheme == "http" &&
                (["localhost", "127.0.0.1", "[::1]", "::1"].contains(host) || host.hasSuffix(".local")))
        else {
            throw AppFailure("Enter an HTTPS server URL. HTTP is allowed only for localhost or a .local development host, without credentials, query, or fragment.")
        }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard let url = parts.url else { throw AppFailure("Invalid server URL.") }
        return url
    }

    func snapshot() async throws -> Snapshot {
        try await request(operation: nil)
    }

    func apply(_ operation: SyncOperation) async throws -> SyncReply {
        try await request(operation: operation)
    }

    private func request<Response: Decodable>(operation: SyncOperation?) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: "api/sync"))
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let operation {
            request.httpMethod = "POST"
            request.httpBody = try JSONEncoder().encode(operation)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw AppFailure("Invalid server response.") }
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPFailure(status: response.statusCode,
                              message: String(decoding: data.prefix(1_000), as: UTF8.self))
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
