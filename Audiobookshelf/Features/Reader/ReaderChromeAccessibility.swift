import ABSUI
import SwiftUI

extension View {
    /// A named accessibility action on a reader's page that shows or hides the reader's chrome, as a
    /// tap on the page does (#675). With the chrome hidden, VoiceOver and Switch Control users
    /// otherwise have no way back to its close, contents and settings buttons.
    func readerChromeAccessibilityAction(isChromeVisible: Bool, toggle: @escaping () -> Void) -> some View {
        accessibilityAction(
            named: Text(
                verbatim: isChromeVisible
                    ? L10n.string("ButtonReaderHideControls") : L10n.string("ButtonReaderShowControls")),
            toggle)
    }
}
