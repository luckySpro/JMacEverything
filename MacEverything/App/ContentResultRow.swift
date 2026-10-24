import SwiftUI
import AppKit

struct ContentResultRow: View {
    let item: ContentFileItem
    let keyword: String
    var isSelected: Bool = false
    var onSelect: (() -> Void)? = nil
    @Environment(\.palette) private var palette
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            fileIcon(for: item.filePath)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.fileName)
                        .font(.title3)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Text(directoryPath(item.filePath))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                highlightMatches(in: item.snippet, keyword: keyword, font: .system(size: 11.5, design: .monospaced), color: palette.muted, highlightColor: palette.accent)
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? palette.surface
                      : (isHovered ? palette.surface.opacity(0.55) : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            FileContextMenu(path: item.filePath, isDirectory: false, isApp: false)
        }
        .onDrag {
            return NSItemProvider(object: NSURL(fileURLWithPath: item.filePath))
        }
        .onTapGesture(count: 2) {
            if NSEvent.modifierFlags.contains(.command) {
                revealInFinder()
            } else {
                openFile()
            }
        }
        .simultaneousGesture(TapGesture().onEnded { onSelect?() })
        .accessibilityIdentifier("contentResultRow")
    }

    private func directoryPath(_ fullPath: String) -> String {
        if let range = fullPath.range(of: "/", options: .backwards) {
            return String(fullPath[fullPath.startIndex..<range.lowerBound])
        }
        return fullPath
    }

    private func fileIcon(for path: String) -> Image {
        Image(nsImage: FileIconCache.shared.icon(forPath: path))
    }

    private func openFile() {
        if !NSWorkspace.shared.open(URL(fileURLWithPath: item.filePath)) {
            NSSound.beep()
        }
    }

    private func revealInFinder() {
        NSWorkspace.shared.selectFile(item.filePath, inFileViewerRootedAtPath: "")
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.filePath, forType: .string)
    }
}
