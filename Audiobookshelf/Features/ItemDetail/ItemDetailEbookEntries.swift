import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// What the book screen shows after an ebook action (``EbookActionsModel/Outcome``): an alert
/// title and optional message, and the text VoiceOver announces. The app has no toast, so a send
/// confirms with an alert, as a failure does; a status change shows in the ebook files table and
/// is only announced. The view announces only when there's no alert, which VoiceOver reads.
enum EbookActionsPresentation {
    struct Feedback: Hashable {
        /// `nil` when nothing needs dismissing.
        let alertTitle: String?
        /// The server's explanation of a failure, if it's worth showing.
        let alertMessage: String?
        let announcement: String
    }

    /// Announced when a send starts, as it can take a while.
    static func sendingAnnouncement(deviceName: String) -> String {
        L10n.string("MessageItemDetailEbookSending", deviceName)
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

/// How long an ebook action's feedback may still be shown. An action takes a ``Ticket`` when it
/// starts; its result is shown only if the ticket is still ``accepts(_:accountID:)``: the menu
/// hasn't ended the lifetime (it disappeared, or shows another item model or account) and the
/// signed-in connection is the one that started it. So a late reply never shows one account's
/// filename or device under another, or on a screen that's gone.
///
/// A class, so a task that outlives the view still sees it ended.
@MainActor
final class EbookFeedbackLifetime {
    struct Ticket: Equatable {
        fileprivate let generation: Int
        let accountID: UUID?
    }

    private var generation = 0

    func ticket(accountID: UUID?) -> Ticket {
        Ticket(generation: generation, accountID: accountID)
    }

    /// Ends every ticket handed out so far.
    func end() {
        generation += 1
    }

    func accepts(_ ticket: Ticket, accountID: UUID?) -> Bool {
        ticket.generation == generation && ticket.accountID == accountID
    }
}

/// The book More menu's ebook entries, in a section headed Ebook: Send ebook to device, a submenu
/// of the user's e-readers, and Set as primary / Set as supplementary for each ebook file, with
/// its filename. Disabled while one runs; Send's icon shows progress meanwhile.
struct ItemDetailEbookEntries: View {
    let devices: [EReaderDevice]
    let statusChanges: [EbookActionsModel.StatusChange]
    let isBusy: Bool
    let send: (String) -> Void
    let apply: (EbookActionsModel.StatusChange) -> Void

    var body: some View {
        if !devices.isEmpty || !statusChanges.isEmpty {
            Section {
                entries
            } header: {
                Text(verbatim: L10n.string("LabelEbook"))
            }
        }
    }

    @ViewBuilder private var entries: some View {
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
                    if isBusy {
                        ProgressView()
                    } else {
                        Image(systemName: "paperplane")
                    }
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
                    // Which file it applies to.
                    if !change.filename.isEmpty {
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
