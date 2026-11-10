import ABSAppModel
import ABSCore
import ABSUI
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// The Logs screen, a port of `pages/logs.vue`: this launch's log, newest first, with level,
/// category and text filters, server address masking, and copy, share and (on a Mac) export.
/// Everything shown or exported has tokens removed by ``LogExporter``.
struct LogsView: View {
    @State private var model: LogsModel
    @State private var copied = false
    @State private var isExporting = false

    init(model: LogsModel = LogsModel()) {
        _model = State(initialValue: model)
    }

    var body: some View {
        @Bindable var model = model
        let rows = model.rows
        List {
            Section {
                Picker(selection: $model.minimumLevel) {
                    ForEach(LogEntry.Level.allCases, id: \.self) { level in
                        Text(verbatim: level.label).tag(level)
                    }
                } label: {
                    Text(verbatim: L10n.string("LabelLogMinimumLevel"))
                }
                Picker(selection: $model.category) {
                    Text(verbatim: L10n.string("LabelAll")).tag(String?.none)
                    ForEach(model.categories, id: \.self) { category in
                        // Categories are the identifiers shown in each log line, so they aren't translated.
                        Text(verbatim: category).tag(String?.some(category))
                    }
                } label: {
                    Text(verbatim: L10n.string("LabelLogCategory"))
                }
                Toggle(isOn: $model.masksServerAddress) {
                    Text(verbatim: L10n.string("ButtonMaskServerAddress"))
                }
            } footer: {
                Text(verbatim: L10n.string("MessageLogsCurrentLaunchOnly"))
            }

            Section {
                if !rows.isEmpty {
                    ForEach(rows) { row in
                        LogRow(row: row)
                    }
                } else if model.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else if model.loadFailed {
                    Text(verbatim: L10n.string("MessageLogsLoadFailed"))
                    Button {
                        Task { await model.load() }
                    } label: {
                        Text(verbatim: L10n.string("ButtonRetry"))
                    }
                } else {
                    Text(verbatim: L10n.string("MessageNoLogs"))
                        .foregroundStyle(ABSColor.mutedForeground)
                }
            }
        }
        .searchable(text: $model.searchText, prompt: Text(verbatim: L10n.string("ButtonSearch")))
        .navigationTitle(Text(verbatim: L10n.string("ButtonLogs")))
        .toolbar { actions(text: model.exportText) }
        #if os(macOS)
            .fileExporter(
                isPresented: $isExporting, item: LogsFile(text: model.exportText),
                contentTypes: [.plainText], defaultFilename: LogsFile.filename
            ) { result in
                if case .failure(let error) = result {
                    Log.ui.error("Couldn't export the logs: \(String(describing: error), privacy: .public)")
                }
            }
        #endif
        .task { await model.load() }
        .refreshable { await model.load() }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    @ToolbarContentBuilder
    private func actions(text: String) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                copy(text)
            } label: {
                Label {
                    Text(verbatim: L10n.string("ButtonCopyAll"))
                } icon: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
            }
            .disabled(text.isEmpty)
            ShareLink(item: LogsFile(text: text), preview: SharePreview(LogsFile.filename)) {
                Label {
                    Text(verbatim: L10n.string("ButtonShare"))
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            .disabled(text.isEmpty)
            #if os(macOS)
                Button {
                    isExporting = true
                } label: {
                    Label {
                        Text(verbatim: L10n.string("ButtonExport"))
                    } icon: {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
                .disabled(text.isEmpty)
            #endif
        }
    }

    private func copy(_ text: String) {
        #if os(iOS)
            UIPasteboard.general.string = text
        #else
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        #endif
        copied = true
        AccessibilityNotification.Announcement(L10n.string("MessageLogsCopied")).post()
    }
}

/// One entry as monospaced, selectable text; errors and faults in the error colour.
private struct LogRow: View {
    let row: LogsModel.Row

    var body: some View {
        Text(verbatim: row.text)
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(row.entry.level >= .error ? AnyShapeStyle(ABSColor.error) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}

/// The exported logs as a plain text file.
struct LogsFile: Transferable {
    static let filename = "audiobookshelf-logs.txt"

    let text: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { file in Data(file.text.utf8) }
            .suggestedFileName(filename)
    }
}

extension LogEntry.Level {
    /// The localized level name.
    fileprivate var label: String {
        switch self {
        case .debug: L10n.string("LabelLogLevelDebug")
        case .info: L10n.string("LabelLogLevelInfo")
        case .notice: L10n.string("LabelLogLevelNotice")
        case .error: L10n.string("LabelLogLevelError")
        case .fault: L10n.string("LabelLogLevelFault")
        }
    }
}

#Preview {
    NavigationStack {
        LogsView()
    }
}
