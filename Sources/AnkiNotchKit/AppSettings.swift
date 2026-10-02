import Foundation
import Observation

/// The user's preferences, stored in `UserDefaults`. One typed property per
/// setting; a change is written through at once and is observable, so the UI
/// and the card view follow it without extra plumbing.
@MainActor
@Observable
public final class AppSettings {
    /// Show every card on pure black, in night mode, whatever its note type says.
    public var forceBlackBackground: Bool {
        didSet { defaults.set(forceBlackBackground, forKey: Key.forceBlackBackground) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    private enum Key {
        static let forceBlackBackground = "forceBlackBackground"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        forceBlackBackground = defaults.bool(forKey: Key.forceBlackBackground)
    }
}
