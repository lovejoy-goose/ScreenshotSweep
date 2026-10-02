import Combine
import Foundation

/// Drives pairing: scanned QR → user confirmation → code exchange → Keychain.
/// Publishes only non-secret state; the pairing code is kept privately until it is
/// sent once, and the device token goes straight from the response to the store.
/// One Connector installation holds at most one active connection.
@MainActor
final class PairingCoordinator: ObservableObject {
    enum Status: Equatable {
        case unpaired
        /// Katana rejected the saved credentials (401); they are no longer used.
        case requiresRepair(PairedDevice)
        case reviewing(host: String)
        case pairing(host: String)
        case connected(PairedDevice)
        case failed(PairingError)
    }

    enum Notice: Equatable {
        /// Saved credentials could not be read (e.g. the app was re-signed); pair again.
        case credentialsUnavailable
        case disconnectFailed
    }

    @Published private(set) var status: Status = .unpaired
    @Published private(set) var notice: Notice?
    /// The connection that a confirmed re-pairing will replace, if any.
    @Published private(set) var deviceToReplace: PairedDevice?

    private let client: any PairingClient
    private let store: any SecureTokenStoring
    private let policy: PairingSecurityPolicy
    private let makeDeviceInfo: (String) -> PairingDeviceInfo
    private var pendingPayload: PairingPayload?

    init(client: any PairingClient,
         store: any SecureTokenStoring,
         policy: PairingSecurityPolicy = .release,
         makeDeviceInfo: @escaping (String) -> PairingDeviceInfo = { PairingDeviceInfo.current(displayName: $0) }) {
        self.client = client
        self.store = store
        self.policy = policy
        self.makeDeviceInfo = makeDeviceInfo
        restore()
    }

    var connectionState: ConnectorConnectionState {
        switch status {
        case .unpaired, .reviewing: return .unpaired
        case .requiresRepair: return .revoked
        case .pairing: return .pairing
        case .connected: return .connected
        case .failed: return .error
        }
    }

    /// Reads saved credentials. Missing or unreadable credentials mean `unpaired`.
    func restore() {
        do {
            if let credentials = try store.load() {
                status = credentials.requiresRepair ? .requiresRepair(credentials.device) : .connected(credentials.device)
            } else {
                status = .unpaired
            }
        } catch {
            status = .unpaired
            notice = .credentialsUnavailable
        }
    }

    func handleScannedCode(_ text: String) {
        switch status {
        case .unpaired, .failed: break
        case .requiresRepair(let device): deviceToReplace = device
        case .reviewing, .pairing, .connected: return
        }
        do {
            let payload = try PairingPayloadParser.parse(text, policy: policy)
            pendingPayload = payload
            status = .reviewing(host: payload.displayHost)
        } catch let error as PairingError {
            pendingPayload = nil
            status = .failed(error)
        } catch {
            pendingPayload = nil
            status = .failed(.invalidQR(.malformed))
        }
    }

    /// The user confirmed the host (and, when re-pairing, replacing the old connection).
    func confirm(displayName: String) async {
        guard case .reviewing = status, let payload = pendingPayload else { return }
        // The code is single-use: it is sent at most once, whatever the outcome.
        pendingPayload = nil
        status = .pairing(host: payload.displayHost)

        let device = makeDeviceInfo(DeviceDisplayName.normalize(displayName))
        let response: PairingCompleteResponse
        do {
            response = try await client.completePairing(baseURL: payload.baseURL, code: payload.code, device: device)
        } catch let error as PairingError {
            status = .failed(error)
            return
        } catch {
            status = .failed(.transport)
            return
        }

        let paired = PairedDevice(deviceID: response.deviceID,
                                  displayName: response.displayName.isEmpty ? device.displayName : response.displayName,
                                  pairedAt: response.pairedAt,
                                  baseURL: payload.baseURL)
        do {
            // Overwrites the previous (rejected) connection, if any.
            try store.save(PairingCredentials(token: response.deviceToken, device: paired))
        } catch {
            status = .failed(.keychainFailure)
            return
        }
        notice = nil
        deviceToReplace = nil
        status = .connected(paired)
    }

    /// Abandons a scanned-but-unconfirmed QR or a failed attempt; the previous state is kept.
    func cancel() {
        switch status {
        case .reviewing, .failed:
            pendingPayload = nil
            if let device = deviceToReplace {
                status = .requiresRepair(device)
            } else {
                status = .unpaired
            }
            deviceToReplace = nil
        case .unpaired, .requiresRepair, .pairing, .connected:
            break
        }
    }

    /// Called when Katana answers 401. The credentials are flagged so they are never used
    /// again (also after a restart); the event queue is not touched.
    func markRequiresRepair() {
        guard let credentials = try? store.load() else {
            status = .unpaired
            return
        }
        var flagged = credentials
        flagged.requiresRepair = true
        try? store.save(flagged)
        status = .requiresRepair(credentials.device)
    }

    /// Deletes local credentials only. The server-side device is not revoked (not implemented yet).
    /// Queued events are kept.
    func disconnectLocally() {
        do {
            try store.delete()
            notice = nil
            deviceToReplace = nil
            status = .unpaired
        } catch {
            notice = .disconnectFailed
        }
    }
}
