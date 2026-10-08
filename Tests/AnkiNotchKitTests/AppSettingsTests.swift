import Foundation
import Observation
import Testing
@testable import AnkiNotchKit

@MainActor
@Suite struct AppSettingsTests {
    /// A throwaway defaults domain, so tests never touch the real preferences.
    private func makeDefaults() -> (UserDefaults, cleanup: () -> Void) {
        let name = "AppSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    @Test func forceBlackBackgroundIsOffByDefault() {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }
        #expect(AppSettings(defaults: defaults).forceBlackBackground == false)
    }

    @Test func forceBlackBackgroundSurvivesANewInstance() {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }
        AppSettings(defaults: defaults).forceBlackBackground = true
        #expect(AppSettings(defaults: defaults).forceBlackBackground == true)
        AppSettings(defaults: defaults).forceBlackBackground = false
        #expect(AppSettings(defaults: defaults).forceBlackBackground == false)
    }

    @Test func changingForceBlackBackgroundIsObservable() {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }
        let settings = AppSettings(defaults: defaults)
        let fired = Flag()
        withObservationTracking {
            _ = settings.forceBlackBackground
        } onChange: {
            fired.value = true
        }
        settings.forceBlackBackground = true
        #expect(fired.value)
    }

    @Test func bouncyAnimationsAreOnByDefault() {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }
        #expect(AppSettings(defaults: defaults).bouncyAnimations)
    }

    @Test func disablingBouncyAnimationsSurvivesANewInstance() {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }
        AppSettings(defaults: defaults).bouncyAnimations = false
        #expect(AppSettings(defaults: defaults).bouncyAnimations == false)
        AppSettings(defaults: defaults).bouncyAnimations = true
        #expect(AppSettings(defaults: defaults).bouncyAnimations)
    }
}

/// `onChange` is `@Sendable`; it runs synchronously on the setter's thread here.
private final class Flag: @unchecked Sendable {
    var value = false
}
