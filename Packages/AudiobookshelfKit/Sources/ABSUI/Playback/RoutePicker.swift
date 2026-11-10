import AVKit
import SwiftUI

/// The system AirPlay / output route picker (`AVRoutePickerView`) for SwiftUI.
///
/// On macOS the picker routes one player and does nothing without it, so pass the engine's
/// `routingPlayer`. iOS routes the whole audio session and ignores `player`.
public struct RoutePicker {
    let player: AVPlayer?

    public init(player: AVPlayer?) {
        self.player = player
    }

    @MainActor
    private func makePickerView() -> AVRoutePickerView {
        let view = AVRoutePickerView()
        #if os(iOS)
            view.prioritizesVideoDevices = false
        #endif
        update(view)
        return view
    }

    @MainActor
    private func update(_ view: AVRoutePickerView) {
        #if os(macOS)
            view.player = player
        #endif
    }
}

#if os(iOS)
    extension RoutePicker: UIViewRepresentable {
        public func makeUIView(context: Context) -> AVRoutePickerView { makePickerView() }
        public func updateUIView(_ uiView: AVRoutePickerView, context: Context) { update(uiView) }
    }
#elseif os(macOS)
    extension RoutePicker: NSViewRepresentable {
        public func makeNSView(context: Context) -> AVRoutePickerView { makePickerView() }
        public func updateNSView(_ nsView: AVRoutePickerView, context: Context) { update(nsView) }
    }
#endif
