import Foundation

/// Source of capability state. In the app this is `CapabilitySnapshotStore` (declared defaults
/// overridden by stored Capability Lab results); tests may use the static provider directly.
protocol CapabilitySnapshotProviding: Sendable {
    func snapshot(for id: CapabilityID) -> CapabilitySnapshot
}

/// Declared initial state. Touches no system APIs and requests no permissions.
struct StaticCapabilitySnapshotProvider: CapabilitySnapshotProviding {
    func snapshot(for id: CapabilityID) -> CapabilitySnapshot {
        let availability: CapabilityAvailability
        switch id {
        case .photos:
            availability = .available
        case .camera, .currentLocation, .motion, .localNotifications:
            // Implemented in Capability Lab; the real device check may turn this into
            // `unsupported_device` (CapabilityLabCoordinator.refreshAuthorizations).
            availability = .available
        case .healthKit, .coreNFC, .coreNFCWrite, .appGroup, .shareExtension:
            // Not provisioned in this build (D-046); the code exists, the entitlement does not.
            availability = .missingEntitlement
        case .locationAlways, .regionMonitoring:
            // Manual probes since v0.3; the device check may turn this into `unsupported_device`.
            availability = .available
        case .visionOCR, .files, .backgroundLocation, .bluetooth, .localNetwork, .contacts,
             .calendar, .reminders, .faceID, .microphone, .speech:
            availability = .planned
        }
        return CapabilitySnapshot(id: id, availability: availability, authorization: .unknown,
                                  probeState: .notRun, checkedAt: nil, detail: nil)
    }
}

/// The single catalog of Connector capabilities, in stable display/report order.
/// Requests no permissions, calls no system APIs, makes no network calls, stores no tokens.
struct CapabilityRegistry: Sendable {
    static let catalog: [CapabilityDescriptor] = [
        CapabilityDescriptor(id: .photos, title: "Фото", category: .media),
        CapabilityDescriptor(id: .camera, title: "Камера", category: .media),
        CapabilityDescriptor(id: .visionOCR, title: "Распознавание текста", category: .media),
        CapabilityDescriptor(id: .microphone, title: "Микрофон", category: .media),
        CapabilityDescriptor(id: .speech, title: "Распознавание речи", category: .media),
        CapabilityDescriptor(id: .files, title: "Файлы", category: .documents),
        CapabilityDescriptor(id: .shareExtension, title: "Поделиться (Share Extension)", category: .documents),
        CapabilityDescriptor(id: .appGroup, title: "App Group", category: .documents),
        CapabilityDescriptor(id: .currentLocation, title: "Текущая геолокация", category: .location),
        CapabilityDescriptor(id: .backgroundLocation, title: "Фоновая геолокация", category: .location),
        CapabilityDescriptor(id: .locationAlways, title: "Геолокация «Всегда»", category: .location),
        CapabilityDescriptor(id: .regionMonitoring, title: "Геозоны (region monitoring)", category: .location),
        CapabilityDescriptor(id: .motion, title: "Движение", category: .sensors),
        CapabilityDescriptor(id: .localNotifications, title: "Локальные уведомления", category: .notifications),
        CapabilityDescriptor(id: .bluetooth, title: "Bluetooth", category: .connectivity),
        CapabilityDescriptor(id: .localNetwork, title: "Локальная сеть", category: .connectivity),
        CapabilityDescriptor(id: .coreNFC, title: "NFC: чтение", category: .connectivity),
        CapabilityDescriptor(id: .coreNFCWrite, title: "NFC: запись", category: .connectivity),
        CapabilityDescriptor(id: .contacts, title: "Контакты", category: .personalData),
        CapabilityDescriptor(id: .calendar, title: "Календарь", category: .personalData),
        CapabilityDescriptor(id: .reminders, title: "Напоминания", category: .personalData),
        CapabilityDescriptor(id: .faceID, title: "Face ID", category: .security),
        CapabilityDescriptor(id: .healthKit, title: "Здоровье (HealthKit)", category: .health),
    ]

    private let provider: any CapabilitySnapshotProviding

    init(provider: any CapabilitySnapshotProviding = StaticCapabilitySnapshotProvider()) {
        self.provider = provider
    }

    var descriptors: [CapabilityDescriptor] { Self.catalog }

    func descriptor(for id: CapabilityID) -> CapabilityDescriptor {
        // The catalog covers every CapabilityID (enforced by tests).
        Self.catalog.first { $0.id == id }!
    }

    func snapshot(for id: CapabilityID) -> CapabilitySnapshot {
        provider.snapshot(for: id)
    }

    /// Snapshots of all capabilities, in catalog order.
    func snapshots() -> [CapabilitySnapshot] {
        Self.catalog.map { snapshot(for: $0.id) }
    }
}
