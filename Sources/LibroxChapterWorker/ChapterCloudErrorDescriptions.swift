import Foundation

extension ChapterDemandTransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .offline: "iCloud is offline. Your request is saved and will be retried when the connection returns."
        case .accountUnavailable: "Sign in to iCloud to prepare and receive this audiobook."
        case .configurationUnavailable: "This copy of Librox cannot access its narration service. Install the current signed build."
        case .quotaExceeded: "iCloud narration storage or the request limit has been reached."
        case .retryAfter: "iCloud is temporarily busy. Preparation will retry shortly."
        case .busy: "Another narration transfer is finishing. Try again shortly."
        case .conflict, .uncertain, .retryLimit: "The iCloud update could not be confirmed. Your saved request can be retried."
        case .operationCancelled: "The narration transfer stopped. Completed audio is preserved."
        case .invalidRecord, .inconsistentSnapshot, .remoteRevisionAhead: "The narration request has changed or could not be verified. Open the book in Librox and request preparation again."
        }
    }
}
