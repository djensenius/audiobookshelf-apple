import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The reader settings (legacy `Reader.vue`'s settings sheet), saved in `AppSettings` for every
/// book. Theme and layout apply to every reader; the text settings only to EPUB (PDF and comic
/// themes change only the page and chrome, ADR 0008).
struct ReaderSettingsMenu: View {
    let kind: ReaderKind
    @Environment(AppSettings.self) private var settings: AppSettings?

    var body: some View {
        Menu {
            if let settings {
                @Bindable var settings = settings
                picker(.theme, selection: $settings.readerSettings.theme, titleKey: \.titleKey)
                picker(.spread, selection: $settings.readerSettings.spread, titleKey: \.titleKey)
                if kind == .epub {
                    picker(.fontFamily, selection: $settings.readerSettings.fontFamily, titleKey: \.titleKey)
                    stepper(
                        .fontScale, value: $settings.readerSettings.fontScale, scale: ReaderSettings.fontScaleScale)
                    stepper(
                        .lineSpacing, value: $settings.readerSettings.lineSpacing,
                        scale: ReaderSettings.lineSpacingScale)
                    stepper(
                        .textStroke, value: $settings.readerSettings.textStroke,
                        scale: ReaderSettings.textStrokeScale)
                }
            }
        } label: {
            Label {
                Text(verbatim: L10n.string("HeaderEreaderSettings"))
            } icon: {
                Image(systemName: "textformat.size")
            }
            .labelStyle(.iconOnly)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
        }
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func picker<Value: Hashable & CaseIterable>(
        _ label: ReaderSettingsLabel, selection: Binding<Value>, titleKey: KeyPath<Value, String>
    ) -> some View where Value.AllCases: RandomAccessCollection {
        Picker(selection: selection) {
            ForEach(Value.allCases, id: \.self) { value in
                Text(verbatim: L10n.string(value[keyPath: titleKey])).tag(value)
            }
        } label: {
            Text(verbatim: L10n.string(label.titleKey))
        }
        .pickerStyle(.menu)
    }

    /// A submenu with the value and buttons a step up and down, since menus can't hold steppers.
    private func stepper(_ label: ReaderSettingsLabel, value: Binding<Int>, scale: ReaderSettings.Scale)
        -> some View
    {
        Menu {
            Button {
                value.wrappedValue = scale.clamp(value.wrappedValue + scale.step)
            } label: {
                Label {
                    Text(verbatim: "+\(scale.step)%")
                } icon: {
                    Image(systemName: "plus")
                }
            }
            .disabled(value.wrappedValue >= scale.range.upperBound)
            Button {
                value.wrappedValue = scale.clamp(value.wrappedValue - scale.step)
            } label: {
                Label {
                    Text(verbatim: "−\(scale.step)%")
                } icon: {
                    Image(systemName: "minus")
                }
            }
            .disabled(value.wrappedValue <= scale.range.lowerBound)
            Button {
                value.wrappedValue = scale.defaultValue
            } label: {
                Text(verbatim: "\(scale.defaultValue)%")
            }
        } label: {
            Text(verbatim: "\(L10n.string(label.titleKey)): \(value.wrappedValue)%")
        }
    }
}
