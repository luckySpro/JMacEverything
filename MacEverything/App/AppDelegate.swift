import Cocoa
import ServiceManagement
import SwiftUI
import Carbon.HIToolbox

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var hotkeyManager: HotkeyManager?
    private var statusItem: NSStatusItem?
    private var launchAtLoginItem: NSMenuItem?
    private var mcpMenuItems: [MCPClient: NSMenuItem] = [:]
    private(set) var mainSearchWindow: NSWindow?
    private var keepResidentItem: NSMenuItem?
    private var panelPopover: NSPopover?
    /// Set only by the menu-bar "Quit" item; every other quit request just hides the app.
    private var userConfirmedQuit = false

    /// Stay in the menu bar when the window is closed, ⌘Q is pressed or the Dock's "Quit" is chosen.
    static var keepResident: Bool {
        get { UserDefaults.standard.object(forKey: "keepResidentInMenuBar") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "keepResidentInMenuBar") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MacSearchBridge.initializeLogger()

        let shouldMinimize = Self.shouldStartMinimized()

        // Delay by one frame to let SwiftUI create the window
        DispatchQueue.main.async { [weak self] in
            self?.mainSearchWindow = NSApp.windows.first { $0.title == "JMacEverything" }
            if shouldMinimize {
                self?.mainSearchWindow?.orderOut(nil)
                NSApp.hide(nil)
            }
        }
        hotkeyManager = HotkeyManager()
        hotkeyManager?.register()
        setupStatusBar()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.keepResident && !userConfirmedQuit && !Self.isSystemSessionEnding() {
            // ⌘Q / Dock "Quit": keep indexing in the background, just get out of the way.
            mainSearchWindow?.orderOut(nil)
            NSApp.hide(nil)
            return .terminateCancel
        }
        DispatchQueue.global(qos: .userInitiated).async {
            MacSearchBridge.shared().prepareForTermination()
            DispatchQueue.main.async {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    /// Clicking the Dock icon brings the search window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        mainSearchWindow?.makeKeyAndOrderFront(nil)
        return true
    }

    /// True when macOS asks us to quit for logout, restart or shutdown (the quit Apple event
    /// then carries a reason). Those must always be honoured.
    private static func isSystemSessionEnding() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == kCoreEventClass,
              event.eventID == kAEQuitApplication else { return false }
        let quitReasonKey: AEKeyword = 0x7768_793F // 'why?' (keyAEQuitReason)
        return event.attributeDescriptor(forKeyword: quitReasonKey) != nil
            || event.paramDescriptor(forKeyword: quitReasonKey) != nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Safety net: shutdown is idempotent (compare_exchange_strong guard)
        MacSearchBridge.shared().prepareForTermination()
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "JMacEverything")
            // Left click: show/hide the search window. Right click (or ⌃-click): the control panel.
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let wantsPanel = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if wantsPanel {
            togglePanel(from: sender)
        } else {
            panelPopover?.performClose(nil)
            toggleWindow()
        }
    }

    private func togglePanel(from button: NSStatusBarButton) {
        if let pop = panelPopover, pop.isShown {
            pop.performClose(nil)
            return
        }
        let actions = MenuBarPanel.Actions(
            toggleWindow: { [weak self] in self?.panelPopover?.performClose(nil); self?.toggleWindow() },
            rebuildIndex: { [weak self] in self?.panelPopover?.performClose(nil); self?.rebuildIndex() },
            contentSettings: { [weak self] in self?.panelPopover?.performClose(nil); self?.openContentSettings() },
            shortcutSettings: { [weak self] in self?.panelPopover?.performClose(nil); self?.openShortcutSettings() },
            syntaxHelp: { [weak self] in self?.panelPopover?.performClose(nil); self?.openSearchSyntaxHelp() },
            quit: { [weak self] in self?.panelPopover?.performClose(nil); self?.quitApp() },
            isWindowVisible: { [weak self] in self?.mainSearchWindow?.isVisible ?? false }
        )
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.contentViewController = NSHostingController(rootView: MenuBarPanel(actions: actions))
        panelPopover = pop
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        pop.contentViewController?.view.window?.makeKey()
    }

    // MARK: - Menu Actions

    @objc private func toggleWindow() {
        if let window = mainSearchWindow, window.isVisible {
            NSApp.hide(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            mainSearchWindow?.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func rebuildIndex() {
        NSApp.activate(ignoringOtherApps: true)
        mainSearchWindow?.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .rebuildIndex, object: nil)
    }

    @objc private func openShortcutSettings() {
        NSApp.activate(ignoringOtherApps: true)
        ShortcutSettingsWindowController.shared.showWindow()
    }

    @objc private func openContentSettings() {
        NSApp.activate(ignoringOtherApps: true)
        ContentSettingsWindowController.shared.showWindow()
    }

    @objc private func openSearchSyntaxHelp() {
        NSApp.activate(ignoringOtherApps: true)
        SearchSyntaxHelpWindowController.shared.showWindow()
    }

    @objc private func toggleMCPClientUnused(_ sender: NSMenuItem) {
        guard let client = sender.representedObject as? MCPClient else { return }
        let currentlyEnabled = MCPConfigManager.isEnabled(for: client)
        MCPConfigManager.setEnabled(!currentlyEnabled, for: client)
        sender.state = !currentlyEnabled ? .on : .off
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            AppLogger.error("App", "Failed to toggle launch at login: \(error)")
        }
    }

    @objc private func quitApp() {
        userConfirmedQuit = true
        NSApp.terminate(nil)
    }

    // MARK: - Launch Mode Detection

    private static func shouldStartMinimized() -> Bool {
        if CommandLine.arguments.contains("--minimized") {
            return true
        }
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == kAEOpenApplication,
           event.paramDescriptor(forKeyword: keyAEPropData)?.stringValue == "com.apple.loginwindow" {
            return true
        }
        return false
    }
}

// MARK: - Menu-bar control panel (Claude Paper style, shown on right click)

struct MenuBarPanel: View {
    struct Actions {
        let toggleWindow: () -> Void
        let rebuildIndex: () -> Void
        let contentSettings: () -> Void
        let shortcutSettings: () -> Void
        let syntaxHelp: () -> Void
        let quit: () -> Void
        let isWindowVisible: () -> Bool
    }

    let actions: Actions
    @AppStorage("paletteID") private var paletteID: String = Palette.claude.id
    @ObservedObject private var l10n = L10n.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var keepResident = AppDelegate.keepResident
    @State private var mcp: [MCPClient: Bool] = [:]
    @State private var indexed: UInt32 = 0
    @State private var memory: UInt64 = 0
    @State private var monitoring = false

    private var palette: Palette { Palette.named(paletteID) }

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 14) {
                group(nil) {
                    PanelRow(symbol: actions.isWindowVisible() ? "eye.slash" : "macwindow",
                             title: actions.isWindowVisible() ? L("Hide JMacEverything") : L("Show JMacEverything"),
                             hint: hotkeyText, action: actions.toggleWindow)
                    PanelRow(symbol: "arrow.clockwise", title: L("Rebuild Index"), action: actions.rebuildIndex)
                    PanelRow(symbol: "doc.text.magnifyingglass", title: L("Content Settings…"), action: actions.contentSettings)
                    PanelRow(symbol: "keyboard", title: L("Shortcut Settings…"), action: actions.shortcutSettings)
                    PanelRow(symbol: "questionmark.circle", title: L("Search Syntax Help"), hint: "⇧⌘/", action: actions.syntaxHelp)
                }
                group(L("Startup")) {
                    PanelToggle(title: L("Launch at Login"), isOn: Binding(
                        get: { launchAtLogin },
                        set: { on in
                            do {
                                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            } catch { NSSound.beep() }
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }))
                    PanelToggle(title: L("Keep Running in Menu Bar"), isOn: Binding(
                        get: { keepResident },
                        set: { keepResident = $0; AppDelegate.keepResident = $0 }))
                }
                group(L("MCP Integration")) {
                    ForEach(MCPClient.allCases, id: \.self) { client in
                        PanelToggle(title: client.displayName, isOn: Binding(
                            get: { mcp[client] ?? false },
                            set: { MCPConfigManager.setEnabled($0, for: client); mcp[client] = MCPConfigManager.isEnabled(for: client) }))
                    }
                }
                group(L("Appearance")) {
                    HStack(spacing: 8) {
                        ForEach(Palette.all) { p in
                            Button { paletteID = p.id } label: {
                                ZStack {
                                    Circle().fill(p.paper)
                                    Circle().fill(p.accent).frame(width: 10, height: 10)
                                }
                                .frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(p.id == paletteID ? palette.accent : palette.rule,
                                                               lineWidth: p.id == paletteID ? 2 : 1))
                            }
                            .buttonStyle(.plain)
                            .help(L(p.name))
                        }
                        Spacer()
                        Menu {
                            Picker(L("Language"), selection: $l10n.language) {
                                ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                            }
                            .pickerStyle(.inline)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "globe")
                                Text(l10n.language == .system ? L("Follow System") : l10n.language.displayName)
                            }
                            .font(.system(size: 11.5))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                    .padding(.horizontal, 10)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)

            Rectangle().fill(palette.rule).frame(height: 1)
            HStack {
                Button(action: actions.quit) {
                    HStack(spacing: 6) {
                        Image(systemName: "power")
                        Text(L("Quit JMacEverything"))
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(palette.accent)
                }
                .buttonStyle(.plain)
                Spacer()
                Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(palette.muted)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .frame(width: 300)
        .background(palette.paper)
        .foregroundStyle(palette.ink)
        .environment(\.palette, palette)
        .preferredColorScheme(palette.isDark ? .dark : .light)
        .id(l10n.resolved)
        .onAppear(perform: refresh)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "scope")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(palette.accent)
                Text("JMACEVERYTHING")
                    .font(.system(size: 11.5, weight: .heavy))
                    .tracking(1.6)
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(monitoring ? Color.green : palette.headerInk.opacity(0.4)).frame(width: 6, height: 6)
                    Text(monitoring ? L("Live") : L("Scanning"))
                        .font(.system(size: 10.5, weight: .medium))
                }
                .opacity(0.85)
            }
            HStack(spacing: 14) {
                stat(Int(indexed).formatted(), L("files"))
                stat(ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory), L("Memory"))
            }
        }
        .foregroundStyle(palette.headerInk)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(palette.header)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(.system(size: 15, weight: .bold, design: .monospaced))
            Text(label).font(.system(size: 10.5)).opacity(0.6)
        }
    }

    @ViewBuilder
    private func group<Content: View>(_ title: String?, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(palette.muted)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 3)
            }
            content()
        }
    }

    private var hotkeyText: String {
        let d = UserDefaults.standard
        if d.object(forKey: "hotkeyKeyCode") != nil {
            return describeShortcut(keyCode: UInt32(d.integer(forKey: "hotkeyKeyCode")),
                                    modifiers: UInt32(d.integer(forKey: "hotkeyModifiers")))
        }
        return describeShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
    }

    private func refresh() {
        let bridge = MacSearchBridge.shared()
        indexed = bridge.liveRecordCount()
        monitoring = bridge.isMonitoring
        memory = MemoryStats.footprintBytes()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        keepResident = AppDelegate.keepResident
        for c in MCPClient.allCases { mcp[c] = MCPConfigManager.isEnabled(for: c) }
    }
}

private struct PanelRow: View {
    let symbol: String
    let title: String
    var hint: String? = nil
    let action: () -> Void
    @Environment(\.palette) private var palette
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .frame(width: 18)
                    .foregroundStyle(hovered ? palette.accent : palette.muted)
                Text(title).font(.system(size: 13))
                Spacer()
                if let hint {
                    Text(hint)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(palette.muted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovered ? palette.surface : Color.clear))
            .overlay(alignment: .leading) {
                Rectangle().fill(hovered ? palette.accent : Color.clear).frame(width: 2.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct PanelToggle: View {
    let title: String
    @Binding var isOn: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title).font(.system(size: 13))
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(palette.accent)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }
}
