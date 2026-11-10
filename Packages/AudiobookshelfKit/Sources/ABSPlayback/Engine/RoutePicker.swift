import AVKit
import SwiftUI

/// The system AirPlay / output route picker (`AVRoutePickerView`) for SwiftUI.
///
/// It lives in ABSPlayback because ABSPlayback must not depend on ABSUI; ABSUI or the app can wrap
/// it in their own styling.
public struct RoutePicker {
    public init() {}

    @MainActor
    private func makePickerView() -> AVRoutePickerView {
        let view = AVRoutePickerView()
        #if os(iOS)
            view.prioritizesVideoDevices = false
        #endif
        return view
    }
}

#if os(iOS)
    extension RoutePicker: UIViewRepresentable {
        public func makeUIView(context: Context) -> AVRoutePickerView { makePickerView() }
        public func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
    }
#elseif os(macOS)
    extension RoutePicker: NSViewRepresentable {
        public func makeNSView(context: Context) -> AVRoutePickerView { makePickerView() }
        public func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
    }
#endif
