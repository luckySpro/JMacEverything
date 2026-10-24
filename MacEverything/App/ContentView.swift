import SwiftUI
import AppKit

// MARK: - Sort order (applied to the results already loaded on screen)

enum ResultSort: String, CaseIterable, Identifiable {
    case relevance, name, dateModified, size, kind
    var id: String { rawValue }
    var title: String {
        switch self {
        case .relevance: return "Relevance"
        case .name: return "Name"
        case .dateModified: return "Date Modified"
        case .size: return "Size"
        case .kind: return "Kind"
        }
    }
}

// MARK: - Palettes ("color cards")

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

struct Palette: Identifiable, Equatable {
    let id: String
    let name: String
    let isDark: Bool
    let paper: Color      // window background
    let surface: Color    // cards, search field, list
    let ink: Color        // primary text
    let muted: Color      // secondary text
    let rule: Color       // hairlines / borders
    let accent: Color     // selection, active tab, matches
    let header: Color     // top bar
    let headerInk: Color  // text on the top bar

    static let claude = Palette(id: "claude", name: "Claude Paper", isDark: false,
        paper: Color(hex: 0xF0EEE6), surface: Color(hex: 0xFAF9F5), ink: Color(hex: 0x1F1E1D),
        muted: Color(hex: 0x73726C), rule: Color(hex: 0xDAD7CC), accent: Color(hex: 0xC9512F),
        header: Color(hex: 0x1F1E1D), headerInk: Color(hex: 0xF0EEE6))

    static let night = Palette(id: "night", name: "Ink Night", isDark: true,
        paper: Color(hex: 0x1F1E1D), surface: Color(hex: 0x2A2927), ink: Color(hex: 0xECEAE3),
        muted: Color(hex: 0x9C9A92), rule: Color(hex: 0x3B3A37), accent: Color(hex: 0xD97757),
        header: Color(hex: 0x141413), headerInk: Color(hex: 0xECEAE3))

    static let sage = Palette(id: "sage", name: "Sage", isDark: false,
        paper: Color(hex: 0xEDEFE7), surface: Color(hex: 0xF8F9F4), ink: Color(hex: 0x1E2620),
        muted: Color(hex: 0x6B7468), rule: Color(hex: 0xD3D8CC), accent: Color(hex: 0x3F7D58),
        header: Color(hex: 0x1E2B22), headerInk: Color(hex: 0xEDEFE7))

    static let indigo = Palette(id: "indigo", name: "Indigo", isDark: false,
        paper: Color(hex: 0xECEEF3), surface: Color(hex: 0xF8F9FC), ink: Color(hex: 0x1C2030),
        muted: Color(hex: 0x6A7085), rule: Color(hex: 0xD2D6E2), accent: Color(hex: 0x3E5BA9),
        header: Color(hex: 0x1C2233), headerInk: Color(hex: 0xECEEF3))

    static let plum = Palette(id: "plum", name: "Plum", isDark: false,
        paper: Color(hex: 0xF3EDEE), surface: Color(hex: 0xFBF8F8), ink: Color(hex: 0x2A1E22),
        muted: Color(hex: 0x7A6A6F), rule: Color(hex: 0xE0D3D6), accent: Color(hex: 0xB4466A),
        header: Color(hex: 0x2A1C22), headerInk: Color(hex: 0xF3EDEE))

    static let all: [Palette] = [.claude, .night, .sage, .indigo, .plum]
    static func named(_ id: String) -> Palette { all.first { $0.id == id } ?? .claude }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue: Palette = .claude
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

// MARK: - Main view

struct ContentView: View {
    @StateObject private var viewModel = SearchViewModel()
    @ObservedObject private var searchOptions = SearchOptions.shared
    @State private var scrollViewID = 0
    @State private var selectedIndex: Int = 0
    @AppStorage("resultSort") private var sortRaw: String = ResultSort.relevance.rawValue
    @AppStorage("resultSortAscending") private var sortAscending: Bool = true
    @AppStorage("paletteID") private var paletteID: String = Palette.claude.id
    @FocusState private var isSearchFieldFocused: Bool

    private var palette: Palette { Palette.named(paletteID) }
    private var sort: ResultSort { ResultSort(rawValue: sortRaw) ?? .relevance }

    /// Results in display order (relevance = engine order).
    private var items: [FileItem] {
        let base = viewModel.displayItems
        guard sort != .relevance else { return base }
        let asc = sortAscending
        return base.sorted { a, b in
            let ordered: Bool
            switch sort {
            case .name: ordered = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .dateModified: ordered = a.modTime < b.modTime
            case .size: ordered = a.size < b.size
            case .kind: ordered = FileActions.kind(a) < FileActions.kind(b)
            case .relevance: ordered = false
            }
            return asc ? ordered : !ordered
        }
    }

    private var resultCount: Int {
        viewModel.isContentSearch ? viewModel.contentResults.count : items.count
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            PermissionView()
            searchBar
            metaBar
            DoubleRule(color: palette.ink)
                .padding(.horizontal, 24)
            resultsArea
            Rectangle().fill(palette.rule).frame(height: 1)
            footer
        }
        .frame(minWidth: 720, minHeight: 460)
        .foregroundStyle(palette.ink)
        .background(palette.paper.ignoresSafeArea())
        .tint(palette.accent)
        .environment(\.palette, palette)
        .preferredColorScheme(palette.isDark ? .dark : .light)
        .onChange(of: viewModel.searchText) { selectedIndex = 0 }
        .onChange(of: searchOptions.typeFilter) { selectedIndex = 0 }
        .onReceive(NotificationCenter.default.publisher(for: .rebuildIndex)) { _ in
            viewModel.rebuildIndex()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.onWindowFocusChanged(true)
            isSearchFieldFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            viewModel.onWindowFocusChanged(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification)) { _ in
            scrollViewID += 1
        }
    }

    // MARK: Header (dark bar with numbered tabs, like AutoCoder)

    private var headerBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "scope")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(palette.accent)
                Text("JMACEVERYTHING")
                    .font(.system(size: 13, weight: .heavy))
                    .tracking(2.2)
                Rectangle().fill(palette.headerInk.opacity(0.25)).frame(width: 1, height: 16)
                Text("Search")
                    .font(.system(size: 12))
                    .opacity(0.6)
            }
            .padding(.trailing, 22)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(TypeFilter.allCases.enumerated()), id: \.element) { idx, f in
                        HeaderTab(number: idx + 1, title: f.title,
                                  isOn: searchOptions.typeFilter == f) {
                            searchOptions.typeFilter = f
                            isSearchFieldFocused = true
                        }
                    }
                }
            }

            Spacer(minLength: 8)
            paletteMenu
            optionsMenu
        }
        .foregroundStyle(palette.headerInk)
        .padding(.leading, 84)      // clear the traffic lights
        .padding(.trailing, 14)
        .frame(height: 50)
        .background(palette.header.ignoresSafeArea(edges: .top))
    }

    private var paletteMenu: some View {
        Menu {
            Picker("Color Card", selection: $paletteID) {
                ForEach(Palette.all) { p in Text(p.name).tag(p.id) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "paintpalette")
                .font(.system(size: 14))
                .foregroundStyle(palette.headerInk.opacity(0.8))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 8)
        .help("Color card")
    }

    // MARK: Search field

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: viewModel.isContentSearch ? "doc.text.magnifyingglass" : "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(palette.muted)
                .frame(width: 22)
            HighlightedSearchField(
                text: $viewModel.searchText,
                placeholder: "Search files and folders…",
                ghostSuggestion: viewModel.ghostSuggestion,
                isFocused: $isSearchFieldFocused,
                onTab: {
                    if viewModel.ghostSuggestion != nil {
                        viewModel.acceptGhostSuggestion()
                        return true
                    }
                    return false
                },
                onKeyCommand: handleKey
            )
            .frame(height: 30)
            .onChange(of: viewModel.searchText) {
                viewModel.onSearchTextChanged()
            }
            SearchOptionBadges(options: searchOptions)
            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(palette.muted.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Clear (Esc)")
                .accessibilityIdentifier("clearButton")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.surface))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSearchFieldFocused ? palette.accent : palette.rule,
                              lineWidth: isSearchFieldFocused ? 1.5 : 1)
        )
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private var optionsMenu: some View {
        Menu {
            Toggle("Regex", isOn: $searchOptions.isRegex)
            Toggle("Case Sensitive", isOn: $searchOptions.isCaseSensitive)
            Toggle("Whole Word", isOn: $searchOptions.isWholeWord)
            Toggle("Match Whole Filename", isOn: $searchOptions.isMatchFilename)
            Divider()
            Button("Search Syntax Help") { SearchSyntaxHelpWindowController.shared.showWindow() }
            Button("Content Settings…") { ContentSettingsWindowController.shared.showWindow() }
            Button("Shortcut Settings…") { ShortcutSettingsWindowController.shared.showWindow() }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 14))
                .foregroundStyle(palette.headerInk.opacity(0.8))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Search options")
    }

    // MARK: Meta strip (status + sort)

    private var metaBar: some View {
        HStack(spacing: 8) {
            Text(viewModel.showingRecent ? "RECENT" : (viewModel.isContentSearch ? "CONTENT" : "RESULTS"))
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(palette.accent)
            statusIndicator
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(palette.muted)
            Spacer(minLength: 8)
            Menu {
                Picker("Sort By", selection: $sortRaw) {
                    ForEach(ResultSort.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Ascending", isOn: $sortAscending).disabled(sort == .relevance)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down")
                    Text(sort.title)
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(palette.ink)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Sort loaded results")
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 10)
    }

    // MARK: Results

    @ViewBuilder
    private var resultsArea: some View {
        if viewModel.isScanning {
            EmptyStateView(symbol: "internaldrive",
                           title: "Building the index…",
                           subtitle: "\(viewModel.scannedCount.formatted()) items scanned so far",
                           showsProgress: true)
        } else if viewModel.isContentSearch {
            contentResults
        } else if items.isEmpty && !viewModel.searchText.isEmpty && viewModel.scanComplete {
            EmptyStateView(symbol: "magnifyingglass",
                           title: "No results",
                           subtitle: searchOptions.typeFilter == .all
                               ? "Try fewer words, wildcards like *.pdf, or press ⇧⌘/ for syntax help."
                               : "Nothing matched in \(searchOptions.typeFilter.title). Try the All filter.")
                .accessibilityIdentifier("noResultsLabel")
        } else if items.isEmpty && viewModel.searchText.isEmpty {
            EmptyStateView(symbol: "sparkle.magnifyingglass",
                           title: "Find anything on your Mac",
                           subtitle: "Try  *.pdf   ext:swift todo   dm:today   size:>100mb   infile:password")
        } else {
            fileResults
        }
    }

    private var fileResults: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if viewModel.showingRecent && !items.isEmpty {
                        SectionHeader(symbol: "clock", title: "Recently Modified")
                    }
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        ResultRow(item: item, hints: viewModel.highlightHints,
                                  isSelected: idx == selectedIndex,
                                  onSelect: { selectedIndex = idx })
                            .id(item.id)
                    }
                    if viewModel.hasMoreResults {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading more…").font(.callout).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .onAppear { viewModel.loadMore() }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .id(scrollViewID)
            .accessibilityIdentifier("fileResultsList")
            .onChange(of: selectedIndex) {
                let list = items
                guard list.indices.contains(selectedIndex) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(list[selectedIndex].id)
                }
            }
        }
    }

    @ViewBuilder
    private var contentResults: some View {
        if viewModel.contentKeyword.isEmpty {
            EmptyStateView(symbol: "doc.text.magnifyingglass",
                           title: "Search inside files",
                           subtitle: "Type a word after infile: to search file contents.")
        } else if viewModel.contentResults.isEmpty && viewModel.scanComplete {
            if viewModel.isContentIndexing {
                EmptyStateView(symbol: "doc.text.magnifyingglass",
                               title: "Content index is building…",
                               subtitle: viewModel.contentIndexProgress.map { "Indexed \($0.indexed) of \($0.total) files" } ?? "",
                               showsProgress: true)
            } else {
                EmptyStateView(symbol: "doc.text.magnifyingglass",
                               title: "No content matches",
                               subtitle: viewModel.contentIndexedCount == 0
                                   ? "No files indexed yet. Choose extensions in Content Settings."
                                   : "Nothing contains “\(viewModel.contentKeyword)”.")
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(viewModel.contentResults.enumerated()), id: \.element.id) { idx, item in
                            ContentResultRow(item: item, keyword: viewModel.contentKeyword,
                                             isSelected: idx == selectedIndex,
                                             onSelect: { selectedIndex = idx })
                                .id(item.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .id(scrollViewID)
                .accessibilityIdentifier("contentResultsList")
                .onChange(of: selectedIndex) {
                    let list = viewModel.contentResults
                    guard list.indices.contains(selectedIndex) else { return }
                    proxy.scrollTo(list[selectedIndex].id)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            KeyHint(keys: "↑↓", label: "Select")
            KeyHint(keys: "↩", label: "Open")
            KeyHint(keys: "⌘↩", label: "Reveal")
            KeyHint(keys: "⌘Y", label: "Quick Look")
            KeyHint(keys: "⌥⌘C", label: "Copy Path")
            Spacer()
            Text("⌘1–9 filters · Esc hide")
        }
        .font(.system(size: 11))
        .foregroundStyle(palette.muted)
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(palette.surface.opacity(0.6))
        .accessibilityIdentifier("statusBar")
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if viewModel.isScanning {
            ProgressView().controlSize(.mini)
            Text("Indexing…")
        } else if viewModel.scanComplete {
            if viewModel.isSyncing {
                ProgressView().controlSize(.mini)
                Text("Syncing").foregroundStyle(.orange)
            } else if viewModel.isMonitoring {
                Circle().fill(.green).frame(width: 6, height: 6)
                    .help("Watching the file system for changes")
            }
            Text("\(Int(viewModel.totalRecords).formatted()) indexed")
                .accessibilityIdentifier("indexedCount")
            if viewModel.isContentIndexing, let p = viewModel.contentIndexProgress {
                Text("·")
                Text("Content \(p.indexed)/\(p.total)").foregroundStyle(.orange)
            }
            if viewModel.totalMatches > 0 {
                Text("·")
                Text(matchSummary).accessibilityIdentifier("matchCount")
                Text("·")
                Text(String(format: "%.1f ms", viewModel.queryTimeMs)).monospacedDigit()
            }
        }
    }

    private var matchSummary: String {
        if viewModel.isContentSearch {
            return "\(viewModel.contentResults.count.formatted()) content matches"
        }
        let total = viewModel.totalMatches.formatted()
        return items.count < viewModel.totalMatches
            ? "\(items.count.formatted()) of \(total) matches"
            : "\(total) matches"
    }

    // MARK: Keyboard

    private func handleKey(_ cmd: SearchKeyCommand) -> Bool {
        let count = resultCount
        switch cmd {
        case .escape:
            if !viewModel.searchText.isEmpty {
                viewModel.searchText = ""
            } else {
                NSApp.keyWindow?.orderOut(nil)
            }
            return true
        case .up:
            guard count > 0 else { return false }
            selectedIndex = max(0, selectedIndex - 1)
            return true
        case .down:
            guard count > 0 else { return false }
            selectedIndex = min(count - 1, selectedIndex + 1)
            if !viewModel.isContentSearch && viewModel.hasMoreResults && selectedIndex >= count - 5 {
                viewModel.loadMore()
            }
            return true
        case .pageUp:
            guard count > 0 else { return false }
            selectedIndex = max(0, selectedIndex - 10)
            return true
        case .pageDown:
            guard count > 0 else { return false }
            selectedIndex = min(count - 1, selectedIndex + 10)
            return true
        case .open, .reveal, .quickLook, .copyPath:
            guard let path = selectedPath else { return false }
            switch cmd {
            case .open:
                if !viewModel.isContentSearch, items.indices.contains(selectedIndex) {
                    FileActions.open(items[selectedIndex])
                } else {
                    FileActions.open(path)
                }
            case .reveal: FileActions.reveal(path)
            case .quickLook: FileActions.quickLook(path)
            case .copyPath: FileActions.copy(path)
            default: break
            }
            return true
        }
    }

    private var selectedPath: String? {
        if viewModel.isContentSearch {
            let list = viewModel.contentResults
            return list.indices.contains(selectedIndex) ? list[selectedIndex].filePath : nil
        }
        let list = items
        return list.indices.contains(selectedIndex) ? FileActions.fullPath(list[selectedIndex]) : nil
    }
}

// MARK: - Small components

private struct HeaderTab: View {
    let number: Int
    let title: String
    let isOn: Bool
    let action: () -> Void
    @Environment(\.palette) private var palette
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(String(format: "%02d", number))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(isOn ? palette.accent : palette.headerInk.opacity(0.45))
                Text(title)
                    .font(.system(size: 13, weight: isOn ? .semibold : .regular))
                    .foregroundStyle(palette.headerInk.opacity(isOn ? 1 : (hovered ? 0.85 : 0.65)))
            }
            .padding(.horizontal, 11)
            .frame(height: 50)
            .overlay(alignment: .bottom) {
                Rectangle().fill(isOn ? palette.accent : .clear).frame(height: 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// The heavy double rule under the title area in AutoCoder.
private struct DoubleRule: View {
    let color: Color
    var body: some View {
        VStack(spacing: 2) {
            Rectangle().fill(color).frame(height: 1.5)
            Rectangle().fill(color).frame(height: 1)
        }
    }
}

private struct FilterChip: View {
    let title: String
    let symbol: String
    let isOn: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4.5)
            .foregroundStyle(isOn ? Color.white : Color.primary.opacity(0.8))
            .background(
                Capsule().fill(isOn ? Color.accentColor
                               : Color.primary.opacity(hovered ? 0.10 : 0.06))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isOn)
    }
}

private struct SectionHeader: View {
    let symbol: String
    let title: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            Text(title.uppercased()).tracking(0.6)
            Spacer()
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(Color.secondary)
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }
}

private struct KeyHint: View {
    let keys: String
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1))
            Text(label)
        }
    }
}

private struct EmptyStateView: View {
    let symbol: String
    let title: String
    let subtitle: String
    var showsProgress: Bool = false

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            if showsProgress {
                ProgressView().controlSize(.regular)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Color.secondary.opacity(0.6))
            }
            Text(title).font(.system(size: 22, weight: .heavy))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
