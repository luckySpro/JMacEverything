# JMacEverything — fork changes

Fork of [joshua-wu/MacEverything](https://github.com/joshua-wu/MacEverything) (MIT). The search engine is unchanged; this fork reworks the UI and adds workflow features.

## Look & feel
- Translucent window with hidden title bar (Spotlight/Raycast style) instead of the heavy blue-bordered search box
- Smaller, calmer search field (22pt), options moved into a slider menu next to the field
- Rows: 32px icons, middle-truncated paths, modified date, kind tag and size on the right
- Real selection highlight; friendly empty states; compact status footer with keyboard hints

## 1.4 — AutoCoder-style theme and color cards
- Dark top bar with the JMACEVERYTHING wordmark and numbered type tabs (`01 All … 09 Archives`, ⌘1–⌘9)
- Warm paper background, bordered search field, monospaced status strip, heavy double rule, list rows with hairlines and an accent bar on the selected row
- Five color cards, switchable from the palette icon in the top bar (remembered between launches): **Claude Paper** (default), **Ink Night** (dark), **Sage**, **Indigo**, **Plum**

![Color cards (design mock)](docs/design/color-cards.png)

## 1.6 — Own name and icon
- The app is now **JMacEverything.app** (window title, menu-bar items, DMG volume and files)
- New icon: terracotta magnifier with a cream "J" on warm ink, matching the Claude Paper palette
- Bundle ID stays `com.maceverything.app`, so the existing index cache and settings keep working

## Quick query (Everything syntax without typing it)
- A **QUICK** chip row under the search field: Today · This Week · Last Month · > 100 MB · > 1 GB · In Path… · Extension… · Exclude… · OR. Complete filters toggle on/off (highlighted when active); partial ones insert the prefix and leave the caret ready to type.
- **Query** menu with ⌃⌥ shortcuts: ⌃⌥T today, ⌃⌥W this week, ⌃⌥M last month, ⌃⌥B > 100 MB, ⌃⌥G > 1 GB, ⌃⌥F files only, ⌃⌥D folders only, ⌃⌥P `path:`, ⌃⌥E `ext:`, ⌃⌥X exclude `!`, ⌃⌥O OR `|`, ⌃⌥R `regex:`
- Existing helpers still apply: Tab accepts the grey auto-complete (`ex` → `ext:`), ⇧⌘/ opens the full syntax reference.

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
