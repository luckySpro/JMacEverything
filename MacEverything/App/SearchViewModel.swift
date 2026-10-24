import Foundation
import Combine
import Darwin

/// Process memory as Activity Monitor reports it ("Memory" column = phys_footprint).
enum MemoryStats {
    static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// Return memory freed after big one-off work (initial scan, index load, compaction)
    /// to the system. macOS malloc otherwise keeps those pages, inflating the footprint.
    static func releaseFreedMemory(force: Bool = true) {
        let now = Date()
        lock.lock()
        let due = force || now.timeIntervalSince(lastRelief) > 60
        if due { lastRelief = now }
        lock.unlock()
        guard due else { return }
        DispatchQueue.global(qos: .utility).async {
            _ = malloc_zone_pressure_relief(nil, 0)
        }
    }
    private static let lock = NSLock()
    private static var lastRelief = Date.distantPast
}

struct FileItem: Identifiable {
    let id: String      // path-based stable ID
    let index: UInt32   // engine index for record lookup
    let name: String
    let path: String
    let type: UInt8
    let size: UInt64
    let modTime: time_t
}

struct ContentFileItem: Identifiable {
    let id: String      // stable ID: filePath + ":" + line
    let fileName: String
    let filePath: String
    let snippet: String // the matching line (trimmed)
    let matchOffset: UInt32
    let fileType: UInt8
    var line: Int = 0   // 1-based line number, 0 if unknown
}

// MARK: - Content query (grep-style search inside files)

/// Parsed form of a query that searches inside files, e.g.
/// `ext:swift path:App grep:TODO`, `infile:"open file"`, `ext:rs inre:fn\s+\w+`.
struct ContentQuery: Equatable {
    var pattern: String
    var isRegex: Bool
    /// The rest of the query, used as a filename/path filter.
    var nameQuery: String

    static let literalPrefixes = ["infile:", "grep:", "content:"]
    static let regexPrefixes = ["inre:", "grepre:"]

    static func parse(_ text: String) -> ContentQuery? {
        var tokens: [String] = []
        var current = ""
        var inQuote = false
        for ch in text {
            if ch == "\"" { inQuote.toggle(); current.append(ch); continue }
            if ch == " " && !inQuote {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }

        var pattern: String?
        var regex = false
        var rest: [String] = []
        for t in tokens {
            let lower = t.lowercased()
            if pattern == nil, let p = (literalPrefixes + regexPrefixes).first(where: { lower.hasPrefix($0) }) {
                var value = String(t.dropFirst(p.count))
                if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                } else if value.hasPrefix("\"") {
                    value = String(value.dropFirst())
                }
                pattern = value
                regex = regexPrefixes.contains(p)
            } else {
                rest.append(t)
            }
        }
        guard let pattern else { return nil }
        return ContentQuery(pattern: pattern, isRegex: regex, nameQuery: rest.joined(separator: " "))
    }
}

/// Thread-safe cancellation flag for a running content scan.
final class ContentCancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// Reads candidate files and returns every matching line (like ripgrep, smart-case).
enum ContentLineSearch {
    static let maxFileBytes = 4 * 1024 * 1024
    static let maxLinesPerFile = 20
    static let maxTotalLines = 1000
    static let maxNamedFilesToScan = 3000

    enum Outcome {
        case results([ContentFileItem], scannedFiles: Int)
        case needsFilter        // regex without a name filter
        case badRegex(String)
    }

    static func run(_ q: ContentQuery, nameQuery builtNameQuery: String,
                    bridge: MacSearchBridge, isCancelled: @escaping () -> Bool) -> Outcome {
        let caseSensitive = q.pattern.contains { $0.isUppercase }
        var regex: NSRegularExpression?
        if q.isRegex {
            do {
                regex = try NSRegularExpression(pattern: q.pattern,
                                                options: caseSensitive ? [] : [.caseInsensitive])
            } catch {
                return .badRegex(error.localizedDescription)
            }
            if q.nameQuery.isEmpty { return .needsFilter }
        }

        // 1. Candidates from the trigram content index (literal patterns only)
        var indexed: [String] = []
        if !q.isRegex && q.pattern.count >= 3 {
            var seen = Set<String>()
            for r in bridge.queryContent(q.pattern, maxResults: 3000) where seen.insert(r.filePath).inserted {
                indexed.append(r.filePath)
            }
        }

        // 2. Narrow / extend with the name filter
        var candidates: [String]
        if !q.nameQuery.isEmpty {
            let named = bridge.queryResults(builtNameQuery, maxResults: 20000, sessionId: 7)
                .filter { $0.type == 1 }
                .map { "\($0.path)/\($0.name)" }
            let namedSet = Set(named)
            let indexedSet = Set(indexed)
            candidates = indexed.filter { namedSet.contains($0) }
            // Files the user named are read directly even if their type isn't content-indexed.
            candidates += named.lazy.filter { !indexedSet.contains($0) }.prefix(maxNamedFilesToScan)
        } else {
            candidates = indexed
        }
        if isCancelled() { return .results([], scannedFiles: 0) }

        // 3. Read each file fresh and collect matching lines (parallel)
        var perFile = [[ContentFileItem]](repeating: [], count: candidates.count)
        let lock = NSLock()
        var total = 0
        DispatchQueue.concurrentPerform(iterations: candidates.count) { i in
            lock.lock(); let full = total >= maxTotalLines; lock.unlock()
            if full || isCancelled() { return }
            let hits = scanFile(candidates[i], pattern: q.pattern, regex: regex, caseSensitive: caseSensitive)
            if hits.isEmpty { return }
            lock.lock(); perFile[i] = hits; total += hits.count; lock.unlock()
        }
        let items = Array(perFile.joined().prefix(maxTotalLines))
        return .results(items, scannedFiles: candidates.count)
    }

    static func scanFile(_ path: String, pattern: String, regex: NSRegularExpression?,
                         caseSensitive: Bool) -> [ContentFileItem] {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber, size.intValue <= maxFileBytes,
              let data = FileManager.default.contents(atPath: path) else { return [] }
        // Skip binaries: a NUL byte in the first 8 KB
        if data.prefix(8192).contains(0) { return [] }
        let text = String(decoding: data, as: UTF8.self)
        let name = (path as NSString).lastPathComponent
        var out: [ContentFileItem] = []
        var lineNo = 0
        text.enumerateLines { line, stop in
            lineNo += 1
            let matched: Bool
            if let regex {
                matched = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
            } else if caseSensitive {
                matched = line.contains(pattern)
            } else {
                matched = line.range(of: pattern, options: .caseInsensitive) != nil
            }
            if matched {
                out.append(ContentFileItem(
                    id: "\(path):\(lineNo)", fileName: name, filePath: path,
                    snippet: clip(line, around: pattern), matchOffset: UInt32(clamping: lineNo),
                    fileType: 1, line: lineNo))
                if out.count >= maxLinesPerFile { stop = true }
            }
        }
        return out
    }

    /// Trim indentation and keep long lines readable around the match.
    static func clip(_ line: String, around pattern: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 220 else { return trimmed }
        if let r = trimmed.range(of: pattern, options: .caseInsensitive) {
            let start = trimmed.index(r.lowerBound, offsetBy: -80, limitedBy: trimmed.startIndex) ?? trimmed.startIndex
            let end = trimmed.index(start, offsetBy: 220, limitedBy: trimmed.endIndex) ?? trimmed.endIndex
            let head = start > trimmed.startIndex ? "…" : ""
            let tail = end < trimmed.endIndex ? "…" : ""
            return head + String(trimmed[start..<end]) + tail
        }
        return String(trimmed.prefix(220)) + "…"
    }
}

@MainActor
class SearchViewModel: ObservableObject {
    @Published var searchText: String = ""
    @Published var displayItems: [FileItem] = []
    @Published var totalMatches: Int = 0
    @Published var isScanning: Bool = false
    @Published var scanComplete: Bool = false
    @Published var totalRecords: UInt32 = 0
    @Published var queryTimeMs: Double = 0
    @Published var isMonitoring: Bool = false
    @Published var scannedCount: UInt64 = 0
    var isLoadingMore: Bool = false
    @Published var showingRecent: Bool = false
    @Published var isContentSearch: Bool = false
    @Published var contentResults: [ContentFileItem] = []
    @Published var isContentIndexing: Bool = false
    @Published var contentIndexProgress: (indexed: UInt32, total: UInt32)?
    @Published var contentIndexedCount: UInt32 = 0
    @Published var isSyncing: Bool = false
    @Published var ghostSuggestion: String? = nil
    /// Set when the current content query is a regex, needs a filter, or is invalid.
    @Published var contentIsRegex: Bool = false
    @Published var contentNotice: String? = nil
    @Published var contentScannedFiles: Int = 0
    /// Current process footprint in bytes (refreshed every few seconds).
    @Published var memoryFootprint: UInt64 = 0
    private var memoryTimer: Timer?

    /// Structured highlight hints extracted from the C++ query AST.
    /// Replaces the old keyword-based approach with field-aware, mode-aware hints.
    var highlightHints: [HighlightHint] {
        let query = searchOptions.buildQuery(searchText)
        guard !query.isEmpty else { return [] }
        return bridge.parseHighlightHints(query).map { HighlightHint(from: $0) }
    }

    private let bridge = MacSearchBridge.shared()
    private let historyStore = SearchHistoryStore()
    private var contentToken: ContentCancelToken?
    @Published private(set) var historyVersion = 0

    func recentSearches(limit: Int = 8) -> [String] { historyStore.recent(limit: limit) }
    func removeRecentSearch(_ q: String) { historyStore.remove(q); historyVersion += 1 }
    func clearRecentSearches() { historyStore.clear(); historyVersion += 1 }
    private let searchOptions = SearchOptions.shared
    private var searchTask: Task<Void, Never>?
    private var recentTask: Task<Void, Never>?
    private var settledTask: Task<Void, Never>?
    private var optionsSink: AnyCancellable?
    private var cachedResults: [MEFileResult] = []
    private var loadedCount: Int = 0
    private var searchGeneration: UInt64 = 0
    private static let guiSessionId: UInt64 = 1

    private static let pageSize: Int = 100
    private static let maxResults: UInt32 = 10000
    private static let indexChangeThrottleNs: UInt64 = 5_000_000_000 // 5 seconds

    private var indexChangeTask: Task<Void, Never>?
    let refreshThrottle = IndexRefreshThrottle()

    static var cacheDir: String {
        let base = NSSearchPathForDirectoriesInDomains(
            .cachesDirectory, .userDomainMask, true
        ).first ?? NSTemporaryDirectory()
        let appCache = (base as NSString).appendingPathComponent("com.maceverything.app")
        try? FileManager.default.createDirectory(
            atPath: appCache, withIntermediateDirectories: true
        )
        return appCache
    }

    static var cachePath: String {
        return (cacheDir as NSString).appendingPathComponent("index.bin")
    }

    static var walPath: String {
        return (cacheDir as NSString).appendingPathComponent("index.wal")
    }

    static var pagesPath: String {
        return (cacheDir as NSString).appendingPathComponent("index.pages")
    }

    static var ptablePath: String {
        return (cacheDir as NSString).appendingPathComponent("index.ptable")
    }

    init() {
        optionsSink = searchOptions.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onSearchOptionsChanged()
            }
        }
        startIncremental()
        memoryFootprint = MemoryStats.footprintBytes()
        memoryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.memoryFootprint = MemoryStats.footprintBytes() }
        }
    }

    private func onSearchOptionsChanged() {
        guard scanComplete, !searchText.isEmpty, !isContentSearch else { return }
        searchTask?.cancel()
        searchGeneration &+= 1
        bridge.cancelSession(Self.guiSessionId)
        performSearch(searchText)
    }

    func startIncremental() {
        isScanning = true
        scannedCount = 0

        bridge.onScanProgress = { [weak self] fileCount, dirCount in
            Task { @MainActor in
                self?.scannedCount = fileCount + dirCount
            }
        }

        bridge.onContentIndexProgress = { [weak self] indexed, total in
            Task { @MainActor in
                guard let self = self else { return }
                self.isContentIndexing = true
                self.contentIndexProgress = (indexed, total)
            }
        }

        bridge.onContentIndexComplete = { [weak self] totalIndexed in
            Task { @MainActor in
                guard let self = self else { return }
                self.isContentIndexing = false
                self.contentIndexProgress = nil
                self.contentIndexedCount = totalIndexed
                MemoryStats.releaseFreedMemory()
                // Auto-refresh content search results after indexing completes
                if self.isContentSearch && !self.contentKeyword.isEmpty {
                    self.performContentSearch(self.searchText)
                }
            }
        }

        // Set up FSEvents change callback before starting
        bridge.onIndexChanged = { [weak self] in
            Task { @MainActor in
                self?.onIndexChanged()
            }
        }

        bridge.startIncremental(from: "/",
                                cachePath: Self.cachePath,
                                walPath: Self.walPath) { [weak self] count, didFullScan in
            Task { @MainActor in
                guard let self = self else { return }
                self.totalRecords = count
                self.isScanning = false
                self.scanComplete = true
                MemoryStats.releaseFreedMemory()
                self.isMonitoring = self.bridge.isMonitoring
                self.isSyncing = self.bridge.isSyncing

                if !self.searchText.isEmpty {
                    self.performSearch(self.searchText)
                } else {
                    self.loadRecentFiles()
                }
            }
        }
    }

    func rebuildIndex() {
        guard !isScanning else { return }
        searchTask?.cancel()
        recentTask?.cancel()
        indexChangeTask?.cancel()
        searchGeneration &+= 1
        scanComplete = false
        displayItems = []
        totalMatches = 0
        queryTimeMs = 0
        contentResults = []
        isContentSearch = false
        contentKeyword = ""

        // Delete cached index files so startIncremental does a full scan
        try? FileManager.default.removeItem(atPath: Self.cachePath)
        try? FileManager.default.removeItem(atPath: Self.walPath)
        try? FileManager.default.removeItem(atPath: Self.pagesPath)
        try? FileManager.default.removeItem(atPath: Self.ptablePath)

        startIncremental()
    }

    func onSearchTextChanged() {
        searchTask?.cancel()
        contentToken?.cancel()
        recentTask?.cancel()
        searchGeneration &+= 1
        isLoadingMore = false
        let text = searchText

        if text.isEmpty {
            totalMatches = 0
            queryTimeMs = 0
            cachedResults = []
            loadedCount = 0
            isContentSearch = false
            contentResults = []
            contentKeyword = "" // H-9: reset cached keyword
            ghostSuggestion = nil
            settledTask?.cancel()
            // Cancel any in-flight queries for this GUI session
            bridge.cancelSession(Self.guiSessionId)
            if scanComplete {
                // Slight delay so the stale query's dispatch_apply threads
                // detect the generation change and exit before we compete for the thread pool
                recentTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
                    guard !Task.isCancelled, let self else { return }
                    self.loadRecentFiles()
                }
            } else {
                displayItems = []
                showingRecent = false
            }
            return
        }
        showingRecent = false

        if let cq = ContentQuery.parse(text) {
            isContentSearch = true
            displayItems = []
            cachedResults = []
            loadedCount = 0

            contentKeyword = cq.pattern // H-9: cache computed keyword
            contentIsRegex = cq.isRegex
            guard !cq.pattern.isEmpty else {
                contentResults = []
                contentNotice = nil
                totalMatches = 0
                queryTimeMs = 0
                return
            }

            searchTask = Task { @MainActor in
                // 300ms debounce for content search (heavier)
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                performContentSearch(text)
            }
        } else {
            isContentSearch = false
            contentResults = []
            contentKeyword = "" // H-9: reset cached keyword

            searchTask = Task { @MainActor in
                // 80ms debounce
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard !Task.isCancelled else { return }
                performSearch(text)
            }
        }

        updateGhostSuggestion()
        scheduleHistoryRecord()
    }

    private func performSearch(_ keyword: String) {
        let bridge = self.bridge
        let maxResults = Self.maxResults
        let pageSize = Self.pageSize
        let gen = searchGeneration
        let query = searchOptions.buildQuery(keyword)
        Task.detached { [weak self] in
            let start = CFAbsoluteTimeGetCurrent()
            // P-4: Use batch method — single engine lock, no NSNumber boxing
            let results = bridge.queryResults(query, maxResults: maxResults, sessionId: Self.guiSessionId)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            let totalCount = results.count

            let firstPageCount = min(totalCount, pageSize)
            var items: [FileItem] = []
            items.reserveCapacity(firstPageCount)
            for i in 0..<firstPageCount {
                let r = results[i]
                items.append(FileItem(
                    id: "\(r.path)/\(r.name)", index: 0,
                    name: r.name, path: r.path,
                    type: r.type, size: r.size, modTime: r.modTime
                ))
            }

            await MainActor.run { [weak self] in
                guard let self, self.searchGeneration == gen else { return }
                self.cachedResults = results
                self.loadedCount = firstPageCount
                self.displayItems = items
                self.totalMatches = totalCount
                self.queryTimeMs = elapsed
            }
        }
    }

    private func performContentSearch(_ text: String) {
        guard let cq = ContentQuery.parse(text) else { return }
        let bridge = self.bridge
        let gen = searchGeneration
        let builtName = searchOptions.buildQuery(cq.nameQuery)
        contentToken?.cancel()
        let token = ContentCancelToken()
        contentToken = token
        Task.detached { [weak self] in
            let start = CFAbsoluteTimeGetCurrent()
            let outcome = ContentLineSearch.run(cq, nameQuery: builtName, bridge: bridge) {
                token.isCancelled   // set once a newer search starts
            }
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

            await MainActor.run { [weak self] in
                guard let self, self.searchGeneration == gen else { return }
                switch outcome {
                case .results(let items, let scanned):
                    self.contentResults = items
                    self.contentScannedFiles = scanned
                    self.contentNotice = nil
                    self.totalMatches = items.count
                case .needsFilter:
                    self.contentResults = []
                    self.totalMatches = 0
                    self.contentNotice = L("Regex search reads files directly — add a filter such as ext:swift or path:Projects to choose which files.")
                case .badRegex(let msg):
                    self.contentResults = []
                    self.totalMatches = 0
                    self.contentNotice = LF("Invalid regular expression: %@", msg)
                }
                self.queryTimeMs = elapsed
            }
        }
    }

    func loadMore() {
        guard !isLoadingMore else { return }
        guard loadedCount < cachedResults.count else { return }

        isLoadingMore = true
        let results = cachedResults
        let currentLoaded = loadedCount
        let pageSize = Self.pageSize
        let gen = searchGeneration

        // P-4: Results are already fetched — just slice the next page, no bridge calls needed
        Task.detached { [weak self] in
            let nextEnd = min(currentLoaded + pageSize, results.count)
            var newItems: [FileItem] = []
            newItems.reserveCapacity(nextEnd - currentLoaded)
            for i in currentLoaded..<nextEnd {
                let r = results[i]
                newItems.append(FileItem(
                    id: "\(r.path)/\(r.name)", index: 0,
                    name: r.name, path: r.path,
                    type: r.type, size: r.size, modTime: r.modTime
                ))
            }

            await MainActor.run { [weak self] in
                guard let self, self.searchGeneration == gen else {
                    self?.isLoadingMore = false
                    return
                }
                self.displayItems.append(contentsOf: newItems)
                self.loadedCount = nextEnd
                self.isLoadingMore = false
            }
        }
    }

    private func loadRecentFiles() {
        recentTask?.cancel()
        let bridge = self.bridge
        let gen = searchGeneration
        recentTask = Task.detached { [weak self] in
            // P-4: Use batch method — single engine lock, no NSNumber boxing
            let results = bridge.recentResults(100)
            var items: [FileItem] = []
            items.reserveCapacity(results.count)
            for r in results {
                guard !Task.isCancelled else { return }
                items.append(FileItem(
                    id: "\(r.path)/\(r.name)", index: 0,
                    name: r.name, path: r.path,
                    type: r.type, size: r.size, modTime: r.modTime
                ))
            }
            await MainActor.run { [weak self] in
                guard let self, self.searchGeneration == gen else { return }
                self.displayItems = items
                self.showingRecent = true
            }
        }
    }

    private func onIndexChanged() {
        if refreshThrottle.indexChanged() {
            performIndexRefresh()
            scheduleCooldown()
        }
    }

    func onWindowFocusChanged(_ focused: Bool) {
        if !focused {
            // Record search text to history when window loses focus
            let text = searchText
            if text.count >= 2 && !text.lowercased().hasPrefix("infile:") {
                historyStore.recordQuery(text)
            }
        }
        if refreshThrottle.focusChanged(focused) {
            performIndexRefresh()
            scheduleCooldown()
        }
    }

    private func scheduleCooldown() {
        indexChangeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.indexChangeThrottleNs)
            guard let self else { return }
            self.indexChangeTask = nil
            if self.refreshThrottle.cooldownExpired() {
                self.performIndexRefresh()
                self.scheduleCooldown()
            }
        }
    }

    private func performIndexRefresh() {
        MemoryStats.releaseFreedMemory(force: false)
        totalRecords = bridge.liveRecordCount()
        isMonitoring = bridge.isMonitoring
        isSyncing = bridge.isSyncing
        contentIndexedCount = bridge.contentIndexedFileCount()

        // Skip expensive search/query when app is not focused.
        // Results will refresh on focus regain via onWindowFocusChanged.
        guard refreshThrottle.isFocused else { return }

        if !searchText.isEmpty && !isContentSearch {
            performSearch(searchText)
        } else if isContentSearch && !contentKeyword.isEmpty {
            performContentSearch(searchText)
        } else if showingRecent {
            loadRecentFiles()
        }
    }

    var hasMoreResults: Bool {
        loadedCount < cachedResults.count
    }

    // H-9: Cached to avoid recomputing lowercased() + hasPrefix on every access
    private(set) var contentKeyword: String = ""

    // MARK: - Ghost text autocomplete

    private static let systemKeywords: [String] = [
        // Basic filters (most common first)
        "ext:", "size:", "file:", "folder:", "path:", "nopath:", "parent:", "depth:", "len:",
        // Date filters
        "dm:", "dc:", "da:", "datemodified:", "datecreated:", "dateaccessed:",
        // Modifiers
        "case:", "nocase:", "regex:", "ww:", "wfn:", "wholeword:", "wholefilename:",
        // Macros
        "audio:", "video:", "pic:", "doc:", "exe:", "zip:",
        // Other
        "content:", "type:",
    ]

    private static func systemKeywordMatch(for text: String) -> String? {
        let lower = text.lowercased()
        // Only match single partial words: no spaces, no colon already present
        guard !lower.isEmpty, !lower.contains(" "), !lower.contains(":") else { return nil }

        let matches = systemKeywords.filter { $0.hasPrefix(lower) }
        // Prefer shorter keywords, then alphabetical
        return matches.min { a, b in
            if a.count != b.count { return a.count < b.count }
            return a < b
        }
    }

    private func updateGhostSuggestion() {
        let text = searchText
        guard !text.isEmpty, !text.lowercased().hasPrefix("infile:") else {
            ghostSuggestion = nil
            return
        }
        // Priority 1: search history match
        if let match = historyStore.bestMatch(for: text),
           match.lowercased() != text.lowercased() {
            ghostSuggestion = text + match.dropFirst(text.count)
            return
        }
        // Priority 2: system keyword match
        if let keyword = Self.systemKeywordMatch(for: text) {
            ghostSuggestion = text + keyword.dropFirst(text.count)
            return
        }
        ghostSuggestion = nil
    }

    private func scheduleHistoryRecord() {
        settledTask?.cancel()
        let text = searchText
        guard text.count >= 2, !text.lowercased().hasPrefix("infile:") else { return }
        settledTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            guard !Task.isCancelled, let self, self.searchText == text else { return }
            self.historyStore.recordQuery(text)
        }
    }

    func acceptGhostSuggestion() {
        guard let suggestion = ghostSuggestion else { return }
        searchText = suggestion
        ghostSuggestion = nil
        historyStore.recordQuery(suggestion)
    }
}
