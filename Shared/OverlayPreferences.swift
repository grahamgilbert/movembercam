import Foundation

enum OverlayPreferences {
    static let key = "MovemberCam.overlay.v1"

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
