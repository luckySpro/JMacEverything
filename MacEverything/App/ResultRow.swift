import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Shared icon cache to avoid repeated NSWorkspace.shared.icon(forFile:) calls.
/// - App bundles (type=5): cached by full path (each app has a unique icon)
/// - Regular files (type=1): cached by file extension (same ext → same icon)
/// - Directories/symlinks/other: cached by type (one icon per type)
final class FileIconCache {
    static let shared = FileIconCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 500
    }

    func icon(for item: FileItem) -> NSImage {
        // Detect app bundles by name suffix (handles both type=5 and legacy type=2)
        let isApp = item.name.hasSuffix(".app")

        let key: String
        if isApp {
            // App bundles — unique icon per app
            key = "app:" + item.path + "/" + item.name
        } else if item.type == 1 {
            // Regular file — same icon per extension
            let ext = (item.name as NSString).pathExtension.lowercased()
            key = "ext:" + (ext.isEmpty ? "__no_ext__" : ext)
        } else {
            // Dir, symlink, other — one icon per type
            key = "type:\(item.type)"
        }

        let nsKey = key as NSString
        if let cached = cache.object(forKey: nsKey) {
            return cached
        }

        let fullPath = item.path + "/" + item.name
        let nsImage = NSWorkspace.shared.icon(forFile: fullPath)
        nsImage.size = NSSize(width: 32, height: 32)
        cache.setObject(nsImage, forKey: nsKey)
        return nsImage
    }

    func icon(forPath path: String) -> NSImage {
        let ext = (path as NSString).pathExtension.lowercased()
        let key = "ext:" + (ext.isEmpty ? "__no_ext__" : ext) as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let nsImage = NSWorkspace.shared.icon(forFile: path)
        nsImage.size = NSSize(width: 32, height: 32)
        cache.setObject(nsImage, forKey: key)
        return nsImage
    }
}

// MARK: - File actions (shared by rows, context menus and keyboard shortcuts)

enum FileActions {
    static func fullPath(_ item: FileItem) -> String { item.path + "/" + item.name }

    static func open(_ path: String, isApp: Bool = false) {
        let url = URL(fileURLWithPath: path)
        if isApp {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else if !NSWorkspace.shared.open(url) {
            NSSound.beep()
        }
    }

    static func open(_ item: FileItem) {
        open(fullPath(item), isApp: item.type == 5 || item.name.hasSuffix(".app"))
    }

    static func reveal(_ path: String) {
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// Quick Look preview via the system qlmanage helper (app is not sandboxed).
    static func quickLook(_ path: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        p.arguments = ["-p", path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        // qlmanage opens behind us; bring its panel forward shortly after launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSRunningApplication(processIdentifier: p.processIdentifier)?.activate()
        }
    }

    static func openInTerminal(_ path: String, isDirectory: Bool) {
        let dir = isDirectory ? path : (path as NSString).deletingLastPathComponent
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: dir)], withApplicationAt: terminal,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    static func openWith(_ path: String) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Open"
        panel.message = "Choose an application to open \((path as NSString).lastPathComponent)"
        if panel.runModal() == .OK, let app = panel.url {
            NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app,
                                    configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Moves to Trash (recoverable), never deletes permanently.
    static func moveToTrash(_ path: String) {
        NSWorkspace.shared.recycle([URL(fileURLWithPath: path)]) { _, error in
            if error != nil { NSSound.beep() }
        }
    }

    static func formatSize(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bitPattern: bytes), countStyle: .file)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    /// "5 min. ago" for the last week, a calendar date otherwise.
    static func formatDate(_ t: time_t) -> String {
        guard t > 0 else { return "—" }
        let date = Date(timeIntervalSince1970: TimeInterval(t))
        if Date().timeIntervalSince(date) < 7 * 24 * 3600 {
            return relativeFormatter.localizedString(for: date, relativeTo: Date())
        }
        return dateFormatter.string(from: date)
    }

    static func kind(_ item: FileItem) -> String {
        if item.name.hasSuffix(".app") { return "Application" }
        switch item.type {
        case 2: return "Folder"
        case 3: return "Symlink"
        case 5: return "Application"
        default:
            let ext = (item.name as NSString).pathExtension
            return ext.isEmpty ? "File" : ext.uppercased()
        }
    }
}

/// Shared context menu for any result path.
struct FileContextMenu: View {
    let path: String
    let isDirectory: Bool
    let isApp: Bool

    var body: some View {
        Button { FileActions.open(path, isApp: isApp) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
        Button { FileActions.openWith(path) } label: { Label("Open With…", systemImage: "square.and.arrow.up.on.square") }
        Button { FileActions.reveal(path) } label: { Label("Reveal in Finder", systemImage: "folder") }
        Button { FileActions.quickLook(path) } label: { Label("Quick Look", systemImage: "eye") }
        Button { FileActions.openInTerminal(path, isDirectory: isDirectory) } label: { Label("Open in Terminal", systemImage: "terminal") }
        Divider()
        Button { FileActions.copy(path) } label: { Label("Copy Path", systemImage: "doc.on.doc") }
        Button { FileActions.copy((path as NSString).lastPathComponent) } label: { Label("Copy Name", systemImage: "textformat") }
        Button { FileActions.copy((path as NSString).deletingLastPathComponent) } label: { Label("Copy Parent Folder", systemImage: "folder.badge.questionmark") }
        Divider()
        Button(role: .destructive) { FileActions.moveToTrash(path) } label: { Label("Move to Trash", systemImage: "trash") }
    }
}

struct ResultRow: View {
    let item: FileItem
    let hints: [HighlightHint]
    var isSelected: Bool = false
    var onSelect: (() -> Void)? = nil
    @Environment(\.palette) private var palette
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: FileIconCache.shared.icon(for: item))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                let highlighted = highlightCrossMatches(
                    path: item.path, name: item.name, hints: hints,
                    nameFont: .system(size: 14, weight: .semibold), nameColor: palette.ink,
                    pathFont: .system(size: 11, design: .monospaced), pathColor: palette.muted,
                    highlightColor: palette.accent)
                highlighted.nameText.lineLimit(1)
                highlighted.pathText.lineLimit(1).truncationMode(.middle)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 2) {
                Text(FileActions.formatDate(item.modTime))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(palette.muted)
                HStack(spacing: 6) {
                    Text(FileActions.kind(item))
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(palette.muted)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(palette.rule, lineWidth: 1))
                    if item.type == 1 && item.size > 0 {
                        Text(FileActions.formatSize(item.size))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(palette.muted)
                    }
                }
            }
            .frame(minWidth: 110, alignment: .trailing)
        }
        .padding(.vertical, 9)
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .background(
            Rectangle().fill(isSelected ? palette.surface
                             : (isHovered ? palette.surface.opacity(0.55) : Color.clear))
        )
        .overlay(alignment: .leading) {
            Rectangle().fill(isSelected ? palette.accent : Color.clear).frame(width: 3)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.rule.opacity(0.7)).frame(height: 1)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            FileContextMenu(path: FileActions.fullPath(item),
                            isDirectory: item.type == 2,
                            isApp: item.name.hasSuffix(".app"))
        }
        .onDrag {
            NSItemProvider(object: NSURL(fileURLWithPath: FileActions.fullPath(item)))
        }
        .onTapGesture(count: 2) {
            if NSEvent.modifierFlags.contains(.command) {
                FileActions.reveal(FileActions.fullPath(item))
            } else {
                FileActions.open(item)
            }
        }
        .simultaneousGesture(TapGesture().onEnded { onSelect?() })
        .accessibilityIdentifier("resultRow")
    }
}
