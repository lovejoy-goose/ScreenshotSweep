import XCTest

final class CapabilityCodingTests: XCTestCase {
    // Whole seconds: ISO 8601 coding does not keep fractional seconds.
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    func testSnapshotRoundTrip() throws {
        let snapshot = CapabilitySnapshot(id: .currentLocation, availability: .available,
                                          authorization: .limited, probeState: .failed,
                                          checkedAt: date, detail: "timeout")
        let data = try ConnectorJSON.makeEncoder().encode(snapshot)
        XCTAssertEqual(try ConnectorJSON.makeDecoder().decode(CapabilitySnapshot.self, from: data), snapshot)

        let empty = CapabilityRegistry().snapshot(for: .photos)
        let emptyData = try ConnectorJSON.makeEncoder().encode(empty)
        XCTAssertEqual(try ConnectorJSON.makeDecoder().decode(CapabilitySnapshot.self, from: emptyData), empty)
    }

    func testSnapshotWireFormat() throws {
        let snapshot = CapabilitySnapshot(id: .backgroundLocation, availability: .missingEntitlement,
                                          authorization: .notRequested, probeState: .notRun,
                                          checkedAt: date, detail: nil)
        let json = String(decoding: try ConnectorJSON.makeEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertEqual(json, #"{"authorization":"not_requested","availability":"missing_entitlement","#
            + #""checked_at":"2026-09-21T14:13:20Z","id":"background_location","probe_state":"not_run"}"#)
    }

    func testCapabilityIDWireValues() {
        let expected: [CapabilityID: String] = [
            .photos: "photos", .camera: "camera", .visionOCR: "vision_ocr", .files: "files",
            .currentLocation: "current_location", .backgroundLocation: "background_location",
            .motion: "motion", .localNotifications: "local_notifications", .bluetooth: "bluetooth",
            .localNetwork: "local_network", .contacts: "contacts", .calendar: "calendar",
            .reminders: "reminders", .faceID: "face_id", .microphone: "microphone",
            .speech: "speech", .healthKit: "health_kit", .coreNFC: "core_nfc",
        ]
        XCTAssertEqual(expected.count, CapabilityID.allCases.count)
        for id in CapabilityID.allCases {
            XCTAssertEqual(id.rawValue, expected[id], "\(id)")
        }
    }

    func testStateWireValues() {
        XCTAssertEqual(CapabilityAvailability.allCases.map(\.rawValue),
                       ["available", "planned", "missing_entitlement", "unsupported_device"])
        XCTAssertEqual(CapabilityAuthorization.allCases.map(\.rawValue),
                       ["unknown", "not_required", "not_requested", "granted", "limited", "denied", "restricted"])
        XCTAssertEqual(CapabilityProbeState.allCases.map(\.rawValue), ["not_run", "passed", "failed"])
        XCTAssertEqual(ConnectorConnectionState.allCases.map(\.rawValue),
                       ["unpaired", "pairing", "connected", "revoked", "error"])
    }

    func testDeviceSummaryRoundTrip() throws {
        let summary = ConnectorDeviceSummary(deviceID: nil, displayName: "iPhone", appVersion: "0.1.0",
                                             systemVersion: "18.0", connectionState: .unpaired,
                                             lastSeenAt: nil)
        let paired = ConnectorDeviceSummary(deviceID: "fixture-device-id", displayName: "iPhone",
                                            appVersion: "0.1.0", systemVersion: "18.0",
                                            connectionState: .connected, lastSeenAt: date)
        for value in [summary, paired] {
            let data = try ConnectorJSON.makeEncoder().encode(value)
            XCTAssertEqual(try ConnectorJSON.makeDecoder().decode(ConnectorDeviceSummary.self, from: data), value)
        }

        let json = String(decoding: try ConnectorJSON.makeEncoder().encode(paired), as: UTF8.self)
        XCTAssertEqual(json, #"{"app_version":"0.1.0","connection_state":"connected","device_id":"fixture-device-id","#
            + #""display_name":"iPhone","last_seen_at":"2026-09-21T14:13:20Z","system_version":"18.0"}"#)
    }
}
