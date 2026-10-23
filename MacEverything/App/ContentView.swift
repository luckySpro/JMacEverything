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

// MARK: - Translucent window background

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
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
    @AppStorage("showTypeFilters") private var showTypeFilters: Bool = true
    @FocusState private var isSearchFieldFocused: Bool

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
            PermissionView()
            searchBar
            if showTypeFilters && !viewModel.isContentSearch {
                filterBar
            }
            Divider().opacity(0.6)
            resultsArea
            Divider().opacity(0.6)
            footer
        }
        .frame(minWidth: 680, minHeight: 440)
        .background(VisualEffectBackground().ignoresSafeArea())
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

    // MARK: Search bar

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: viewModel.isContentSearch ? "doc.text.magnifyingglass" : "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)
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
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear (Esc)")
                .accessibilityIdentifier("clearButton")
            }
            optionsMenu
        }
        .padding(.horizontal, 18)
        .padding(.top, 34)      // room for the traffic lights (hidden title bar)
        .padding(.bottom, 14)
    }

    private var optionsMenu: some View {
        Menu {
            Toggle("Regex", isOn: $searchOptions.isRegex)
            Toggle("Case Sensitive", isOn: $searchOptions.isCaseSensitive)
            Toggle("Whole Word", isOn: $searchOptions.isWholeWord)
            Toggle("Match Whole Filename", isOn: $searchOptions.isMatchFilename)
            Divider()
            Toggle("Show Type Filters", isOn: $showTypeFilters)
            Divider()
            Button("Search Syntax Help") { SearchSyntaxHelpWindowController.shared.showWindow() }
            Button("Content Settings…") { ContentSettingsWindowController.shared.showWindow() }
            Button("Shortcut Settings…") { ShortcutSettingsWindowController.shared.showWindow() }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Search options")
    }

    // MARK: Filter chips + sort

    private var filterBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(TypeFilter.allCases) { f in
                        FilterChip(title: f.title, symbol: f.symbol,
                                   isOn: searchOptions.typeFilter == f) {
                            searchOptions.typeFilter = f
                            isSearchFieldFocused = true
                        }
                    }
                }
                .padding(.vertical, 1)
            }
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
                .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Sort loaded results")
        }
        .padding(.horizontal, 16)
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
                LazyVStack(spacing: 2) {
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
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
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
                    LazyVStack(spacing: 2) {
                        ForEach(Array(viewModel.contentResults.enumerated()), id: \.element.id) { idx, item in
                            ContentResultRow(item: item, keyword: viewModel.contentKeyword,
                                             isSelected: idx == selectedIndex,
                                             onSelect: { selectedIndex = idx })
                                .id(item.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
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
        HStack(spacing: 10) {
            statusIndicator
            Spacer()
            if resultCount > 0 {
                KeyHint(keys: "↩", label: "Open")
                KeyHint(keys: "⌘↩", label: "Reveal")
                KeyHint(keys: "⌘Y", label: "Quick Look")
                KeyHint(keys: "⌥⌘C", label: "Copy Path")
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
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
        .foregroundStyle(.secondary)
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
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
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
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.tertiary)
            }
            Text(title).font(.system(size: 15, weight: .semibold))
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
