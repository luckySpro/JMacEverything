# JMacEverything 2.0 方案：一套代码，Mac + Windows

> 状态：方案稿（v2 分支）· 起草：2026-10-24 · 方法：lucky-rust-fullstack
> 进度记录见 [PROGRESS.md](PROGRESS.md)，关键取舍见 [DECISIONS.md](DECISIONS.md)。

## 1. 目标与验收

**一句话目标**：在 Mac 和 Windows 上提供同一个「毫秒级文件搜索 + 带行号的内容搜索」工具，界面、语法、快捷键一致，下载即用、离线可用、可自动升级。

**核心链路（必须端到端跑通才算 2.0）**

1. 首次启动 → 引导授权（Mac：完全磁盘访问；Windows：安装服务）→ 建立全盘索引并显示进度
2. 输入 `ext:pdf 合同 dm:thisweek` → 50 ms 内出结果，↑↓ 选择，↩ 打开，⌘/Ctrl+↩ 在 Finder/资源管理器中显示
3. 输入 `ext:rs grep:apply_dir` → 列出匹配行和行号，↩ 在编辑器里跳到该行
4. 新建、改名、删除文件 → 1 秒内反映到结果里
5. 退出重开 → 2 秒内可搜索（从磁盘加载索引，不重扫）
6. 发布新版本 → 旧版本收到升级提示，验签后安装并重启

7. **常驻**：关闭窗口、⌘Q / Alt+F4、Dock 或任务栏右键「退出」都只隐藏到菜单栏 / 系统托盘，索引继续在后台更新；全局快捷键（默认 ⌥Space / Alt+Space）随时唤出；只有托盘菜单里的「退出」和系统注销/关机才真正退出；默认开机自启（可关）。

8. **多语言**：简体中文、繁体中文、English、日本語；默认跟随系统，可在设置和托盘面板中即时切换（1.11 已在 Mac 版实现，2.0 用共享语言包 + 相同 key 延续）。
9. **托盘 / 菜单栏面板**：左键显示/隐藏主窗口；右键弹出 Claude 暖纸风格的控制面板（状态、常用操作、启动项、MCP、色卡、语言、退出），两平台同一套前端组件（1.11 的 Mac 版为参考实现）。

**量化指标（250 万文件，Apple Silicon / 主流 Windows 笔记本）**

| 指标 | 目标 |
|---|---|
| 文件名搜索延迟（中位数） | < 10 ms |
| 首次全盘索引 | Mac < 30 s；Windows（NTFS MFT）< 20 s |
| 文件变化可见 | < 1 s |
| 常驻内存（不开内容索引） | < 400 MB |
| 安装包体积 | < 15 MB |

**不做（2.0 范围外）**：账号、云同步、遥测、Linux 版、移动端。

## 2. 为什么这样拆：现有代码盘点

| 部分 | 现状 | 2.0 处理 |
|---|---|---|
| C++ 引擎：索引、查询解析、Everything 语法、WAL、持久化（约 9,200 行） | 质量高，11,962 个测试全过；依赖 GCD（dispatch_apply）和 CoreFoundation（toLower） | **保留**，去掉平台依赖后经 FFI 供 Rust 调用（见 D-001） |
| 扫描与监控：getattrlistbulk + FSEvents | 仅 macOS | Mac 保留并迁到适配层；Windows 新写 MFT + USN 版本 |
| 内容索引（三元组）+ 行级 grep（Swift） | 内容索引在 C++，行级搜索在 Swift | 行级搜索改写进 Rust（借鉴 fsearch / ripgrep 的 grep-searcher） |
| 界面：SwiftUI | 仅 macOS | 用 Tauri 2 + Vue 3 重写，保留暖纸风格、5 套色卡、QUICK 按钮、起始页 |
| MCP 服务、HTTP 本地服务（C++） | 可用 | 迁到 Rust（rmcp），本地服务只接受本机来源 |
| 打包发布：GitHub Actions 自动发版 | 仅 macOS arm64 | 矩阵：macOS arm64 + x64、Windows x64；Tauri updater + 签名 |

## 3. 架构

```
┌──────────────────────── Tauri 2 应用（普通用户权限） ────────────────────────┐
│  Vue 3 前端：搜索框 · 分类标签 · QUICK · 结果/内容行 · 色卡 · 设置 · 起始页     │
│        │ Tauri IPC（类型化命令，Rust 端校验）                                   │
│  app crate：命令层 · 窗口/托盘/全局快捷键 · 打开/显示/预览 · 升级                 │
└────────┬───────────────────────────────────────────────────────────────────────┘
         │
   jme-core（Rust，平台无关）
   ├─ engine  ── FFI(cxx) ──► C++ 引擎（索引 / 查询解析 / WAL / 持久化）
   ├─ content    行级 grep：行号、智能大小写、正则、跳到行
   ├─ settings   用户配置（界面内管理，原子写入 + 备份）
   └─ mcp        find_files / grep，给 AI 编程工具用
         │
   jme-platform（trait FileSource + 各平台实现）
   ├─ macos      getattrlistbulk 全盘扫描 + FSEvents 增量
   └─ windows    ├─ 有服务：MFT 枚举 + USN 日志（jme-indexer 服务，SYSTEM 权限，只做读取）
                 └─ 无服务：FindFirstFileEx 遍历 + ReadDirectoryChangesW（降级，较慢）
```

**权限边界（Windows）**：读取 MFT/USN 需要管理员。由安装器注册一个只读的 `jme-indexer` 服务，通过命名管道向 GUI 提供「文件记录流」；GUI 始终是普通用户。服务校验调用方，不执行任何写盘或命令；版本不一致时 GUI 停止使用并提示更新整套组件。

## 4. 分阶段计划

每个阶段结束都要：代码合入 `v2`、CI 绿、PROGRESS.md 记一行、可演示。

| 阶段 | 内容 | 可检查结果 |
|---|---|---|
| **M0 骨架**（约 3 天） | Rust workspace + Tauri 2 + Vue 3；CI 矩阵（mac arm64/x64、win x64）只编译空壳；四语种骨架 | 三个平台 CI 都能产出可启动的空窗口 |
| **M1 引擎可移植**（约 1 周） | C++ 引擎去 GCD（换 std::thread 池）、去 CoreFoundation（Unicode 小写用 ICU4X 或自带表）；在 Linux/Windows/Mac 上跑通原 11,962 个测试 | 三平台 `core-tests` 全绿 |
| **M2 FFI 与 Mac 扫描** （约 1 周） | cxx 桥接；Mac 扫描/监控迁入 jme-platform；Rust CLI `jme search ...` | Mac 上 CLI 搜索结果与 1.9 一致（对照测试） |
| **M3 界面重写**（约 2 周） | Vue 版界面：顶栏标签、QUICK、起始页、结果行、内容行、色卡、键盘操作、设置页（扩展名清单等全部可在界面里改）；托盘/菜单栏常驻、全局快捷键、开机自启、关闭即隐藏 | Mac 版 2.0 预览可日常替代 1.9；真实截图入 README |
| **M4 Windows 扫描**（约 2 周） | MFT 枚举 + USN 增量 + 服务 + 命名管道；无服务降级模式；资源管理器显示/预览 | Windows 上核心链路 1–5 全部通过 |
| **M5 内容搜索 + MCP**（约 1 周） | 行级 grep 移入 Rust；MCP（rmcp）；内容索引内存优化（去掉每文件三元组副本） | `grep:` 两平台一致；MCP 在 Claude Code 中可用 |
| **M6 发布与升级**（约 1 周） | Tauri updater（签名目录）、DMG/NSIS/MSI、Windows 服务随安装器升级、1.9 → 2.0 迁移说明 | 链路 6 在两平台通过；Release 附件齐全 |

合计约 9–10 周（单人 + Claude 协作节奏）。任何阶段都可以单独发布预览版。

## 5. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| C++ 去平台依赖后性能下降 | 搜索变慢 | M1 前后跑同一套基准，回退线 10% |
| Windows MFT 需要管理员，用户拒绝安装服务 | 只能用慢速遍历 | 降级模式可用但明确提示；文档说明服务只读 |
| 非 NTFS 盘（exFAT、网络盘） | 无 MFT/USN | 走遍历 + 目录监控，界面标注「慢速盘」 |
| 代码签名证书（Apple Developer ID、Windows Authenticode）暂缺 | 安装时有系统警告 | 先发未签名预览版并写清绕过步骤；证书到位后补签，不影响架构 |
| Tauri WebView 首屏和输入延迟 | 手感不如原生 | 结果列表虚拟滚动；查询在 Rust 端节流；M3 设输入到渲染 < 16 ms 的门槛 |
| 1.9 用户迁移 | 需要重建索引 | 2.0 首次启动自动重建；1.9 不内置升级器，需手动安装一次 |

## 6. 署名与许可

- 继承原项目 MIT 许可和原作者 joshua-wu 的署名；2.0 新增部分署名 M&J Group（473276@qq.com）。
- 借鉴 fsearch 的思路不复制其代码；如引入第三方 crate，在 `THIRD_PARTY.md` 记录许可证。

## 7. 需要你拍板的事

1. ~~界面语言~~：已定——四种语言，默认跟随系统（见 1.11）。
2. **Windows 服务**：接受「安装时请求一次管理员权限、换来秒级索引」吗？
3. **仓库**：继续在本仓库的 `v2` 分支开发，还是新建独立仓库（如 `JMacEverything2` / 更名为跨平台的新名字）？
