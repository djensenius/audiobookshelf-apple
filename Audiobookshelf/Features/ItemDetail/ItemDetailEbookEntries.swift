import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// What the book screen shows after an ebook action (``EbookActionsModel/Outcome``): an alert
/// title and optional message, and the text VoiceOver announces. The app has no toast, so a send
/// confirms with an alert, as a failure does; a status change shows in the ebook files table and
/// is only announced.
enum EbookActionsPresentation {
    struct Feedback: Hashable {
        /// `nil` when nothing needs dismissing.
        let alertTitle: String?
        /// The server's text for a failure, if it sent one.
        let alertMessage: String?
        let announcement: String
    }

    /// `nil` for ``EbookActionsModel/Outcome/ignored``.
    static func feedback(for outcome: EbookActionsModel.Outcome) -> Feedback? {
        switch outcome {
        case .sent(let deviceName):
            let text = L10n.string("MessageItemDetailEbookSent", deviceName)
            return Feedback(alertTitle: text, alertMessage: nil, announcement: text)
        case .sendFailed(let deviceName, let message):
            let title = L10n.string("MessageItemDetailEbookSendFailed", deviceName)
            return Feedback(alertTitle: title, alertMessage: message, announcement: joined(title, message))
        case .statusChanged(let change):
            let name = change.filename.isEmpty ? L10n.string("LabelEbook") : change.filename
            let key =
                change.makesPrimary ? "MessageItemDetailEbookNowPrimary" : "MessageItemDetailEbookNowSupplementary"
            return Feedback(alertTitle: nil, alertMessage: nil, announcement: L10n.string(key, name))
        case .statusChangeFailed(let message):
            let title = L10n.string("MessageItemDetailEbookStatusFailed")
            return Feedback(alertTitle: title, alertMessage: message, announcement: joined(title, message))
        case .ignored:
            return nil
        }
    }

    private static func joined(_ title: String, _ message: String?) -> String {
        guard let message, !message.isEmpty else { return title }
        return "\(title) \(message)"
    }
}

/// The book More menu's ebook entries: Send ebook to device, a submenu of the user's e-readers,
/// and Set as primary / Set as supplementary for each ebook file. Disabled while one runs.
struct ItemDetailEbookEntries: View {
    let devices: [EReaderDevice]
    let statusChanges: [EbookActionsModel.StatusChange]
    let isBusy: Bool
    let send: (String) -> Void
    let apply: (EbookActionsModel.StatusChange) -> Void

    var body: some View {
        if !devices.isEmpty {
            Menu {
                Section {
                    ForEach(devices, id: \.name) { device in
                        Button {
                            send(device.name)
                        } label: {
                            Text(verbatim: device.name)
                        }
                    }
                } header: {
                    Text(verbatim: L10n.string("LabelSelectADevice"))
                }
            } label: {
                Label {
                    Text(verbatim: L10n.string("ButtonSendEbookToDevice"))
                } icon: {
                    Image(systemName: "paperplane")
                }
            }
            .disabled(isBusy)
        }
        ForEach(statusChanges) { change in
            Button {
                apply(change)
            } label: {
                Label {
                    Text(verbatim: L10n.string(change.titleKey))
                    // Which file, when there is more than one to tell apart.
                    if statusChanges.count > 1, !change.filename.isEmpty {
                        Text(verbatim: change.filename)
                    }
                } icon: {
                    Image(systemName: change.makesPrimary ? "star" : "star.slash")
                }
            }
            .disabled(isBusy)
        }
    }
}
