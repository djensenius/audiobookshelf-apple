import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The year in review (legacy `components/stats/YearInReviewBanner.vue`): a year picker, a
/// switch between the user's and the server's year for admins, and the shareable card.
///
/// The card is shown as the image that is shared, rendered once its covers have loaded.
struct YearInReviewView: View {
    @Environment(\.statsService) private var service
    @State private var model: YearInReviewModel?

    var body: some View {
        content
            .navigationTitle(Text(verbatim: L10n.string("HeaderYearInReview")))
            .task {
                guard let service else { return }
                let model = model ?? YearInReviewModel(service: service)
                self.model = model
                await model.loadIfNeeded()
            }
    }

    @ViewBuilder private var content: some View {
        if let model {
            YearInReviewContentView(model: model)
        } else if service == nil {
            ErrorStateView(title: L10n.string("MessageYearInReviewLoadFailed"))
        } else {
            LoadingView()
        }
    }
}

private struct YearInReviewContentView: View {
    let model: YearInReviewModel

    @Environment(\.serverID) private var serverID
    @Environment(\.imagePipeline) private var pipeline
    @Environment(\.displayScale) private var displayScale
    @Environment(\.locale) private var locale
    @Environment(\.openURL) private var openURL
    @State private var layout = YearInReviewLayout.card
    /// The confirmation shown under the card after copying or saving the image.
    @State private var confirmationKey: String?
    /// Why the last save to Photos failed; shown as an alert.
    @State private var photoFailure: PhotoSaveOutcome?
    @State private var rendered = YearInReviewRenderSlot<YearInReviewShareImage>()
    /// A render started by the retry button; cancelled when the selection changes.
    @State private var retryTask: Task<Void, Never>?

    private var shareImage: YearInReviewShareImage? { rendered.image }
    /// Whether the last render of the loaded stats produced no image.
    private var renderFailed: Bool { rendered.failed }

    /// What the card shows now. A successful refresh changes the key even when the stats are
    /// unchanged, so covers that failed to download are fetched again.
    private var renderKey: YearInReviewRenderKey {
        YearInReviewRenderKey(
            content: model.content, year: model.year, variant: model.variant, scale: renderScale, locale: locale,
            loadRevision: model.loadRevision, layout: layout)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: ABSSpacing.large) {
                controls
                if model.error != nil, model.content != nil, !model.isLoading {
                    RefreshFailedRow { Task { await model.load() } }
                }
                card
                if let confirmationKey, shareImage != nil {
                    Text(verbatim: L10n.string(confirmationKey))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(ABSSpacing.large)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let shareImage {
                    ShareLink(
                        item: shareImage,
                        preview: SharePreview(
                            Text(verbatim: L10n.string("HeaderYearInReviewYear", String(model.year))),
                            image: Image(decorative: shareImage.cgImage, scale: renderScale))
                    ) {
                        Label {
                            Text(verbatim: L10n.string("ButtonShare"))
                        } icon: {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                if let shareImage {
                    imageActions(shareImage)
                }
            }
            #if os(macOS)
                // No pull to refresh on macOS.
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await model.load() }
                    } label: {
                        Label {
                            Text(verbatim: L10n.string("ButtonRefresh"))
                        } icon: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isLoading)
                }
            #endif
        }
        .refreshable { await model.load() }
        .alert(
            Text(verbatim: L10n.string("HeaderYearInReviewPhotosFailed")),
            isPresented: Binding(get: { photoFailure != nil }, set: { if !$0 { photoFailure = nil } }),
            presenting: photoFailure
        ) { failure in
            #if os(iOS)
                if failure.offersSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                    Button {
                        openURL(url)
                    } label: {
                        Text(verbatim: L10n.string("ButtonOpenSettings"))
                    }
                }
            #endif
            Button(role: .cancel) {
            } label: {
                Text(verbatim: L10n.string("ButtonOk"))
            }
        } message: { failure in
            Text(verbatim: L10n.string(failure.messageKey))
        }
        .task(id: renderKey) {
            confirmationKey = nil
            retryTask?.cancel()
            retryTask = nil
            await render(renderKey)
        }
    }

    private var controls: some View {
        VStack(spacing: ABSSpacing.medium) {
            Picker(
                selection: Binding(get: { model.year }, set: { year in Task { await model.select(year: year) } })
            ) {
                ForEach(model.availableYears, id: \.self) { year in
                    Text(verbatim: String(year)).tag(year)
                }
            } label: {
                Text(verbatim: L10n.string("LabelYearInReviewYear"))
            }
            .pickerStyle(.menu)
            if model.availableVariants.count > 1 {
                Picker(
                    selection: Binding(
                        get: { model.variant }, set: { variant in Task { await model.select(variant: variant) } })
                ) {
                    ForEach(model.availableVariants) { variant in
                        Text(verbatim: L10n.string(Self.labelKey(variant))).tag(variant)
                    }
                } label: {
                    Text(verbatim: L10n.string("LabelYearInReviewVariant"))
                }
                .pickerStyle(.segmented)
            }
            Picker(selection: $layout) {
                ForEach(YearInReviewLayout.allCases) { layout in
                    Text(verbatim: L10n.string(layout.labelKey)).tag(layout)
                }
            } label: {
                Text(verbatim: L10n.string("LabelLayout"))
            }
            .pickerStyle(.segmented)
        }
    }

    /// Copy, and on iOS save to Photos (on macOS the share menu offers Photos).
    private func imageActions(_ image: YearInReviewShareImage) -> some View {
        Menu {
            Button {
                YearInReviewClipboard.copy(png: image.png)
                confirm("MessageYearInReviewImageCopied")
            } label: {
                Label {
                    Text(verbatim: L10n.string("ButtonYearInReviewCopyImage"))
                } icon: {
                    Image(systemName: "doc.on.doc")
                }
            }
            #if os(iOS)
                Button {
                    let key = renderKey
                    Task { await saveToPhotos(image, renderedFor: key) }
                } label: {
                    Label {
                        Text(verbatim: L10n.string("ButtonYearInReviewSaveToPhotos"))
                    } icon: {
                        Image(systemName: "photo.badge.plus")
                    }
                }
            #endif
        } label: {
            Label {
                Text(verbatim: L10n.string("LabelMore"))
            } icon: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    #if os(iOS)
        /// Saves `image`, rendered for `key`. The result is shown only if the selection is still
        /// `key`'s: the saved PNG belongs to it, not to a year or layout picked meanwhile.
        private func saveToPhotos(_ image: YearInReviewShareImage, renderedFor key: YearInReviewRenderKey) async {
            let outcome = await YearInReviewPhotoSaver(library: SystemPhotoLibrary()).save(png: image.png)
            guard outcome.isShown(savedFrom: key, current: renderKey) else { return }
            if outcome == .saved {
                confirm(outcome.messageKey)
            } else {
                photoFailure = outcome
            }
        }
    #endif

    private func confirm(_ key: String) {
        confirmationKey = key
        AccessibilityNotification.Announcement(L10n.string(key)).post()
    }

    @ViewBuilder private var card: some View {
        if let shareImage, model.content != nil {
            Image(decorative: shareImage.cgImage, scale: renderScale)
                .resizable()
                .scaledToFit()
                .clipShape(.rect(cornerRadius: ABSRadius.large))
                .accessibilityElement()
                .accessibilityAddTraits(.isImage)
                .accessibilityLabel(Text(verbatim: summary))
        } else if model.content == nil, model.error != nil, !model.isLoading {
            ErrorStateView(title: L10n.string("MessageYearInReviewLoadFailed")) {
                Task { await model.load() }
            }
        } else if renderFailed, model.content != nil {
            ErrorStateView(title: L10n.string("MessageYearInReviewLoadFailed")) {
                retryTask?.cancel()
                let key = renderKey
                retryTask = Task { await render(key) }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 300)
        }
    }

    /// The display's scale, at least 2x, so the shared image is sharp on other screens too.
    private var renderScale: Double { max(displayScale, 2) }

    private var summary: String {
        guard let content = model.content else { return "" }
        return YearInReviewCard.summary(for: content, year: model.year, locale: locale, layout: layout)
    }

    static func labelKey(_ variant: YearInReviewVariant) -> String {
        switch variant {
        case .user: "LabelYearInReviewUser"
        case .server: "LabelYearInReviewServer"
        }
    }

    /// Loads the covers first, then renders the card for `key`: `ImageRenderer` doesn't wait
    /// for them. The image is published only if `key` is still the selection when it's done.
    private func render(_ key: YearInReviewRenderKey) async {
        // Never show or share the previous year's or variant's image while this one renders.
        rendered.begin(key)
        guard let content = key.content else { return }
        let covers = await YearInReviewCovers.load(ids: content.coverItemIDs, serverID: serverID, pipeline: pipeline)
        guard !Task.isCancelled, key == renderKey else { return }
        let card = YearInReviewCard(
            content: content, year: key.year, covers: covers, locale: key.locale, layout: key.layout)
        let image = YearInReviewShareImage.render(card, variant: key.variant, scale: key.scale)
        rendered.finish(image, for: key, current: renderKey)
    }
}

/// What the year in review card's image depends on.
struct YearInReviewRenderKey: Hashable {
    var content: YearInReviewContent?
    var year: Int
    var variant: YearInReviewVariant
    var scale: Double
    var locale: Locale
    /// The model's ``YearInReviewModel/loadRevision``: bumped by each successful refresh.
    var loadRevision = 0
    var layout = YearInReviewLayout.card

    /// Whether `other` shows the same card, perhaps from another load of the same stats.
    func isSameSelection(as other: Self) -> Bool {
        var other = other
        other.loadRevision = loadRevision
        return self == other
    }
}

/// The card image shown and shared. Renders await covers, so an earlier one can finish after
/// the selection changed; its image is dropped instead of replacing the new selection's.
struct YearInReviewRenderSlot<Image> {
    private(set) var image: Image?
    /// Whether the render of ``key`` finished without an image.
    private(set) var failed = false
    /// The render started last.
    private(set) var key: YearInReviewRenderKey?

    /// Starts rendering `key`, clearing the image so another selection's isn't shown meanwhile.
    /// A re-render of the same selection after a refresh keeps showing the current image; a
    /// retry of the same key starts over.
    mutating func begin(_ key: YearInReviewRenderKey) {
        let isRefresh = self.key.map { $0 != key && $0.isSameSelection(as: key) } ?? false
        self.key = key
        if !isRefresh {
            image = nil
            failed = false
        }
    }

    /// Publishes a render of `key` unless another render began since or `current`, the selection
    /// now, isn't `key`. Returns whether it was published.
    @discardableResult
    mutating func finish(_ image: Image?, for key: YearInReviewRenderKey, current: YearInReviewRenderKey) -> Bool {
        guard key == self.key, key == current else { return false }
        self.image = image
        failed = image == nil
        return true
    }
}
