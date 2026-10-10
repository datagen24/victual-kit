import Foundation
import VictualAPI

extension VictualClient {
    /// The id of the user the API key authenticates as.
    ///
    /// Work that is kept per signed-in user on the device — a sync queue, an
    /// anchor — keys on this rather than on the key text, which rotates.
    public func currentUserID() async throws(VictualError) -> Int {
        try await perform {
            try await underlying.getCurrentUser(.init())
        } unwrap: { output in
            switch output {
            case .ok(let response):
                guard let id = try response.body.json.first?.id else { throw VictualError.notFound }
                return id
            case .badRequest(let response):
                throw VictualError.badRequest(message: try? response.body.json.errorMessage)
            case .unauthorized:
                throw VictualError.unauthorized
            case .undocumented(let statusCode, _):
                throw VictualError.forStatus(statusCode)
            }
        }
    }
}
