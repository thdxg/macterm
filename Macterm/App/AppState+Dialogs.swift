import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "AppState+Dialogs")

/// The one dialog `AppState` can have up, and the one way it is confirmed
/// or dismissed.
///
/// Every confirmation the model stages — close pane, close tab, unload or
/// remove a project, bulk-remove a selection, a destructive layout apply —
/// and every notice it raises (layout errors) used to be its own optional
/// with its own request/confirm/cancel triplet and its own `.alert` copy per
/// scene, each hand-gated on `DialogHost`. That is how a confirmation raised
/// from the palette once also opened Settings: a gate forgotten on one of
/// thirteen alerts. One value, one alert per host (`PendingDialogAlert`),
/// and the gate is written once.
extension AppState {
    /// Which scene presents a dialog: the terminal window that asked
    /// (`dialogWindowID`), or the Settings window when the request came from
    /// Settings → Projects.
    enum DialogHost: Equatable {
        case mainWindow
        case settings
    }

    struct PendingDialog: Identifiable {
        /// What the dialog is about — for callers that must know (the CLI's
        /// `layout apply` forces or cancels a staged apply) and for tests.
        /// The strings below are what the user sees; the kind is the fact.
        enum Kind: Equatable {
            case closePane(paneID: UUID, projectID: UUID)
            case closeTab(tabID: UUID, projectID: UUID)
            case unloadProject(UUID)
            case removeProject(UUID)
            case removeSelection
            case applyLayout(projectID: UUID)
            /// A notice, not a question: the layout verb that failed.
            case layoutError(verb: String)
        }

        let id = UUID()
        let kind: Kind
        let title: String
        let message: String
        /// The destructive button's label. nil makes the dialog a notice
        /// with a single OK button and no `onConfirm`.
        let confirmTitle: String?
        let host: DialogHost
        let onConfirm: @MainActor () -> Void

        /// A notice with an OK button. A question is the memberwise init with
        /// a `confirmTitle` and an `onConfirm`.
        static func notice(_ kind: Kind, title: String, message: String, host: DialogHost) -> PendingDialog {
            PendingDialog(kind: kind, title: title, message: message, confirmTitle: nil, host: host, onConfirm: {})
        }
    }

    /// Put `dialog` up, replacing whatever was pending. Two dialogs never
    /// coexist: the app is modal while one is up, and the second request
    /// is the one the user just made.
    func present(_ dialog: PendingDialog) {
        if let current = pendingDialog {
            let was = String(describing: current.kind)
            let now = String(describing: dialog.kind)
            logger.info("dialog \(was, privacy: .public) replaced by \(now, privacy: .public)")
        }
        pendingDialog = dialog
    }

    /// The user chose the destructive option: run it. Cleared before it
    /// runs so an action that presents something itself is not undone.
    func confirmPendingDialog() {
        guard let dialog = pendingDialog else { return }
        pendingDialog = nil
        dialog.onConfirm()
    }

    /// The user cancelled or acknowledged. `id` lets an alert dismiss only
    /// the dialog it was showing: SwiftUI reports the dismissal after a
    /// button ran, and by then a different dialog may be up.
    func dismissPendingDialog(_ id: PendingDialog.ID? = nil) {
        if let id, pendingDialog?.id != id { return }
        pendingDialog = nil
    }

    /// Whether a destructive layout apply is waiting on the user.
    var isLayoutApplyPending: Bool {
        if case .applyLayout? = pendingDialog?.kind { return true }
        return false
    }

    /// Raise a layout notice: `title` defaults to "Couldn't <verb> layout".
    func presentLayoutError(verb: String, message: String, title: String? = nil, host: DialogHost = .mainWindow) {
        present(.notice(
            .layoutError(verb: verb),
            title: title ?? "Couldn't \(verb) layout",
            message: message,
            host: host
        ))
    }
}
