import Foundation

/// What a capture contains (D-050). Raw values are wire values.
enum CaptureKind: String, Codable, CaseIterable, Sendable {
    case text
    case url
    case image
    case pdf
    case file
}
