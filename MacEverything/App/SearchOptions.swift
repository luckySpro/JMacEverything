import SwiftUI
import Combine

@MainActor
class SearchOptions: ObservableObject {
    static let shared = SearchOptions()

    @Published var isRegex: Bool = false {
        didSet {
            if isRegex {
                isWholeWord = false
                isMatchFilename = false
            }
        }
    }
    @Published var isCaseSensitive: Bool = false
    @Published var isWholeWord: Bool = false {
        didSet {
            if isWholeWord {
                isRegex = false
                isMatchFilename = false
            }
        }
    }
    @Published var isMatchFilename: Bool = false {
        didSet {
            if isMatchFilename {
                isRegex = false
                isWholeWord = false
            }
        }
    }

    /// Quick file-kind filter chosen from the chip bar under the search field.
    @Published var typeFilter: TypeFilter = .all

    private init() {}

    var hasActiveOptions: Bool {
        isRegex || isCaseSensitive || isWholeWord || isMatchFilename
    }

    /// Build query string with prefixes for the C++ engine
    func buildQuery(_ keyword: String) -> String {
        guard !keyword.isEmpty else { return keyword }
        var prefix = ""
        if isRegex { prefix += "regex:" }
        if isCaseSensitive { prefix += "case:" }
        if isWholeWord { prefix += "ww:" }
        if isMatchFilename { prefix += "wfn:" }
        let kind = typeFilter.query.isEmpty ? "" : typeFilter.query + " "
        return kind + prefix + keyword
    }
}

/// File-kind filters exposed as chips. Each maps to Everything-style query syntax
/// understood by the C++ engine (see Search Syntax Help → File Type Macros).
enum TypeFilter: String, CaseIterable, Identifiable {
    case all, apps, folders, documents, images, video, audio, code, archives

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .apps: return "Apps"
        case .folders: return "Folders"
        case .documents: return "Documents"
        case .images: return "Images"
        case .video: return "Video"
        case .audio: return "Audio"
        case .code: return "Code"
        case .archives: return "Archives"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .apps: return "app.badge"
        case .folders: return "folder"
        case .documents: return "doc.text"
        case .images: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .archives: return "archivebox"
        }
    }

    var query: String {
        switch self {
        case .all: return ""
        case .apps: return "ext:app"
        case .folders: return "folder:"
        case .documents: return "doc:"
        case .images: return "pic:"
        case .video: return "video:"
        case .audio: return "audio:"
        case .code: return "ext:swift;m;mm;c;cc;cpp;h;hpp;py;js;jsx;ts;tsx;go;rs;java;kt;rb;php;sh;zsh;lua;cs;vue;html;css;scss;json;yaml;yml;toml;sql"
        case .archives: return "zip:"
        }
    }
}

struct SearchOptionBadges: View {
    @ObservedObject var options: SearchOptions

    var body: some View {
        if options.hasActiveOptions {
            HStack(spacing: 4) {
                if options.isRegex {
                    badge(".*", color: .purple) { options.isRegex.toggle() }
                }
                if options.isCaseSensitive {
                    badge("Aa", color: .orange) { options.isCaseSensitive.toggle() }
                }
                if options.isWholeWord {
                    badge("W", color: .blue) { options.isWholeWord.toggle() }
                }
                if options.isMatchFilename {
                    badge("FN", color: .green) { options.isMatchFilename.toggle() }
                }
            }
        }
    }

    private func badge(_ text: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(color))
        }
        .buttonStyle(.plain)
    }
}
