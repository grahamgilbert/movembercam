import Foundation

enum UpdateChannel {
    static let prereleasePreference = "MovemberCam.installPrereleases"
    static let checkInterval: TimeInterval = 3600

    static func feedURL(includePrereleases: Bool) -> URL {
        URL(string: "https://raw.githubusercontent.com/grahamgilbert/movembercam/main/" +
            (includePrereleases ? "appcast-prerelease.xml" : "appcast.xml"))!
    }
}
