import Foundation

enum OverlayPreferences {
    static let key = "MovemberCam.overlay.v1"
    private static let recoveryDraftKey = "MovemberCam.recoveryDraft.v1"

    static func preserveDraft(_ draft: OverlayConfiguration, in defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(draft), forKey: recoveryDraftKey)
    }

    static func takeRecoveryDraft(from defaults: UserDefaults, restoring: Bool) -> OverlayConfiguration? {
        defer { defaults.removeObject(forKey: recoveryDraftKey) }
        guard restoring, let data = defaults.data(forKey: recoveryDraftKey) else { return nil }
        // Unsaved edits may be invalid; preserve them without applying them.
        return try? JSONDecoder().decode(OverlayConfiguration.self, from: data)
    }

    static func load(from defaults: UserDefaults = .standard) -> OverlayConfiguration {
        var configuration = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(OverlayConfiguration.self, from: $0) }
            .flatMap { try? $0.validated() } ?? OverlayConfiguration()
        let previous = configuration
        if configuration.qrURL == "https://movember.com" {
            configuration.qrURL = OverlayConfiguration.defaultFundraisingURL
        }
        if ["movember.com", "https://movember.com"].contains(configuration.displayURL) {
            configuration.displayURL = OverlayConfiguration.defaultFundraisingURL
        }
        if configuration != previous { save(configuration, to: defaults) }
        return configuration
    }

    static func save(_ configuration: OverlayConfiguration, to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(configuration) {
            defaults.set(data, forKey: key)
        }
    }
}
