import Foundation

struct OverlayConfiguration: Codable, Equatable {
    enum Corner: String, Codable, CaseIterable {
        case left, right
        var title: String { self == .left ? "Bottom left" : "Bottom right" }
    }
    static let defaultFundraisingURL = "https://movember.com/t/musta-ch"
    var qrURL = defaultFundraisingURL
    var displayURL = defaultFundraisingURL
    var corner: Corner = .right
    var mirrorCamera = false

    func validated() throws -> Self {
        var result = self
        result.qrURL = qrURL.trimmingCharacters(in: .whitespacesAndNewlines)
        result.displayURL = displayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: result.qrURL),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              !result.qrURL.contains(where: { $0.isWhitespace }), url.url != nil else {
            throw VideoError.message("Enter a complete fundraising URL beginning with https:// or http://.")
        }
        guard result.qrURL.utf8.count <= 220 else {
            throw VideoError.message("Use a shorter fundraising link (up to 220 bytes) to keep the QR code easy to scan.")
        }
        guard !result.displayURL.isEmpty, result.displayURL.count <= 64,
              !result.displayURL.contains(where: { $0.isNewline }) else {
            throw VideoError.message("The written URL must be 1–64 characters on a single line.")
        }
        return result
    }
}
