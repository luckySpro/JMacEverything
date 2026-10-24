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
        case .all: return L("All")
        case .apps: return L("Apps")
        case .folders: return L("Folders")
        case .documents: return L("Documents")
        case .images: return L("Images")
        case .video: return L("Video")
        case .audio: return L("Audio")
        case .code: return L("Code")
        case .archives: return L("Archives")
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

// MARK: - Localization (zh-Hans, zh-Hant, en, ja; follows the system or a user choice)

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, zhHans = "zh-Hans", zhHant = "zh-Hant", en, ja
    var id: String { rawValue }
    /// Shown in its own language so people can always find theirs.
    var displayName: String {
        switch self {
        case .system: return L("Follow System")
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .en: return "English"
        case .ja: return "日本語"
        }
    }
}

final class L10n: ObservableObject {
    static let shared = L10n()
    private static let key = "appLanguage"

    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.key)
            resolved = Self.resolve(language)
            NotificationCenter.default.post(name: .languageChanged, object: nil)
        }
    }
    @Published private(set) var resolved: AppLanguage

    private init() {
        let saved = AppLanguage(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "") ?? .system
        language = saved
        resolved = Self.resolve(saved)
    }

    static func resolve(_ lang: AppLanguage) -> AppLanguage {
        guard lang == .system else { return lang }
        for pref in Locale.preferredLanguages {
            let p = pref.lowercased()
            if p.hasPrefix("zh-hant") || p.hasPrefix("zh-tw") || p.hasPrefix("zh-hk") || p.hasPrefix("zh-mo") { return .zhHant }
            if p.hasPrefix("zh") { return .zhHans }
            if p.hasPrefix("ja") { return .ja }
            if p.hasPrefix("en") { return .en }
        }
        return .en
    }

    /// Locale for dates and relative times in the chosen language.
    var locale: Locale {
        switch resolved {
        case .zhHans: return Locale(identifier: "zh-Hans")
        case .zhHant: return Locale(identifier: "zh-Hant")
        case .ja: return Locale(identifier: "ja")
        default: return Locale(identifier: "en")
        }
    }

    func translate(_ english: String) -> String {
        guard resolved != .en, let row = L10nTable.rows[english] else { return english }
        switch resolved {
        case .zhHans: return row.0
        case .zhHant: return row.1
        case .ja: return row.2
        default: return english
        }
    }
}

extension Notification.Name {
    static let languageChanged = Notification.Name("languageChanged")
}

/// Translate a UI string (English source text is the key; missing keys fall back to English).
func L(_ english: String) -> String { L10n.shared.translate(english) }

/// Translate a format string ("%@ indexed") and fill it in.
func LF(_ english: String, _ args: CVarArg...) -> String {
    String(format: L10n.shared.translate(english), locale: L10n.shared.locale, arguments: args)
}

enum L10nTable {
    // English: (简体中文, 繁體中文, 日本語)
    static let rows: [String: (String, String, String)] = [
        // Language menu
        "Follow System": ("跟随系统", "跟隨系統", "システムに従う"),
        "Language": ("语言", "語言", "言語"),
        // Type tabs
        "All": ("全部", "全部", "すべて"),
        "Apps": ("应用", "應用程式", "アプリ"),
        "Folders": ("文件夹", "檔案夾", "フォルダ"),
        "Documents": ("文档", "文件", "書類"),
        "Images": ("图片", "圖片", "画像"),
        "Video": ("视频", "影片", "ビデオ"),
        "Audio": ("音频", "音訊", "オーディオ"),
        "Code": ("代码", "程式碼", "コード"),
        "Archives": ("压缩包", "壓縮檔", "アーカイブ"),
        // Sort
        "Relevance": ("相关度", "相關度", "関連度"),
        "Name": ("名称", "名稱", "名前"),
        "Date Modified": ("修改日期", "修改日期", "変更日"),
        "Size": ("大小", "大小", "サイズ"),
        "Kind": ("类型", "類型", "種類"),
        "Sort By": ("排序方式", "排序方式", "並べ替え"),
        "Ascending": ("升序", "遞增", "昇順"),
        "Sort loaded results": ("对已加载的结果排序", "排序已載入的結果", "読み込んだ結果を並べ替え"),
        // Quick
        "QUICK": ("快捷", "快捷", "クイック"),
        "Today": ("今天", "今天", "今日"),
        "This Week": ("本周", "本週", "今週"),
        "Last Month": ("上月", "上個月", "先月"),
        "Files Only": ("只要文件", "只要檔案", "ファイルのみ"),
        "Folders Only": ("只要文件夹", "只要檔案夾", "フォルダのみ"),
        "In Path…": ("路径包含…", "路徑包含…", "パスに含む…"),
        "Extension…": ("扩展名…", "副檔名…", "拡張子…"),
        "Exclude…": ("排除…", "排除…", "除外…"),
        "OR": ("或", "或", "または"),
        "Regex…": ("正则…", "正規表示式…", "正規表現…"),
        "In Content…": ("搜内容…", "搜內容…", "内容を検索…"),
        "Syntax ⇧⌘/": ("语法 ⇧⌘/", "語法 ⇧⌘/", "構文 ⇧⌘/"),
        "Query": ("查询", "查詢", "クエリ"),
        "Filter": ("筛选", "篩選", "フィルタ"),
        "Search": ("搜索", "搜尋", "検索"),
        // Search field & options
        "Search files and folders…": ("搜索文件和文件夹…", "搜尋檔案和檔案夾…", "ファイルとフォルダを検索…"),
        "Clear (Esc)": ("清空（Esc）", "清除（Esc）", "クリア（Esc）"),
        "Regex": ("正则表达式", "正規表示式", "正規表現"),
        "Case Sensitive": ("区分大小写", "區分大小寫", "大文字と小文字を区別"),
        "Whole Word": ("全词匹配", "全字匹配", "単語単位"),
        "Match Whole Filename": ("匹配完整文件名", "比對完整檔名", "ファイル名全体に一致"),
        "Match Filename": ("匹配文件名", "比對檔名", "ファイル名に一致"),
        "Show Recently Modified Files When Empty": ("搜索框为空时显示最近修改的文件", "搜尋框為空時顯示最近修改的檔案", "空欄のとき最近変更したファイルを表示"),
        "Search Syntax Help": ("搜索语法帮助", "搜尋語法說明", "検索構文ヘルプ"),
        "Content Settings…": ("内容搜索设置…", "內容搜尋設定…", "内容検索の設定…"),
        "Shortcut Settings…": ("快捷键设置…", "快速鍵設定…", "ショートカット設定…"),
        "Search options": ("搜索选项", "搜尋選項", "検索オプション"),
        "Color Card": ("色卡", "色卡", "カラー"),
        "Color card": ("色卡", "色卡", "カラー"),
        "Shortcut Settings...": ("快捷键设置…", "快速鍵設定…", "ショートカット設定…"),
        "Content Settings...": ("内容搜索设置…", "內容搜尋設定…", "内容検索の設定…"),
        "Search Syntax Help...": ("搜索语法帮助…", "搜尋語法說明…", "検索構文ヘルプ…"),
        "Rebuild Index": ("重建索引", "重建索引", "インデックスを再構築"),
        // Status / meta
        "RESULTS": ("结果", "結果", "結果"),
        "RECENT": ("最近", "最近", "最近"),
        "READY": ("就绪", "就緒", "準備完了"),
        "CONTENT": ("内容", "內容", "内容"),
        "Indexing…": ("正在建立索引…", "正在建立索引…", "インデックス作成中…"),
        "Syncing": ("同步中", "同步中", "同期中"),
        "Watching the file system for changes": ("正在实时监控文件变化", "正在即時監控檔案變化", "ファイルの変更を監視中"),
        "%@ indexed": ("已索引 %@ 个", "已索引 %@ 個", "%@ 件をインデックス済み"),
        "Content %@/%@": ("内容 %@/%@", "內容 %@/%@", "内容 %@/%@"),
        "%@ lines in %@ files": ("%@ 个文件中的 %@ 行", "%@ 個檔案中的 %@ 行", "%@ ファイル中 %@ 行"),
        "%@ of %@ matches": ("%@ / %@ 个匹配", "%@ / %@ 個符合", "%@ / %@ 件一致"),
        "%@ matches": ("%@ 个匹配", "%@ 個符合", "%@ 件一致"),
        "RAM %@": ("内存 %@", "記憶體 %@", "メモリ %@"),
        "Memory used by JMacEverything (same as Activity Monitor)": ("JMacEverything 占用的内存（与活动监视器一致）", "JMacEverything 使用的記憶體（與活動監視器一致）", "JMacEverything のメモリ使用量（アクティビティモニタと同じ）"),
        "⌘1–9 filters · Esc hide": ("⌘1–9 筛选 · Esc 隐藏", "⌘1–9 篩選 · Esc 隱藏", "⌘1–9 フィルタ · Esc 隠す"),
        "Select": ("选择", "選擇", "選択"),
        "Open": ("打开", "開啟", "開く"),
        "Reveal": ("显示", "顯示", "表示"),
        "Quick Look": ("快速查看", "快速查看", "クイックルック"),
        "Copy Path": ("复制路径", "拷貝路徑", "パスをコピー"),
        // Empty states
        "Building the index…": ("正在建立索引…", "正在建立索引…", "インデックスを作成中…"),
        "%@ items scanned so far": ("已扫描 %@ 项", "已掃描 %@ 項", "%@ 項目をスキャン済み"),
        "No results": ("没有结果", "沒有結果", "結果なし"),
        "Try fewer words, wildcards like *.pdf, or press ⇧⌘/ for syntax help.": ("试试更少的关键词、*.pdf 这样的通配符，或按 ⇧⌘/ 查看语法帮助。", "試試更少的關鍵字、*.pdf 這樣的萬用字元，或按 ⇧⌘/ 查看語法說明。", "キーワードを減らす、*.pdf のようなワイルドカードを使う、または ⇧⌘/ で構文ヘルプを表示してください。"),
        "Nothing matched in %@. Try the All filter.": ("「%@」里没有匹配，试试「全部」。", "「%@」中沒有符合，試試「全部」。", "「%@」に一致なし。「すべて」を試してください。"),
        "Recently Modified": ("最近修改", "最近修改", "最近の変更"),
        "Loading more…": ("正在加载更多…", "正在載入更多…", "さらに読み込み中…"),
        "Search inside files": ("搜索文件内容", "搜尋檔案內容", "ファイル内を検索"),
        "Type what to look for after grep: — combine with filters, e.g.  ext:swift grep:TODO   or   path:Projects inre:fn\\s+main": ("在 grep: 后面输入要找的内容，可以和其他条件组合，例如  ext:swift grep:TODO   或   path:Projects inre:fn\\s+main", "在 grep: 後面輸入要找的內容，可與其他條件組合，例如  ext:swift grep:TODO   或   path:Projects inre:fn\\s+main", "grep: の後に検索語を入力。条件と組み合わせられます。例：ext:swift grep:TODO   または   path:Projects inre:fn\\s+main"),
        "Regex needs a filter": ("正则搜索需要筛选条件", "正規表示式搜尋需要篩選條件", "正規表現には条件が必要です"),
        "Can't search": ("无法搜索", "無法搜尋", "検索できません"),
        "Content index is building…": ("正在建立内容索引…", "正在建立內容索引…", "内容インデックスを作成中…"),
        "Indexed %@ of %@ files": ("已索引 %@ / %@ 个文件", "已索引 %@ / %@ 個檔案", "%@ / %@ ファイルをインデックス済み"),
        "No matching lines": ("没有匹配的行", "沒有符合的行", "一致する行なし"),
        "Only files you filter by name are read (e.g. ext:md grep:%@). Add file types in Content Settings to search everywhere.": ("只会读取按名称筛选出的文件（例如 ext:md grep:%@）。在「内容搜索设置」里添加文件类型即可全盘搜索。", "只會讀取依名稱篩選出的檔案（例如 ext:md grep:%@）。在「內容搜尋設定」加入檔案類型即可全碟搜尋。", "名前で絞り込んだファイルだけを読み込みます（例：ext:md grep:%@）。全体を検索するには「内容検索の設定」でファイル種類を追加してください。"),
        "Nothing contains “%@”. Add a filter such as ext:txt to also read files outside the content index.": ("没有文件包含「%@」。加上 ext:txt 这类条件，可以连同内容索引以外的文件一起读取。", "沒有檔案包含「%@」。加上 ext:txt 這類條件，可連同內容索引以外的檔案一起讀取。", "「%@」を含むファイルはありません。ext:txt などの条件を加えると、内容インデックス外のファイルも読み込みます。"),
        "Regex search reads files directly — add a filter such as ext:swift or path:Projects to choose which files.": ("正则搜索会直接读取文件，请加上 ext:swift 或 path:Projects 这类条件来限定范围。", "正規表示式搜尋會直接讀取檔案，請加上 ext:swift 或 path:Projects 這類條件來限定範圍。", "正規表現検索はファイルを直接読み込みます。ext:swift や path:Projects などで対象を絞ってください。"),
        "Invalid regular expression: %@": ("正则表达式有误：%@", "正規表示式有誤：%@", "正規表現が不正です：%@"),
        // Start panel
        "Find anything on your Mac": ("在 Mac 上找到任何东西", "在 Mac 上找到任何東西", "Mac のあらゆるものを見つける"),
        "Start typing — results appear as you type. Use the tabs above to narrow by kind.": ("直接输入，结果随打随出；用上方的标签按类型缩小范围。", "直接輸入，結果隨打隨出；用上方的標籤依類型縮小範圍。", "入力するとすぐに結果が表示されます。上のタブで種類を絞り込めます。"),
        "RECENT SEARCHES": ("最近搜索", "最近搜尋", "最近の検索"),
        "Clear": ("清除", "清除", "クリア"),
        "TRY": ("试试", "試試", "試す"),
        "All PDFs": ("所有 PDF", "所有 PDF", "すべての PDF"),
        "Changed today": ("今天修改过的", "今天修改過的", "今日変更したもの"),
        "Huge files": ("超大文件", "超大檔案", "巨大なファイル"),
        "Swift files named todo": ("名字含 todo 的 Swift 文件", "名稱含 todo 的 Swift 檔案", "名前に todo を含む Swift ファイル"),
        "Folders named project": ("名为 project 的文件夹", "名為 project 的檔案夾", "project という名前のフォルダ"),
        "Installers in Downloads": ("下载文件夹里的安装包", "下載檔案夾中的安裝檔", "ダウンロード内のインストーラ"),
        "Text inside files": ("文件里的文字", "檔案中的文字", "ファイル内のテキスト"),
        // Result rows & menus
        "Application": ("应用", "應用程式", "アプリケーション"),
        "Folder": ("文件夹", "檔案夾", "フォルダ"),
        "Symlink": ("替身", "替身", "シンボリックリンク"),
        "File": ("文件", "檔案", "ファイル"),
        "Open With…": ("打开方式…", "打開方式…", "このアプリで開く…"),
        "Reveal in Finder": ("在 Finder 中显示", "在 Finder 中顯示", "Finder に表示"),
        "Open in Terminal": ("在终端中打开", "在終端機中開啟", "ターミナルで開く"),
        "Copy Name": ("复制名称", "拷貝名稱", "名前をコピー"),
        "Copy Parent Folder": ("复制所在文件夹", "拷貝所在檔案夾", "親フォルダをコピー"),
        "Move to Trash": ("移到废纸篓", "丟到垃圾桶", "ゴミ箱に入れる"),
        "Open at Line %@": ("在第 %@ 行打开", "在第 %@ 行開啟", "%@ 行目で開く"),
        "Copy path:line": ("复制 路径:行号", "拷貝 路徑:行號", "パス:行 をコピー"),
        "Copy Line": ("复制这一行", "拷貝這一行", "この行をコピー"),
        // Menu bar panel
        "Show JMacEverything": ("显示 JMacEverything", "顯示 JMacEverything", "JMacEverything を表示"),
        "Hide JMacEverything": ("隐藏 JMacEverything", "隱藏 JMacEverything", "JMacEverything を隠す"),
        "Quit JMacEverything": ("退出 JMacEverything", "結束 JMacEverything", "JMacEverything を終了"),
        "Launch at Login": ("登录时启动", "登入時啟動", "ログイン時に起動"),
        "Keep Running in Menu Bar": ("常驻菜单栏", "常駐選單列", "メニューバーに常駐"),
        "MCP Integration": ("MCP 集成", "MCP 整合", "MCP 連携"),
        "Live": ("实时", "即時", "ライブ"),
        "Scanning": ("扫描中", "掃描中", "スキャン中"),
        "files": ("个文件", "個檔案", "ファイル"),
        "Memory": ("内存", "記憶體", "メモリ"),
        "Settings": ("设置", "設定", "設定"),
        "Startup": ("启动", "啟動", "起動"),
        "Appearance": ("外观", "外觀", "外観"),
        "Hotkey": ("快捷键", "快速鍵", "ホットキー"),
        // Settings windows
        "Content Settings": ("内容搜索设置", "內容搜尋設定", "内容検索の設定"),
        "Shortcut Settings": ("快捷键设置", "快速鍵設定", "ショートカット設定"),
        "Content Indexing": ("内容索引", "內容索引", "内容インデックス"),
        "Indexed Files: %@": ("已索引文件：%@", "已索引檔案：%@", "インデックス済み：%@"),
        "Max File Size": ("最大文件大小", "最大檔案大小", "最大ファイルサイズ"),
        "File Extensions": ("文件扩展名", "副檔名", "拡張子"),
        "Add extension...": ("添加扩展名…", "新增副檔名…", "拡張子を追加…"),
        "Add": ("添加", "新增", "追加"),
        "Add Common Text & Code Types": ("添加常用文本和代码类型", "新增常用文字與程式碼類型", "一般的なテキストとコードの種類を追加"),
        "Plain text, Markdown, config files and source code": ("纯文本、Markdown、配置文件和源代码", "純文字、Markdown、設定檔和原始碼", "プレーンテキスト、Markdown、設定ファイル、ソースコード"),
        "Apply": ("应用", "套用", "適用"),
        "Global Hotkey Settings": ("全局快捷键设置", "全域快速鍵設定", "グローバルホットキー設定"),
        "Click the button below and press your desired key combination to set the global hotkey for showing/hiding MacEverything.": ("点击下面的按钮，然后按下想用的组合键，设置显示/隐藏 JMacEverything 的全局快捷键。", "點按下方按鈕，然後按下想用的組合鍵，設定顯示/隱藏 JMacEverything 的全域快速鍵。", "下のボタンをクリックし、JMacEverything の表示/非表示に使うキーの組み合わせを押してください。"),
        "Current Shortcut": ("当前快捷键", "目前快速鍵", "現在のショートカット"),
        "Press a key combination...": ("请按下组合键…", "請按下組合鍵…", "キーの組み合わせを押してください…"),
        "Reset to Default": ("恢复默认", "還原預設值", "デフォルトに戻す"),
        "Close": ("关闭", "關閉", "閉じる"),
        "Full Disk Access is required to scan all files.": ("需要「完全磁盘访问权限」才能扫描所有文件。", "需要「完整磁碟取用權限」才能掃描所有檔案。", "すべてのファイルをスキャンするには「フルディスクアクセス」が必要です。"),
        "Open Settings": ("打开系统设置", "打開系統設定", "システム設定を開く"),
        // Syntax help sections
        "Basic Search": ("基础搜索", "基礎搜尋", "基本検索"),
        "Boolean Operators": ("逻辑运算", "邏輯運算", "論理演算子"),
        "Wildcards / Glob": ("通配符", "萬用字元", "ワイルドカード"),
        "Extension Filter": ("扩展名筛选", "副檔名篩選", "拡張子フィルタ"),
        "Size Filter": ("大小筛选", "大小篩選", "サイズフィルタ"),
        "Type Filter": ("类型筛选", "類型篩選", "種類フィルタ"),
        "Path Filter": ("路径筛选", "路徑篩選", "パスフィルタ"),
        "Date Filter": ("日期筛选", "日期篩選", "日付フィルタ"),
        "Name Length Filter": ("文件名长度筛选", "檔名長度篩選", "名前の長さフィルタ"),
        "Match Modifiers": ("匹配方式", "比對方式", "一致オプション"),
        "File Type Macros": ("文件类型宏", "檔案類型巨集", "ファイル種類マクロ"),
        "Structured Path Query": ("结构化路径查询", "結構化路徑查詢", "構造化パス検索"),
        "Content Search": ("内容搜索", "內容搜尋", "内容検索"),
        "Tilde Expansion": ("~ 展开", "~ 展開", "~ の展開"),
        // Palettes
        "Claude Paper": ("Claude 暖纸", "Claude 暖紙", "Claude ペーパー"),
        "Ink Night": ("墨夜", "墨夜", "インクナイト"),
        "Sage": ("鼠尾草绿", "鼠尾草綠", "セージ"),
        "Indigo": ("靛蓝", "靛藍", "インディゴ"),
        "Plum": ("梅子红", "梅子紅", "プラム"),
    ]
}
