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
    /// state's message instead, and anything pushed over it is popped. Tapping a row plays it
    /// through the model and pushes Now Playing once it starts. A play that fails, or that the
    /// streaming policy blocks on a metered network, presents an alert instead
    /// (``CarPlayRootModel/alert``): Stream or Cancel for "ask", the reason alone otherwise. The
    /// alert is dismissed once the failure changes or clears, for example when the phone answered
    /// it; ``CarPlayAlertPresenter`` presents one alert at a time. A play that ends after a sign-out
    /// or switch shows nothing. Covers come from the shared image pipeline: a row shows a cached
    /// cover at once, or none until it's decoded.
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
            let model = CarPlayRootModel(
                gate: { environment.lifecycle.gate }, store: environment.library?.store,
                playItem: { identity in
                    RootView.playback(environment.playback.participant, accounts: environment.accounts, for: identity)?
                        .playItem
                },
                playing: { environment.playback.current.mediaKey }, playback: environment.playback.current,
                playbackSession: { environment.playback.current.current },
                limits: CarPlayLimits(
                    maximumItemCount: min(12, CPListTemplate.maximumItemCount),
                    maximumSectionCount: CPListTemplate.maximumSectionCount),
                labels: Self.labels,
                imageBucket: ImageWidthBucket(pixelWidth: imageSize.width * scale))
            self.model = model

            let list = CPListTemplate(title: Self.labels.continueListening, sections: [])
            list.tabImage = UIImage(systemName: "play.circle")
            continueTemplate = list
            let tabs = CPTabBarTemplate(templates: [list])
            interfaceController.setRootTemplate(tabs, animated: false, completion: nil)
            observeContent()
            observeLoadTrigger()
            observeAlert()
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
            guard let model, aTemplate is CPTabBarTemplate || aTemplate === continueTemplate else { return }
            if hasShownContinue { Task { await model.refresh() } }
            hasShownContinue = true
        }

        // MARK: - Templates

        private func show(_ content: CarPlayRootContent) {
            guard content != shownContent, let continueTemplate else { return }
            shownContent = content
            guard case .tabs(let list, let playingRowID) = content else {
                if let interfaceController, interfaceController.templates.count > 1 {
                    interfaceController.popToRootTemplate(animated: true, completion: nil)
                }
                continueTemplate.emptyViewTitleVariants = [Self.title(of: content)]
                continueTemplate.emptyViewSubtitleVariants = Self.subtitle(of: content).map { [$0] } ?? []
                continueTemplate.updateSections([])
                keepCovers(for: [])
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
            keepCovers(for: Set(list.rows.compactMap(\.image)))
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
        /// disconnected pushes nothing, even onto a newer connection.
        private func showNowPlaying(after play: Task<CarPlayPlayOutcome, Never>) {
            guard let wait = nowPlayingWaiter.wait(for: play) else { return }
            Task { [weak self] in
                guard await wait.value, let interfaceController = self?.interfaceController else { return }
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
            }
            return nil
        }

        /// Drops the covers and decodes of rows no longer shown.
        private func keepCovers(for keys: Set<ImageKey>) {
            covers = covers.filter { keys.contains($0.key) }
            for (key, load) in coverLoads where !keys.contains(key) {
                load.cancel()
                coverLoads[key] = nil
            }
        }

        // MARK: - Strings

        private static var labels: CarPlayLabels {
            CarPlayLabels(
                continueListening: L10n.string("LabelContinueListening"), libraries: L10n.string("HeaderLibraries"),
                books: L10n.string("LabelBooks"), podcasts: L10n.string("LabelPodcasts"),
                series: L10n.string("LabelSeries"), authors: L10n.string("LabelAuthors"),
                more: L10n.string("LabelMore"))
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
