import ABSAppModel
import ABSCore
import Foundation
import SwiftUI

#if os(iOS)
    import UIKit
#endif

/// When a reader keeps the screen awake (legacy `Reader.vue` `keepScreenAwake`, every reader
/// format): with the setting on, while the reader is shown and its scene is in front. On iOS that
/// is `.active`; a Mac window stays on screen while another app is frontmost (`.inactive`), so
/// there only `.background` lets the display sleep.
enum ReaderScreenAwake {
    static func isRequested(setting: Bool, isShown: Bool, phase: ScenePhase, platform: ReaderPlatform) -> Bool {
        guard setting, isShown else { return false }
        switch platform {
        case .iOS: return phase == .active
        case .macOS: return phase != .background
        }
    }
}

/// The readers holding the screen awake. Several can be shown at once (iPad scenes, Mac windows),
/// so the screen may sleep again only once the last lets go. A set rather than a count, so a
/// reader taking or releasing its hold twice doesn't unbalance it.
struct ScreenAwakeHolds {
    private(set) var holders: Set<UUID> = []

    var isHeld: Bool { !holders.isEmpty }

    /// Takes or releases `holder`'s hold; returns whether ``isHeld`` changed.
    mutating func set(_ holder: UUID, holding: Bool) -> Bool {
        let wasHeld = isHeld
        if holding {
            holders.insert(holder)
        } else {
            holders.remove(holder)
        }
        return wasHeld != isHeld
    }
}

/// Applies ``ScreenAwakeHolds`` to the system: the idle timer on iOS, a display-sleep activity on
/// macOS.
@MainActor
final class ReaderScreenAwakeController {
    static let shared = ReaderScreenAwakeController(apply: ReaderScreenAwakeController.applySystem)

    private var holds = ScreenAwakeHolds()
    private let apply: @MainActor (Bool) -> Void

    init(apply: @escaping @MainActor (Bool) -> Void) {
        self.apply = apply
    }

    func set(_ holder: UUID, holding: Bool) {
        guard holds.set(holder, holding: holding) else { return }
        apply(holds.isHeld)
    }

    #if os(macOS)
        private static var activity: (any NSObjectProtocol)?
    #endif

    private static func applySystem(_ keepsAwake: Bool) {
        #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = keepsAwake
        #elseif os(macOS)
            if keepsAwake {
                guard activity == nil else { return }
                activity = ProcessInfo.processInfo.beginActivity(
                    options: .idleDisplaySleepDisabled, reason: "Reader keep screen awake")
            } else if let current = activity {
                ProcessInfo.processInfo.endActivity(current)
                activity = nil
            }
        #endif
    }
}

/// Holds the screen awake while the reader it modifies is shown (``ReaderScreenAwake``).
struct ReaderKeepsScreenAwake: ViewModifier {
    @Environment(AppSettings.self) private var settings: AppSettings?
    @Environment(\.scenePhase) private var scenePhase
    @State private var holder = UUID()
    @State private var isShown = false

    func body(content: Content) -> some View {
        let isRequested = ReaderScreenAwake.isRequested(
            setting: settings?.readerSettings.keepScreenAwake ?? false, isShown: isShown, phase: scenePhase,
            platform: Self.platform)
        content
            .onAppear { isShown = true }
            // Released here as well: a view leaving the hierarchy may not see its last change.
            .onDisappear {
                isShown = false
                ReaderScreenAwakeController.shared.set(holder, holding: false)
            }
            .onChange(of: isRequested, initial: true) { _, isRequested in
                ReaderScreenAwakeController.shared.set(holder, holding: isRequested)
            }
    }

    private static var platform: ReaderPlatform {
        #if os(macOS)
            .macOS
        #else
            .iOS
        #endif
    }
}
