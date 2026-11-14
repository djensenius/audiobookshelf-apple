import ABSAppModel
import Foundation
import SwiftUI
import Testing

@testable import Audiobookshelf

@Suite struct ReaderScreenAwakeTests {
    @Test(arguments: [ReaderPlatform.iOS, .macOS])
    func needsTheSettingAndAShownReader(platform: ReaderPlatform) {
        #expect(ReaderScreenAwake.isRequested(setting: true, isShown: true, phase: .active, platform: platform))
        #expect(!ReaderScreenAwake.isRequested(setting: false, isShown: true, phase: .active, platform: platform))
        #expect(!ReaderScreenAwake.isRequested(setting: true, isShown: false, phase: .active, platform: platform))
        #expect(!ReaderScreenAwake.isRequested(setting: true, isShown: true, phase: .background, platform: platform))
    }

    /// An inactive Mac window is still on screen; an inactive iOS scene is covered.
    @Test func inactiveKeepsAwakeOnlyOnMac() {
        #expect(!ReaderScreenAwake.isRequested(setting: true, isShown: true, phase: .inactive, platform: .iOS))
        #expect(ReaderScreenAwake.isRequested(setting: true, isShown: true, phase: .inactive, platform: .macOS))
    }

    @Test func holdsReleaseOnlyWithTheLastHolder() {
        var holds = ScreenAwakeHolds()
        let first = UUID()
        let second = UUID()
        let changes = [
            holds.set(first, holding: true), holds.set(second, holding: true), holds.set(first, holding: false),
        ]
        #expect(changes == [true, false, false])
        #expect(holds.isHeld)
        let lastRelease = holds.set(second, holding: false)
        #expect(lastRelease)
        #expect(!holds.isHeld)
    }

    @Test func repeatedTakesAndReleasesStayBalanced() {
        var holds = ScreenAwakeHolds()
        let reader = UUID()
        let changes = [
            holds.set(reader, holding: true), holds.set(reader, holding: true), holds.set(reader, holding: false),
            holds.set(reader, holding: false), holds.set(UUID(), holding: false),
        ]
        #expect(changes == [true, false, true, false, false])
        #expect(!holds.isHeld)
    }

    /// One window's reader closing leaves the screen awake for another still showing.
    @MainActor
    @Test func controllerAppliesOnlyChanges() {
        var applied: [Bool] = []
        let controller = ReaderScreenAwakeController { applied.append($0) }
        let first = UUID()
        let second = UUID()
        controller.set(first, holding: true)
        controller.set(second, holding: true)
        controller.set(first, holding: false)
        #expect(applied == [true])
        controller.set(second, holding: false)
        controller.set(second, holding: false)
        #expect(applied == [true, false])
    }
}
