#if canImport(CarPlay) && os(iOS)
    import ABSAppModel
    import ABSCore
    import ABSUI
    import CarPlay

    /// Scene delegate for the CarPlay audio app scene declared in `Info.plist` (#79): a thin
    /// adapter that shows ``CarPlayRootModel``'s content in CarPlay's templates.
    ///
    /// The root is a tab bar with the Continue tab. When the model has no rows to show (loading,
    /// signed out, the store unavailable, a failed load), the tab's list is empty and shows the
    /// state's message instead; anything pushed over it is popped only when the account signs out
    /// or switches (``CarPlayBrowseModel/keepsBrowsing(for:)``). Tapping a row plays it
    /// through the model and pushes Now Playing once it starts. A play that fails, or that the
    /// streaming policy blocks on a metered network, presents an alert instead
    /// (``CarPlayRootModel/alert``): Stream or Cancel for "ask", the reason alone otherwise. The
    /// alert is dismissed once the failure changes or clears, for example when the phone answered
    /// it; ``CarPlayAlertPresenter`` presents one alert at a time. A play that ends after a sign-out
    /// or switch shows nothing. Covers come from the shared image pipeline: a row shows a cached
    /// cover at once, or none until it's decoded.
    ///
    /// The Library and Latest tabs (#80) show ``CarPlayBrowseModel``'s lists, one model per
    /// signed-in account: a row that opens a list pushes it, "More…" replaces the list's rows with
    /// its next page in place, and a book or episode plays like a Continue row. The Latest tab is
    /// shown while the account has a podcast library. Each list reloads when it shows again.
    final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate,
        CPInterfaceControllerDelegate
    {
        private var interfaceController: CPInterfaceController?
        private var model: CarPlayRootModel?
        private var continueTemplate: CPListTemplate?
        private var shownContent: CarPlayRootContent?
        private var loadedTrigger: CarPlayRootModel.LoadTrigger?
        private var hasShownContinue = false
        private var alerts = CarPlayAlertPresenter<PlayerErrorMessage>()
        /// The plays awaited to show Now Playing, by connection.
        private let nowPlayingWaiter = CarPlayNowPlayingWaiter()
        private var pixelBox = PixelBox(width: 1, height: 1)
        /// The covers the rows show, kept so the pipeline doesn't evict them (``CoverImage``).
        private var covers: [ImageKey: CoverImage] = [:]
        private var coverLoads: [ImageKey: Task<Void, Never>] = [:]
        private var limits = CarPlayLimits.standard
        private var imageBucket = ImageWidthBucket.small
        private var tabBar: CPTabBarTemplate?
        private var libraryTemplate: CPListTemplate?
        private var latestTemplate: CPListTemplate?
        /// The Library and Latest tabs' model for the signed-in account.
        private var browse: CarPlayBrowseModel?
        /// The browse lists shown: the tabs' roots and the lists pushed over them.
        private var browseTemplates: [BrowseTemplate] = []
        /// Bumped by each ``observeBrowse()``, so only the latest observation renders again.
        private var browseObservation = 0
        /// The images of the rows shown, by tab, so neither tab's covers evict the other's.
        private var continueImages: Set<ImageKey> = []
        private var browseImages: Set<ImageKey> = []

        func templateApplicationScene(
            _ templateApplicationScene: CPTemplateApplicationScene,
            didConnect interfaceController: CPInterfaceController
        ) {
            self.interfaceController = interfaceController
            interfaceController.delegate = self
            // CarPlay can launch the app without a window, so the session starts here too.
            // It is safe to call from every scene: only the first call runs.
            let environment = AppEnvironment.shared
            Task { await environment.lifecycle.start() }

            let scale = interfaceController.carTraitCollection.displayScale
            let imageSize = CPListItem.maximumImageSize
            pixelBox = PixelBox(size: imageSize, scale: scale)
            limits = CarPlayLimits(
                maximumItemCount: min(12, CPListTemplate.maximumItemCount),
                maximumSectionCount: CPListTemplate.maximumSectionCount)
            imageBucket = ImageWidthBucket(pixelWidth: imageSize.width * scale)
            let model = CarPlayRootModel(
                gate: { environment.lifecycle.gate }, store: environment.library?.store,
                playItem: { identity in
                    RootView.playback(environment.playback.participant, accounts: environment.accounts, for: identity)?
                        .playItem
                },
                playing: { environment.playback.current.mediaKey }, playback: environment.playback.current,
                playbackSession: { environment.playback.current.current },
                limits: limits, labels: Self.labels, imageBucket: imageBucket)
            self.model = model

            let list = CPListTemplate(title: Self.labels.continueListening, sections: [])
            list.tabImage = UIImage(systemName: "play.circle")
            continueTemplate = list
            let library = CPListTemplate(title: Self.labels.libraries, sections: [])
            library.tabImage = UIImage(systemName: "books.vertical")
            libraryTemplate = library
            browseTemplates = [BrowseTemplate(library, .libraries)]
            let latest = CPListTemplate(title: Self.labels.latest, sections: [])
            latest.tabImage = UIImage(systemName: "clock")
            latestTemplate = latest
            let tabs = CPTabBarTemplate(templates: [list, library])
            tabBar = tabs
            interfaceController.setRootTemplate(tabs, animated: false, completion: nil)
            observeContent()
            observeLoadTrigger()
            observeAlert()
            observeBrowse()
        }

        func templateApplicationScene(
            _ templateApplicationScene: CPTemplateApplicationScene,
            didDisconnectInterfaceController interfaceController: CPInterfaceController
        ) {
            coverLoads.values.forEach { $0.cancel() }
            coverLoads = [:]
            covers = [:]
            model = nil
            continueTemplate = nil
            shownContent = nil
            loadedTrigger = nil
            hasShownContinue = false
            alerts = CarPlayAlertPresenter()
            nowPlayingWaiter.disconnect()
            browse = nil
            browseTemplates = []
            tabBar = nil
            libraryTemplate = nil
            latestTemplate = nil
            continueImages = []
            browseImages = []
            self.interfaceController = nil
        }

        // MARK: - Observing the model

        private func observeContent() {
            guard let model else { return }
            let content = withObservationTracking {
                model.content
            } onChange: { [weak self] in
                Task { @MainActor in self?.observeContent() }
            }
            show(content)
        }

        private func observeLoadTrigger() {
            guard let model else { return }
            let trigger = withObservationTracking {
                model.loadTrigger
            } onChange: { [weak self] in
                Task { @MainActor in self?.observeLoadTrigger() }
            }
            guard trigger != loadedTrigger else { return }
            loadedTrigger = trigger
            Task { await model.update() }
            updateBrowse(for: trigger.identity)
        }

        private func observeAlert() {
            guard let model else { return }
            let alert = withObservationTracking {
                model.alert
            } onChange: { [weak self] in
                Task { @MainActor in self?.observeAlert() }
            }
            perform(alerts.request(alert))
        }

        /// Reloads the shelves when the Continue tab shows again, for example after Now Playing.
        func templateWillAppear(_ aTemplate: CPTemplate, animated: Bool) {
            refreshBrowse(aTemplate)
            guard let model, aTemplate is CPTabBarTemplate || aTemplate === continueTemplate else { return }
            if hasShownContinue { Task { await model.refresh() } }
            hasShownContinue = true
        }

        // MARK: - Templates

        private func show(_ content: CarPlayRootContent) {
            guard content != shownContent, let continueTemplate else { return }
            shownContent = content
            guard case .tabs(let list, let playingRowID) = content else {
                continueTemplate.emptyViewTitleVariants = [Self.title(of: content)]
                continueTemplate.emptyViewSubtitleVariants = Self.subtitle(of: content).map { [$0] } ?? []
                continueTemplate.updateSections([])
                continueImages = []
                keepCovers()
                return
            }
            continueTemplate.emptyViewTitleVariants = [L10n.string("MessageNoItems")]
            continueTemplate.emptyViewSubtitleVariants = []
            let sections = list.sections.map { section in
                CPListSection(
                    items: section.rows.map { listItem(for: $0, isPlaying: $0.id == playingRowID) },
                    header: section.header, sectionIndexTitle: nil)
            }
            continueTemplate.updateSections(sections)
            continueImages = Set(list.rows.compactMap(\.image))
            keepCovers()
        }

        private func listItem(for row: CarPlayRow, isPlaying: Bool) -> CPListItem {
            let image = row.image.flatMap(cover(for:)).map { UIImage(cgImage: $0.cgImage) }
            let item = CPListItem(text: row.text, detailText: nil, image: image)
            if let progress = row.progress { item.playbackProgress = CGFloat(progress) }
            item.isPlaying = isPlaying
            item.isEnabled = row.isEnabled
            item.handler = { [weak self] _, completion in
                self?.select(row)
                completion()
            }
            return item
        }

        private func select(_ row: CarPlayRow) {
            guard let play = model?.play(row) else { return }
            showNowPlaying(after: play)
        }

        /// Pushes Now Playing once `play` has started; a failed or blocked play shows its alert
        /// instead, and a discarded one nothing. A play from a connection that has since
        /// disconnected pushes nothing, even onto a newer connection: the waiter checks the
        /// connection when the play ends, and the push checks it's still the controller the tap
        /// came from when it runs, which can be after a disconnect and reconnect.
        private func showNowPlaying(after play: Task<CarPlayPlayOutcome, Never>) {
            guard let interfaceController, let wait = nowPlayingWaiter.wait(for: play) else { return }
            Task { [weak self] in
                guard await wait.value, let self, self.interfaceController === interfaceController else { return }
                let nowPlaying = CPNowPlayingTemplate.shared
                guard !interfaceController.templates.contains(where: { $0 === nowPlaying }) else { return }
                interfaceController.pushTemplate(nowPlaying, animated: true, completion: nil)
            }
        }

        /// Performs the presenter's command; a dismissal reports its completion, which may present
        /// the alert wanted by then.
        private func perform(_ command: CarPlayAlertPresenter<PlayerErrorMessage>.Command?) {
            guard let command, let interfaceController else { return }
            switch command {
            case .dismiss:
                interfaceController.dismissTemplate(animated: true) { [weak self] _, _ in
                    Task { @MainActor in
                        guard let self, self.interfaceController === interfaceController else { return }
                        self.perform(self.alerts.didDismiss())
                    }
                }
            case .present(let alert):
                interfaceController.presentTemplate(template(for: alert), animated: true) { [weak self] presented, _ in
                    guard !presented else { return }
                    Task { @MainActor in self?.alerts.didFailToPresent(alert) }
                }
            }
        }

        /// The alert for `message`, with the player's strings: Stream or Cancel for a streaming
        /// confirmation, OK otherwise.
        private func template(for message: PlayerErrorMessage) -> CPAlertTemplate {
            let title = L10n.string(PlayerSlot.messageKey(for: message))
            guard message == .streamingNeedsConfirmation else {
                return CPAlertTemplate(
                    titleVariants: [title],
                    actions: [
                        CPAlertAction(title: L10n.string("ButtonOk"), style: .cancel) { [weak self] _ in
                            self?.model?.dismissAlert()
                        }
                    ])
            }
            return CPAlertTemplate(
                titleVariants: [title],
                actions: [
                    CPAlertAction(title: L10n.string("ButtonStream"), style: .default) { [weak self] _ in
                        guard let play = self?.model?.confirmStreaming() else { return }
                        self?.showNowPlaying(after: play)
                    },
                    CPAlertAction(title: L10n.string("ButtonCancel"), style: .cancel) { [weak self] _ in
                        self?.model?.dismissAlert()
                    },
                ])
        }

        // MARK: - Covers

        /// The cover for `key` if the pipeline has it decoded; otherwise starts decoding it and
        /// shows the rows again once it's there.
        private func cover(for key: ImageKey) -> CoverImage? {
            let environment = AppEnvironment.shared
            if let cover = covers[key] ?? environment.images.pipeline.cachedImage(for: key, pixelBox: pixelBox) {
                covers[key] = cover
                return cover
            }
            guard coverLoads[key] == nil else { return nil }
            let pixelBox = pixelBox
            coverLoads[key] = Task { [weak self] in
                let cover = try? await environment.images.pipeline.image(for: key, pixelBox: pixelBox)
                guard let self, !Task.isCancelled else { return }
                coverLoads[key] = nil
                guard let cover else { return }
                covers[key] = cover
                if let content = shownContent {
                    shownContent = nil
                    show(content)
                }
                browseTemplates.forEach { $0.shown = nil }
                observeBrowse()
            }
            return nil
        }

        /// Drops the covers and decodes of rows no longer shown in any tab.
        private func keepCovers() {
            let keys = continueImages.union(browseImages)
            covers = covers.filter { keys.contains($0.key) }
            for (key, load) in coverLoads where !keys.contains(key) {
                load.cancel()
                coverLoads[key] = nil
            }
        }

        // MARK: - Library and Latest tabs (#80)

        /// A browse list's template and the page it shows.
        private final class BrowseTemplate {
            weak var template: CPListTemplate?
            var destination: CarPlayDestination
            var offset = 0
            /// What the template shows, so an unchanged list isn't rebuilt.
            var shown: (CarPlayList, CarPlayBrowseStatus)?
            var hasAppeared = false

            init(_ template: CPListTemplate, _ destination: CarPlayDestination) {
                self.template = template
                self.destination = destination
            }
        }

        /// Replaces the browse model when the signed-in account changes, dropping the lists pushed
        /// for the previous one, and loads the tabs' roots, which retries a failed load when the
        /// connection comes back.
        private func updateBrowse(for identity: SessionIdentity?) {
            if browse?.keepsBrowsing(for: identity) != true {
                // Signed out or switched: close the old account's pushed lists and Now Playing.
                if let interfaceController, interfaceController.templates.count > 1 {
                    interfaceController.popToRootTemplate(animated: true, completion: nil)
                }
                let store = AppEnvironment.shared.library?.store
                browse = identity.flatMap { identity in
                    guard let store, let service = store.makeServices() else { return nil }
                    return CarPlayBrowseModel(
                        store: store, identity: identity, service: service, limits: limits, labels: Self.labels,
                        imageBucket: imageBucket)
                }
                browseTemplates.removeAll { $0.template !== libraryTemplate && $0.template !== latestTemplate }
                for entry in browseTemplates {
                    entry.offset = 0
                    entry.shown = nil
                }
            }
            if let browse {
                let roots = browseTemplates.map { ($0.destination, $0.offset) }
                Task {
                    for (destination, offset) in roots { await browse.load(destination, offset: offset) }
                }
            }
            observeBrowse()
        }

        /// Shows each browse template's list, and the Latest tab while there's a podcast library,
        /// again each time they change.
        private func observeBrowse() {
            browseObservation += 1
            let observation = browseObservation
            browseTemplates.removeAll { $0.template == nil }
            let browse = browse
            let model = model
            let entries = browseTemplates
            let (lists, latestLibraryID, content) = withObservationTracking {
                (
                    entries.map { entry in
                        browse.map { ($0.list(entry.destination, offset: entry.offset), $0.status(entry.destination)) }
                    },
                    browse?.latestLibraryID,
                    // Without a browse model, the tabs show the root's message.
                    browse == nil ? model?.content : nil
                )
            } onChange: { [weak self] in
                Task { @MainActor in
                    guard let self, self.browseObservation == observation else { return }
                    self.observeBrowse()
                }
            }
            var images: Set<ImageKey> = []
            for (entry, list) in zip(entries, lists) {
                render(entry, list, content: content ?? .loading)
                images.formUnion(list?.0.rows.compactMap(\.image) ?? [])
            }
            browseImages = images
            keepCovers()
            // A Latest list for another library shows once rendered, even if it's loaded already.
            if showLatest(latestLibraryID) { observeBrowse() }
        }

        /// Shows the Latest tab for `libraryID`'s episodes, or hides it without one. Returns whether
        /// its list changed.
        private func showLatest(_ libraryID: String?) -> Bool {
            guard let tabBar, let continueTemplate, let libraryTemplate, let latestTemplate else { return false }
            let destination = libraryID.map { CarPlayDestination.latestEpisodes(libraryID: $0) }
            let entry = browseTemplates.first { $0.template === latestTemplate }
            let changed = entry?.destination != destination
            if changed {
                browseTemplates.removeAll { $0.template === latestTemplate }
                if let destination, let browse {
                    browseTemplates.append(BrowseTemplate(latestTemplate, destination))
                    Task { await browse.load(destination) }
                }
                latestTemplate.updateSections([])
            }
            let templates =
                destination == nil
                ? [continueTemplate, libraryTemplate]
                : [
                    continueTemplate, libraryTemplate, latestTemplate,
                ]
            if tabBar.templates.count != templates.count { tabBar.updateTemplates(templates) }
            return changed
        }

        /// Shows `list` in `entry`'s template; without a browse model (signed out, loading), the
        /// root content's message.
        private func render(
            _ entry: BrowseTemplate, _ page: (CarPlayList, CarPlayBrowseStatus)?, content: CarPlayRootContent
        ) {
            guard let template = entry.template else { return }
            guard let page else {
                entry.shown = nil
                template.emptyViewTitleVariants = [Self.title(of: content)]
                template.emptyViewSubtitleVariants = Self.subtitle(of: content).map { [$0] } ?? []
                template.updateSections([])
                return
            }
            let (list, status) = page
            if let shown = entry.shown, shown.0 == list, shown.1 == status { return }
            entry.shown = page
            var isLatest = false
            if case .latestEpisodes = list.destination { isLatest = true }
            let message =
                switch status {
                case .loading: "MessageLoading"
                case .failed: isLatest ? "MessageLatestEpisodesLoadFailed" : "MessageLibraryItemsLoadFailed"
                case .loaded: isLatest ? "MessageNoLatestEpisodes" : "MessageNoItems"
                }
            template.emptyViewTitleVariants = [L10n.string(message)]
            template.emptyViewSubtitleVariants = []
            let sections = list.sections.map { section in
                CPListSection(
                    items: section.rows.map { row in
                        let item = listItem(for: row, isPlaying: false)
                        item.handler = { [weak self, weak entry] _, completion in
                            if let entry { self?.select(row, from: entry, page: list) }
                            completion()
                        }
                        return item
                    },
                    header: section.header, sectionIndexTitle: nil)
            }
            template.updateSections(sections)
        }

        /// A tapped browse row: plays it, pushes the list it opens, or shows the next page.
        private func select(_ row: CarPlayRow, from entry: BrowseTemplate, page: CarPlayList) {
            guard let browse, let model else { return }
            switch row.action {
            case .play:
                guard let play = model.play(row, in: page.destination, offset: page.offset, of: browse) else { return }
                showNowPlaying(after: play)
            case .open:
                guard let interfaceController, let destination = browse.open(row) else { return }
                let template = CPListTemplate(title: row.text, sections: [])
                template.emptyViewTitleVariants = [L10n.string("MessageLoading")]
                browseTemplates.append(BrowseTemplate(template, destination))
                interfaceController.pushTemplate(template, animated: true, completion: nil)
                Task { await browse.load(destination) }
                observeBrowse()
            case .more(let destination, let offset):
                guard entry.destination == destination else { return }
                entry.offset = offset
                Task { await browse.load(destination, offset: offset) }
                observeBrowse()
            }
        }

        /// Reloads a browse list when it shows again, for example after Now Playing or a pushed
        /// list; not when it first shows, as it's loading then.
        private func refreshBrowse(_ template: CPTemplate) {
            guard let browse, let entry = browseTemplates.first(where: { $0.template === template }) else { return }
            guard entry.hasAppeared else {
                entry.hasAppeared = true
                return
            }
            let (destination, offset) = (entry.destination, entry.offset)
            Task { await browse.refresh(destination, offset: offset) }
        }

        // MARK: - Strings

        private static var labels: CarPlayLabels {
            CarPlayLabels(
                continueListening: L10n.string("LabelContinueListening"), libraries: L10n.string("HeaderLibraries"),
                books: L10n.string("LabelBooks"), podcasts: L10n.string("LabelPodcasts"),
                series: L10n.string("LabelSeries"), authors: L10n.string("LabelAuthors"),
                latest: L10n.string("ButtonLatest"), more: L10n.string("LabelMore"))
        }

        private static func title(of content: CarPlayRootContent) -> String {
            switch content {
            case .loading: L10n.string("MessageLoading")
            case .signedOut: L10n.string("MessageCarPlaySignedOut")
            case .storeUnavailable: L10n.string("MessageStoreUnavailable")
            case .failed: L10n.string("MessageHomeLoadFailed")
            case .tabs: L10n.string("MessageNoItems")
            }
        }

        private static func subtitle(of content: CarPlayRootContent) -> String? {
            guard case .storeUnavailable = content else { return nil }
            return L10n.string("MessageStoreUnavailableHelp")
        }
    }
#endif
