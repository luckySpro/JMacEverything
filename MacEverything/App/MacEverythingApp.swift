import SwiftUI

@main
struct MacEverythingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var searchOptions = SearchOptions.shared
    @ObservedObject private var l10n = L10n.shared

    var body: some Scene {
        Window("JMacEverything", id: "main") {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 860, height: 620)
        .commands {
            CommandMenu(L("Search")) {
                Toggle(L("Regex"), isOn: $searchOptions.isRegex)
                    .keyboardShortcut("r", modifiers: [.command])
                Toggle(L("Case Sensitive"), isOn: $searchOptions.isCaseSensitive)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Toggle(L("Whole Word"), isOn: $searchOptions.isWholeWord)
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                Toggle(L("Match Filename"), isOn: $searchOptions.isMatchFilename)
                    .keyboardShortcut("f", modifiers: [.command, .shift])
            }

            CommandMenu(L("Filter")) {
                ForEach(Array(TypeFilter.allCases.enumerated()), id: \.element) { idx, f in
                    Button(f.title) { searchOptions.typeFilter = f }
                        .keyboardShortcut(KeyEquivalent(Character("\(idx + 1)")), modifiers: [.command])
                }
            }

            CommandMenu(L("Query")) {
                ForEach(QuickQuery.allCases) { q in
                    Button("\(L(q.title))   \(q.token)") {
                        NotificationCenter.default.post(name: .quickQuery, object: q.rawValue)
                    }
                    .keyboardShortcut(KeyEquivalent(q.key), modifiers: [.control, .option])
                }
            }

            CommandGroup(replacing: .help) {
                Button(L("Search Syntax Help")) {
                    SearchSyntaxHelpWindowController.shared.showWindow()
                }
                .keyboardShortcut("/", modifiers: [.command, .shift])
            }

            CommandGroup(after: .appSettings) {
                Button(L("Rebuild Index")) {
                    NotificationCenter.default.post(name: .rebuildIndex, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button(L("Shortcut Settings...")) {
                    ShortcutSettingsWindowController.shared.showWindow()
                }
                .keyboardShortcut(",", modifiers: [.command])

                Button(L("Content Settings...")) {
                    ContentSettingsWindowController.shared.showWindow()
                }

                Divider()

                Menu("MCP Integration") {
                    ForEach(MCPClient.allCases, id: \.self) { client in
                        Toggle(client.displayName, isOn: Binding(
                            get: { MCPConfigManager.isEnabled(for: client) },
                            set: { MCPConfigManager.setEnabled($0, for: client) }
                        ))
                    }
                }
            }
        }
    }
}

extension Notification.Name {
    static let rebuildIndex = Notification.Name("rebuildIndex")
}

class ContentSettingsWindowController {
    static let shared = ContentSettingsWindowController()
    private var window: NSWindow?

    func showWindow() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let settingsView = ContentSettingsView()
        let hostingController = NSHostingController(rootView: settingsView)
        let win = NSWindow(contentViewController: hostingController)
        win.title = L("Content Settings")
        win.styleMask = [.titled, .closable]
        win.center()
        win.makeKeyAndOrderFront(nil)
        window = win
    }
}

class ShortcutSettingsWindowController {
    static let shared = ShortcutSettingsWindowController()
    private var window: NSWindow?

    func showWindow() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let settingsView = ShortcutSettingsView()
        let hostingController = NSHostingController(rootView: settingsView)
        let win = NSWindow(contentViewController: hostingController)
        win.title = L("Shortcut Settings")
        win.styleMask = [.titled, .closable]
        win.center()
        win.makeKeyAndOrderFront(nil)
        window = win
    }
}

class SearchSyntaxHelpWindowController {
    static let shared = SearchSyntaxHelpWindowController()
    private var window: NSWindow?

    func showWindow() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let helpView = SearchSyntaxHelpView()
        let hostingController = NSHostingController(rootView: helpView)
        let win = NSWindow(contentViewController: hostingController)
        win.title = L("Search Syntax Help")
        win.styleMask = [.titled, .closable, .resizable]
        win.setContentSize(NSSize(width: 580, height: 720))
        win.minSize = NSSize(width: 450, height: 400)
        win.center()
        win.makeKeyAndOrderFront(nil)
        window = win
    }
}
