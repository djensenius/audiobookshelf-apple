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
