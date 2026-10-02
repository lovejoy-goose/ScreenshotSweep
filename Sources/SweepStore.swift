import Photos
import SwiftUI
import UIKit

enum AccessState: Equatable {
    case unknown, notDetermined, denied, restricted, limited, full
}

enum Decision {
    case keep, delete
}

/// Holds all sorting state. The photo library is never modified except in `deleteCandidates()`,
/// which is only called after an explicit confirmation in the review screen.
///
/// Invariant: `assets[0..<history.count]` are already decided, in decision order;
/// `assets[history.count]` is the current screenshot.
@MainActor
final class SweepStore: NSObject, ObservableObject {
    static let batchSize = 30

    @Published private(set) var access: AccessState = .unknown
    @Published private(set) var assets: [PHAsset] = []
    @Published private(set) var decisions: [String: Decision] = [:]
    @Published private(set) var history: [String] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isDeleting = false
    @Published private(set) var deletedTotal = 0
    @Published var showReview = false
    @Published var errorMessage: String?
    @Published var infoMessage: String?

    let imageManager = PHCachingImageManager()
    private var observing = false

    var current: PHAsset? { history.count < assets.count ? assets[history.count] : nil }
    var processedCount: Int { history.count }
    var remainingCount: Int { max(assets.count - history.count, 0) }
    var candidates: [PHAsset] { assets.filter { decisions[$0.localIdentifier] == .delete } }
    var canUndo: Bool { !history.isEmpty }
    var isFinished: Bool { !assets.isEmpty && current == nil }

    // MARK: Authorization

    func start() {
        updateAccess(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        if access == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                Task { @MainActor in self.updateAccess(status) }
            }
        }
    }

    private func updateAccess(_ status: PHAuthorizationStatus) {
        switch status {
        case .notDetermined: access = .notDetermined
        case .denied: access = .denied
        case .restricted: access = .restricted
        case .limited: access = .limited
        case .authorized: access = .full
        @unknown default: access = .denied
        }
        if access == .full || access == .limited {
            if !observing {
                PHPhotoLibrary.shared().register(self)
                observing = true
            }
            reload()
        }
    }

    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    func presentLimitedPicker() {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController })
            .first else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top)
    }

    // MARK: Fetching

    func reload() {
        isLoading = true
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType == %d AND (mediaSubtypes & %d) != 0",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaSubtype.photoScreenshot.rawValue
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: options)

        var fetched: [PHAsset] = []
        fetched.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            // Double-check the subtype in code, as required.
            if asset.mediaSubtypes.contains(.photoScreenshot) { fetched.append(asset) }
        }

        // Keep already-decided assets first (in decision order) so the invariant holds.
        let byID = Dictionary(uniqueKeysWithValues: fetched.map { ($0.localIdentifier, $0) })
        let keptHistory = history.filter { byID[$0] != nil }
        let decidedSet = Set(keptHistory)
        history = keptHistory
        decisions = decisions.filter { decidedSet.contains($0.key) }
        assets = keptHistory.compactMap { byID[$0] } + fetched.filter { !decidedSet.contains($0.localIdentifier) }
        isLoading = false
    }

    // MARK: Decisions

    func decide(_ decision: Decision) {
        guard let asset = current else { return }
        decisions[asset.localIdentifier] = decision
        history.append(asset.localIdentifier)
        if history.count % Self.batchSize == 0 || current == nil {
            if !candidates.isEmpty || current == nil { showReview = true }
        }
    }

    func undo() {
        guard let last = history.popLast() else { return }
        decisions[last] = nil
    }

    func toggleCandidate(_ asset: PHAsset) {
        let id = asset.localIdentifier
        guard decisions[id] != nil else { return }
        decisions[id] = decisions[id] == .delete ? .keep : .delete
    }

    // MARK: Deletion (the only place that modifies the library)

    func deleteCandidates() {
        let toDelete = candidates
        guard !toDelete.isEmpty, !isDeleting else { return }
        isDeleting = true
        let count = toDelete.count
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(toDelete as NSArray)
        }) { success, error in
            Task { @MainActor in
                self.isDeleting = false
                if success {
                    self.deletedTotal += count
                    self.infoMessage = "Удалено: \(count). Скриншоты лежат в «Недавно удалённых» ещё 30 дней."
                    self.reload()
                } else if let error = error as NSError?,
                          error.domain == PHPhotosErrorDomain,
                          error.code == PHPhotosError.userCancelled.rawValue {
                    // User tapped "Don't allow" in the system dialog — nothing changed.
                } else {
                    self.errorMessage = "Не удалось удалить: \(error?.localizedDescription ?? "неизвестная ошибка"). Медиатека не изменена."
                }
            }
        }
    }
}

extension SweepStore: PHPhotoLibraryChangeObserver {
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            self.updateAccessSilently()
            self.reload()
        }
    }

    private func updateAccessSilently() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        access = status == .limited ? .limited : (status == .authorized ? .full : access)
    }
}
