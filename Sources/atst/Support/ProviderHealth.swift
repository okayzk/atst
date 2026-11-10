import Foundation

/// Reachability of one translation service, shown as a small dot in the
/// settings UI.
enum ProviderHealth: Equatable {
    case unknown
    case checking
    case reachable
    case unreachable(String)
}
