#if canImport(CarPlay) && os(iOS)
    import CarPlay

    /// Scene delegate for the CarPlay audio app scene declared in `Info.plist`.
    final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
        private var interfaceController: CPInterfaceController?

        func templateApplicationScene(
            _ templateApplicationScene: CPTemplateApplicationScene,
            didConnect interfaceController: CPInterfaceController
        ) {
            self.interfaceController = interfaceController
            // CarPlay can launch the app without a window, so the session starts here too.
            // It is safe to call from every scene: only the first call runs.
            Task { await AppEnvironment.shared.lifecycle.start() }
            let item = CPListItem(text: "Audiobookshelf — coming soon", detailText: nil)
            let template = CPListTemplate(title: "Audiobookshelf", sections: [CPListSection(items: [item])])
            interfaceController.setRootTemplate(template, animated: false, completion: nil)
        }

        func templateApplicationScene(
            _ templateApplicationScene: CPTemplateApplicationScene,
            didDisconnectInterfaceController interfaceController: CPInterfaceController
        ) {
            self.interfaceController = nil
        }
    }
#endif
