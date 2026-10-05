import Foundation

/// Stable identifier of a device capability. Raw values are wire values (snake_case)
/// and must never change once shipped.
enum CapabilityID: String, Codable, CaseIterable, Sendable {
    case photos
    case camera
    case visionOCR = "vision_ocr"
    case files
    case currentLocation = "current_location"
    case backgroundLocation = "background_location"
    case motion
    case localNotifications = "local_notifications"
    case bluetooth
    case localNetwork = "local_network"
    case contacts
    case calendar
    case reminders
    case faceID = "face_id"
    case microphone
    case speech
    case healthKit = "health_kit"
    case coreNFC = "core_nfc"
    // v0.3 (D-051): appended; existing wire values never change.
    case coreNFCWrite = "core_nfc_write"
    case appGroup = "app_group"
    case shareExtension = "share_extension"
    case locationAlways = "location_always"
    case regionMonitoring = "region_monitoring"
}
