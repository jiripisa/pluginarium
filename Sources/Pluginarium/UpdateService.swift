import Foundation
import Observation
import Sparkle

/// Auto-update on Sparkle: the feed and the EdDSA public key come from
/// Info.plist (`SUFeedURL`, `SUPublicEDKey`). Every launch asks the feed
/// for a newer version; Sparkle's standard dialog offers it and installs
/// only after the user agrees.
@MainActor
@Observable
final class UpdateService {

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    private(set) var canCheck = false
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        canCheck = controller.updater.canCheckForUpdates
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates,
                                                         options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.canCheck = self.controller.updater.canCheckForUpdates
            }
        }
        // "At launch", not Sparkle's daily schedule: ask now when enabled.
        if controller.updater.automaticallyChecksForUpdates {
            controller.updater.checkForUpdatesInBackground()
        }
    }

    /// "Check for Updates…": always shows a result, also "you're up to date".
    func checkNow() {
        controller.checkForUpdates(nil)
    }
}
