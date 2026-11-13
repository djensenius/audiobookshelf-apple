#if canImport(CarPlay) && os(iOS)
    import ABSAppModel
    import ABSUI
    import CarPlay

    /// Now Playing's buttons and lists in CarPlay (#81): a thin adapter that shows
    /// ``CarPlayNowPlayingModel`` on `CPNowPlayingTemplate.shared` (ADR 0006, CarPlay).
    ///
    /// The buttons are the rate, the sleep timer (selected while a timer runs; each tap starts the
    /// next preset, then end of chapter, then turns it off) and the chapters, rebuilt whenever what
    /// they show changes. Up Next opens the queue when it has items, else the chapters. The chapter
    /// list marks the chapter playing and follows playback while it shows; choosing a chapter seeks
    /// to its start and goes back to Now Playing. The mini player stays on.
    @MainActor
    final class CarPlayNowPlayingController: NSObject, CPNowPlayingTemplateObserver {
        /// How the rate button shows the rate.
        enum RateButtonStyle {
            /// `CPNowPlayingPlaybackRateButton`, which the system draws from the Now Playing session.
            case system
            /// A `CPNowPlayingImageButton` showing the rate, for when the system button doesn't
            /// follow the NowPlaying framework's rate (ADR 0006, Consequences).
            case image
        }

        static let rateButtonStyle = RateButtonStyle.system

        private let interfaceController: CPInterfaceController
        private let model: CarPlayNowPlayingModel
        private var isConnected = true
        private var shownButtons: CarPlayNowPlayingButtons?
        private var chapterList: CPListTemplate?
        private var shownChapters: [CarPlayChapterRow]?

        init(interfaceController: CPInterfaceController, model: CarPlayNowPlayingModel) {
            self.interfaceController = interfaceController
            self.model = model
            super.init()
            let template = CPNowPlayingTemplate.shared
            template.allowsMiniPlayer = true
            template.add(self)
            observeButtons()
        }

        /// Stops updating the template; the shared template outlives the connection.
        func disconnect() {
            isConnected = false
            CPNowPlayingTemplate.shared.remove(self)
            chapterList = nil
            shownChapters = nil
        }

        // MARK: - Buttons

        private func observeButtons() {
            guard isConnected else { return }
            let buttons = withObservationTracking {
                model.buttons
            } onChange: { [weak self] in
                Task { @MainActor in self?.observeButtons() }
            }
            guard buttons != shownButtons else { return }
            shownButtons = buttons
            let template = CPNowPlayingTemplate.shared
            template.updateNowPlayingButtons([
                rateButton(rate: buttons.rate), sleepTimerButton(buttons), chaptersButton(buttons),
            ])
            template.isUpNextButtonEnabled = buttons.upNext != nil
            template.upNextTitle = L10n.string(buttons.upNext == .queue ? "HeaderUpNext" : "LabelChapters")
        }

        private func rateButton(rate: Double) -> CPNowPlayingButton {
            let handler: (CPNowPlayingButton) -> Void = { [weak self] _ in self?.model.cycleRate() }
            switch Self.rateButtonStyle {
            case .system: return CPNowPlayingPlaybackRateButton(handler: handler)
            case .image:
                let label = PlaybackSpeedPresentation.label(rate, locale: .autoupdatingCurrent)
                return CPNowPlayingImageButton(image: Self.textImage(label), handler: handler)
            }
        }

        private func sleepTimerButton(_ buttons: CarPlayNowPlayingButtons) -> CPNowPlayingButton {
            let button = CPNowPlayingImageButton(image: Self.symbol("moon.zzz")) { [weak self] _ in
                self?.model.cycleSleepTimer()
            }
            button.isSelected = buttons.isSleepTimerActive
            return button
        }

        private func chaptersButton(_ buttons: CarPlayNowPlayingButtons) -> CPNowPlayingButton {
            let button = CPNowPlayingImageButton(image: Self.symbol("list.bullet")) { [weak self] _ in
                self?.showChapters()
            }
            button.isEnabled = buttons.hasChapters
            return button
        }

        nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if model.buttons.upNext == .queue { showQueue() } else { showChapters() }
            }
        }

        // MARK: - Chapters

        private func showChapters() {
            guard isConnected, !isShown(chapterList) else { return }
            let list = CPListTemplate(title: L10n.string("LabelChapters"), sections: [])
            list.emptyViewTitleVariants = [L10n.string("MessageNoChapters")]
            chapterList = list
            shownChapters = nil
            observeChapters()
            interfaceController.pushTemplate(list, animated: true, completion: nil)
        }

        /// Updates the chapter list while it shows. The current chapter follows the playback time,
        /// so this runs on every tick, but the list changes only when a row does.
        private func observeChapters() {
            guard isConnected, let chapterList else { return }
            let rows = withObservationTracking {
                model.chapters
            } onChange: { [weak self] in
                Task { @MainActor in
                    guard let self, self.isShown(self.chapterList) else {
                        self?.chapterList = nil
                        return
                    }
                    self.observeChapters()
                }
            }
            guard rows != shownChapters else { return }
            shownChapters = rows
            let rate = model.buttons.rate
            let items = rows.map { row in
                let presentation = ChapterRowPresentation(
                    row: row.chapter, position: row.id + 1, rate: rate, locale: .autoupdatingCurrent)
                let item = CPListItem(text: presentation.title, detailText: presentation.startText)
                item.isPlaying = row.isCurrent
                item.handler = { [weak self] _, completion in
                    self?.select(row)
                    completion()
                }
                return item
            }
            chapterList.updateSections([CPListSection(items: items)])
        }

        private func select(_ row: CarPlayChapterRow) {
            Task {
                await model.select(row)
                popToNowPlaying()
            }
        }

        // MARK: - Queue

        private func showQueue() {
            guard isConnected else { return }
            let items = model.queueRows.map { row in
                let item = CPListItem(text: row.title, detailText: row.subtitle)
                item.handler = { [weak self] _, completion in
                    self?.play(row)
                    completion()
                }
                return item
            }
            let list = CPListTemplate(title: L10n.string("HeaderUpNext"), sections: [CPListSection(items: items)])
            interfaceController.pushTemplate(list, animated: true, completion: nil)
        }

        private func play(_ row: QueueRow) {
            Task {
                await model.play(row)
                popToNowPlaying()
            }
        }

        // MARK: - Helpers

        private func isShown(_ template: CPTemplate?) -> Bool {
            guard let template else { return false }
            return interfaceController.templates.contains { $0 === template }
        }

        /// Pops the lists pushed over Now Playing, if it's still in the stack.
        private func popToNowPlaying() {
            let nowPlaying = CPNowPlayingTemplate.shared
            guard isConnected, isShown(nowPlaying), interfaceController.topTemplate !== nowPlaying else { return }
            interfaceController.pop(to: nowPlaying, animated: true, completion: nil)
        }

        /// A button image: the dark variant of an SF Symbol at 20 points; CarPlay recolors it.
        private static func symbol(_ name: String) -> UIImage {
            let configuration = UIImage.SymbolConfiguration(pointSize: 20)
                .applying(UITraitCollection(userInterfaceStyle: .dark).imageConfiguration)
            return UIImage(systemName: name, withConfiguration: configuration) ?? UIImage()
        }

        /// `text` drawn in white at 20 points, for the image rate button.
        private static func textImage(_ text: String) -> UIImage {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 20, weight: .semibold), .foregroundColor: UIColor.white,
            ]
            let string = NSAttributedString(string: text, attributes: attributes)
            let size = CPNowPlayingButtonMaximumImageSize
            return UIGraphicsImageRenderer(size: size).image { _ in
                let bounds = string.boundingRect(with: size, options: .usesLineFragmentOrigin, context: nil)
                string.draw(at: CGPoint(x: (size.width - bounds.width) / 2, y: (size.height - bounds.height) / 2))
            }
        }
    }
#endif
