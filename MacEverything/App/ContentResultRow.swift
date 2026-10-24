import SwiftUI
import AppKit

/// One matching line inside a file. When `showsFileHeader` is true the row starts a new file group.
struct ContentResultRow: View {
    let item: ContentFileItem
    let keyword: String
    var showsFileHeader: Bool = true
    var isSelected: Bool = false
    var onSelect: (() -> Void)? = nil
    @Environment(\.palette) private var palette
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsFileHeader {
                HStack(spacing: 10) {
                    Image(nsImage: FileIconCache.shared.icon(forPath: item.filePath))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 20, height: 20)
                    Text(item.fileName)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(palette.ink)
                        .lineLimit(1)
                    Text(directoryPath(item.filePath))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .padding(.top, 12)
                .padding(.bottom, 4)
                .padding(.horizontal, 8)
                .contextMenu {
                    FileContextMenu(path: item.filePath, isDirectory: false, isApp: false)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(item.line > 0 ? "\(item.line)" : "·")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(isSelected ? palette.accent : palette.muted)
                    .frame(width: 44, alignment: .trailing)
                highlightMatches(in: item.snippet, keyword: keyword,
                                 font: .system(size: 12, design: .monospaced),
                                 color: palette.ink.opacity(0.85), highlightColor: palette.accent)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .padding(.trailing, 10)
            .background(
                Rectangle().fill(isSelected ? palette.surface
                                 : (isHovered ? palette.surface.opacity(0.55) : Color.clear))
            )
            .overlay(alignment: .leading) {
                Rectangle().fill(isSelected ? palette.accent : Color.clear).frame(width: 3)
            }
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .contextMenu {
                Button { FileActions.openAt(item.filePath, line: item.line) } label: {
                    Label(LF("Open at Line %@", "\(item.line)"), systemImage: "text.cursor")
                }
                Button { FileActions.copy("\(item.filePath):\(item.line)") } label: {
                    Label(L("Copy path:line"), systemImage: "doc.on.doc")
                }
                Button { FileActions.copy(item.snippet) } label: {
                    Label(L("Copy Line"), systemImage: "text.quote")
                }
                Divider()
                FileContextMenu(path: item.filePath, isDirectory: false, isApp: false)
            }
            .onDrag { NSItemProvider(object: NSURL(fileURLWithPath: item.filePath)) }
            .onTapGesture(count: 2) {
                if NSEvent.modifierFlags.contains(.command) {
                    FileActions.reveal(item.filePath)
                } else {
                    FileActions.openAt(item.filePath, line: item.line)
                }
            }
            .simultaneousGesture(TapGesture().onEnded { onSelect?() })
        }
        .accessibilityIdentifier("contentResultRow")
    }

    private func directoryPath(_ fullPath: String) -> String {
        (fullPath as NSString).deletingLastPathComponent
    }
}
