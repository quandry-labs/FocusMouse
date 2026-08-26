import AppKit
import Foundation
import Testing
@testable import FocusMouse

@MainActor
@Suite("Command shortcut guide", .serialized)
struct ShortcutGuideControllerTests {
    @Test("guide panel is click-through and non-activating")
    func panelIsClickThrough() {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = ShortcutGuideController(settings: settings)
        let panel = controller.makePanel()

        #expect(panel.ignoresMouseEvents)
        #expect(!panel.acceptsMouseMovedEvents)
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    @Test("holding only Command shows the guide and releasing it hides the guide")
    func commandHoldShowsAndReleaseHides() async throws {
        let (settings, defaults, suiteName) = makeSettings()
        let controller = ShortcutGuideController(
            settings: settings,
            showDelay: .milliseconds(1)
        )
        defer {
            controller.stop()
            defaults.removePersistentDomain(forName: suiteName)
        }

        controller.start()
        controller.handleModifierFlags(.command)
        try await waitUntil { controller.isVisible }

        controller.handleModifierFlags([])
        #expect(!controller.isVisible)
    }

    @Test("other shortcut modifiers suppress the guide")
    func otherModifiersSuppressGuide() async throws {
        let (settings, defaults, suiteName) = makeSettings()
        let controller = ShortcutGuideController(
            settings: settings,
            showDelay: .milliseconds(1)
        )
        defer {
            controller.stop()
            defaults.removePersistentDomain(forName: suiteName)
        }

        controller.start()
        controller.handleModifierFlags([.command, .option])
        try await Task.sleep(for: .milliseconds(20))

        #expect(!controller.isVisible)
    }

    @Test("disabling the feature removes monitors and dismisses the guide")
    func disablingStopsGuide() async throws {
        let (settings, defaults, suiteName) = makeSettings()
        let controller = ShortcutGuideController(
            settings: settings,
            showDelay: .milliseconds(1)
        )
        defer {
            controller.stop()
            defaults.removePersistentDomain(forName: suiteName)
        }

        controller.start()
        #expect(controller.isMonitoring)
        controller.handleModifierFlags(.command)
        try await waitUntil { controller.isVisible }

        settings.isShortcutGuideEnabled = false
        controller.applySettings()

        #expect(!controller.isMonitoring)
        #expect(!controller.isVisible)
    }

    @Test("system shortcut catalog has stable unique entries")
    func catalogHasUniqueEntries() {
        let shortcuts = SystemShortcutCatalog.groups.flatMap(\.shortcuts)

        #expect(SystemShortcutCatalog.groups.count == 15)
        #expect(shortcuts.count >= 200)
        #expect(Set(shortcuts.map(\.id)).count == shortcuts.count)
        #expect(shortcuts.allSatisfy { !$0.title.isEmpty && !$0.keys.isEmpty })
    }

    @Test("pagination preserves every shortcut")
    func paginationPreservesShortcuts() {
        let sourceGroups = [
            ShortcutGuideGroup(
                id: "first",
                title: "FIRST",
                symbol: "1.circle",
                shortcuts: (0..<19).map {
                    ShortcutGuideItem("first-\($0)", "First \($0)", keys: ["⌘", "\($0)"])
                }
            ),
            ShortcutGuideGroup(
                id: "second",
                title: "SECOND",
                symbol: "2.circle",
                shortcuts: (0..<9).map {
                    ShortcutGuideItem("second-\($0)", "Second \($0)", keys: ["⌥", "\($0)"])
                }
            ),
        ]

        let pages = ShortcutGuidePaginator.pages(
            sourceID: "test",
            eyebrow: "TEST",
            title: "All shortcuts",
            sourceDetail: "28 shortcuts",
            groups: sourceGroups
        )
        let output = pages.flatMap(\.groups).flatMap(\.shortcuts)

        #expect(output.map(\.id) == sourceGroups.flatMap(\.shortcuts).map(\.id))
        #expect(pages.allSatisfy { $0.groups.count <= ShortcutGuidePaginator.groupsPerPage })
        #expect(pages.flatMap(\.groups).allSatisfy {
            $0.shortcuts.count <= ShortcutGuidePaginator.shortcutsPerGroup
        })
    }

    @Test("native menu key equivalents preserve modifiers and special keys")
    func nativeKeyFormatting() {
        #expect(
            NativeShortcutKeyFormatter.keyCaps(
                commandCharacter: "k",
                virtualKey: nil,
                glyph: nil,
                modifiers: 0b011
            ) == ["⌥", "⇧", "⌘", "K"]
        )
        #expect(
            NativeShortcutKeyFormatter.keyCaps(
                commandCharacter: nil,
                virtualKey: nil,
                glyph: 0x64,
                modifiers: 0b1000
            ) == ["←"]
        )
        #expect(
            NativeShortcutKeyFormatter.keyCaps(
                commandCharacter: nil,
                virtualKey: 0x60,
                glyph: nil,
                modifiers: 0b100
            ) == ["⌃", "⌘", "F5"]
        )
        #expect(
            NativeShortcutKeyFormatter.keyCaps(
                commandCharacter: nil,
                virtualKey: nil,
                glyph: nil,
                modifiers: 0
            ) == nil
        )
    }

    @Test("frontmost app shortcuts precede system pages")
    func nativePagesComeFirst() {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let nativeGroup = ShortcutGuideGroup(
            id: "file",
            title: "FILE",
            symbol: "doc",
            shortcuts: [ShortcutGuideItem("new", "New", keys: ["⌘", "N"])]
        )
        let provider = StubNativeShortcutProvider(
            snapshot: NativeShortcutSnapshot(
                applicationName: "Test App",
                bundleIdentifier: "com.example.test",
                groups: [nativeGroup]
            )
        )
        let controller = ShortcutGuideController(
            settings: settings,
            nativeShortcutProvider: provider
        )

        controller.reloadShortcutPages()

        #expect(controller.pages.first?.eyebrow == "TEST APP")
        #expect(controller.pages.first?.groups.flatMap(\.shortcuts).map(\.id) == ["new"])
        #expect(controller.pages.contains { $0.eyebrow == "MACOS" })
    }

    @Test("page navigation wraps in both directions")
    func pageNavigationWraps() {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = ShortcutGuideController(
            settings: settings,
            nativeShortcutProvider: StubNativeShortcutProvider(snapshot: nil)
        )

        #expect(controller.pages.count > 1)
        controller.movePage(.previous)
        #expect(controller.currentPageIndex == controller.pages.count - 1)
        controller.movePage(.next)
        #expect(controller.currentPageIndex == 0)
    }

    private func makeSettings() -> (AppSettings, UserDefaults, String) {
        let suiteName = "test-shortcut-guide-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (AppSettings(defaults: defaults), defaults, suiteName)
    }

    private func waitUntil(
        timeout: Duration = .milliseconds(500),
        condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}

@MainActor
private struct StubNativeShortcutProvider: NativeShortcutProviding {
    let snapshot: NativeShortcutSnapshot?

    func frontmostApplicationShortcuts() -> NativeShortcutSnapshot? {
        snapshot
    }
}
