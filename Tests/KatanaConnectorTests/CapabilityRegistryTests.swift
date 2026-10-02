import XCTest

final class CapabilityRegistryTests: XCTestCase {
    private let registry = CapabilityRegistry()

    func testCapabilityIDsAreUnique() {
        let rawValues = CapabilityID.allCases.map(\.rawValue)
        XCTAssertEqual(Set(rawValues).count, rawValues.count)
    }

    func testRegistryContainsEachCapabilityExactlyOnce() {
        let ids = registry.descriptors.map(\.id)
        XCTAssertEqual(ids.count, CapabilityID.allCases.count)
        for id in CapabilityID.allCases {
            XCTAssertEqual(ids.filter { $0 == id }.count, 1, "\(id) must appear exactly once")
        }
    }

    func testRegistryOrderIsStable() {
        let expected: [CapabilityID] = [
            .photos, .camera, .visionOCR, .microphone, .speech,
            .files,
            .currentLocation, .backgroundLocation,
            .motion,
            .localNotifications,
            .bluetooth, .localNetwork, .coreNFC,
            .contacts, .calendar, .reminders,
            .faceID,
            .healthKit,
        ]
        XCTAssertEqual(registry.descriptors.map(\.id), expected)
        XCTAssertEqual(registry.snapshots().map(\.id), expected)
        XCTAssertEqual(CapabilityRegistry().descriptors, registry.descriptors)
    }

    func testEveryCapabilityHasTitle() {
        for descriptor in registry.descriptors {
            XCTAssertFalse(descriptor.title.isEmpty, "\(descriptor.id) has no title")
            XCTAssertEqual(registry.descriptor(for: descriptor.id), descriptor)
        }
    }

    func testInitialStates() {
        let photos = registry.snapshot(for: .photos)
        XCTAssertEqual(photos.availability, .available)
        XCTAssertEqual(photos.authorization, .unknown)
        XCTAssertEqual(photos.probeState, .notRun)
        XCTAssertNil(photos.checkedAt)

        for id in [CapabilityID.healthKit, .coreNFC] {
            XCTAssertEqual(registry.snapshot(for: id).availability, .missingEntitlement, "\(id)")
        }

        let planned = CapabilityID.allCases.filter { ![.photos, .healthKit, .coreNFC].contains($0) }
        XCTAssertTrue(planned.contains(.backgroundLocation))
        for id in planned {
            XCTAssertEqual(registry.snapshot(for: id).availability, .planned, "\(id)")
        }

        for snapshot in registry.snapshots() {
            XCTAssertEqual(snapshot.probeState, .notRun, "\(snapshot.id)")
            XCTAssertEqual(snapshot.authorization, .unknown, "\(snapshot.id)")
        }
    }

    func testProviderCanBeReplaced() {
        struct GrantedPhotos: CapabilitySnapshotProviding {
            func snapshot(for id: CapabilityID) -> CapabilitySnapshot {
                var snapshot = StaticCapabilitySnapshotProvider().snapshot(for: id)
                if id == .photos { snapshot.authorization = .granted }
                return snapshot
            }
        }
        let custom = CapabilityRegistry(provider: GrantedPhotos())
        XCTAssertEqual(custom.snapshot(for: .photos).authorization, .granted)
        XCTAssertEqual(custom.descriptors, registry.descriptors)
    }
}
