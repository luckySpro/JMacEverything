# JMacEverything — fork changes

Fork of [joshua-wu/MacEverything](https://github.com/joshua-wu/MacEverything) (MIT). The search engine is unchanged; this fork reworks the UI and adds workflow features.

## Look & feel
- Translucent window with hidden title bar (Spotlight/Raycast style) instead of the heavy blue-bordered search box
- Smaller, calmer search field (22pt), options moved into a slider menu next to the field
- Rows: 32px icons, middle-truncated paths, modified date, kind tag and size on the right
- Real selection highlight; friendly empty states; compact status footer with keyboard hints

## New features
| Feature | How |
|---|---|
| Keyboard navigation | ↑ ↓, Page Up/Down; ↩ open, ⌘↩ reveal in Finder |
| Quick Look | ⌘Y on the selected result, or right-click → Quick Look |
| Copy path | ⌥⌘C |
| Esc | clears the query; on an empty query it hides the window |
| Type filter chips | All / Apps / Folders / Documents / Images / Video / Audio / Code / Archives (also ⌘0–⌘8 via the Filter menu) |
| Sort | Relevance, Name, Date Modified, Size, Kind; ascending/descending (sorts the loaded results) |
| Richer context menu | Open With…, Open in Terminal, Copy Name, Copy Parent Folder, Move to Trash (recoverable) |

## Files touched
`App/ContentView.swift` (rewritten), `App/ResultRow.swift`, `App/ContentResultRow.swift`, `App/SearchOptions.swift`, `App/HighlightedSearchField.swift`, `App/MacEverythingApp.swift`. No new files were added, so the Xcode project needs no changes.

## Release
Bump `CFBundleShortVersionString` (and `CFBundleVersion`) in `MacEverything/Info.plist` and push to `main`: CI builds, tags `vX.Y.Z` and publishes the release with zip, dmg and SHA256SUMS. Builds are ad-hoc signed (not notarized): first launch needs right-click → Open.

## Build
Open `MacEverything.xcodeproj` in Xcode (macOS 14+, `brew install re2`), choose your signing team, ⌘R.
