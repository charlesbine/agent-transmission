import Foundation

/// Turns raw target/RPC errors into a short headline + human sentence for the HUD.
struct PresentedShiftError: Equatable {
    let headline: String
    let detail: String
}

enum ShiftErrorPresenter {
    static func present(_ error: Error) -> PresentedShiftError {
        if let t3 = error as? T3CodeClientError {
            switch t3 {
            case .notConnected:
                return .init(headline: "T3 Code Offline", detail: "Reconnect to T3 Code, then shift again.")
            case .rpcTimeout:
                return .init(headline: "No Response", detail: "T3 Code didn't answer in time. Try the shift again.")
            case .unknownThread:
                return .init(headline: "Thread Not Found", detail: "It may have been closed. Pick another thread.")
            case let .fastModeUnsupported(model):
                return .init(headline: "No Fast Mode", detail: "\(model) doesn't offer a Fast option.")
            case let .rpcFailure(detail):
                return present(rawMessage: detail)
            default:
                break
            }
        }
        return present(rawMessage: error.localizedDescription)
    }

    static func present(rawMessage: String) -> PresentedShiftError {
        let lower = rawMessage.lowercased()
        if lower.contains("active turn") || lower.contains("turn is running") || lower.contains("turn in progress") {
            return .init(headline: "Thread Is Busy", detail: "Wait for the current turn to finish, then shift again.")
        }
        if lower.contains("not found") {
            return .init(headline: "Thread Not Found", detail: "It may have been closed. Pick another thread.")
        }
        return .init(headline: "Shift Rejected", detail: clean(rawMessage))
    }

    /// Strips transport prefixes and opaque IDs, keeps the first sentence.
    static func clean(_ message: String) -> String {
        var text = message
        for prefix in ["T3 Code rejected the update:", "Error:"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        let uuid = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        text = text.replacingOccurrences(of: "(?i)\\bthread \(uuid)", with: "This thread", options: .regularExpression)
        text = text.replacingOccurrences(of: uuid, with: "", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let end = text.range(of: ". ") {
            text = String(text[..<end.lowerBound]) + "."
        }
        guard let first = text.first else { return "T3 Code refused the change." }
        return first.uppercased() + text.dropFirst()
    }
}
