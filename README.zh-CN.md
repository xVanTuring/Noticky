# Noticky

[English](./README.md) · 简体中文

> macOS 原生便签应用 — 菜单栏常驻、全局快捷键速记、多窗浮窗、Markdown、iCloud 同步。

Noticky 是一款 macOS 15+ 原生便签 / 速记工具。AppKit 外壳 + SwiftUI 内容
（`NSHostingController` 桥接），Core Data 持久化，可选 `NSPersistentCloudKitContainer`
跨设备同步。无 Dock 图标，常驻菜单栏（`LSUIElement`）。

<p align="center">
  <img src="docs/screenshots/menutray-open.png" width="340" alt="菜单栏托盘">
  &nbsp;&nbsp;
  <img src="docs/screenshots/stack.png" width="255" alt="浮窗便签">
</p>
<p align="center">
  <img src="docs/screenshots/manage-all-note.png" width="760" alt="Manager 窗口">
</p>

---

## 项目特点

### 浮窗便签
- 6 色调色板（黄 / 粉 / 蓝 / 绿 / 紫 / 灰），新便签默认色可在 Settings 配置。
- 三种排版模式（菜单栏 → Layout）：
  - **Free** 自由摆放
  - **Stack** 层叠 cascade，选中谁谁滑到最下方完整可见
  - **Tile** 平铺，拖动后按位置自动重排
- 「Pin」属性兼任「下次启动自动恢复」标记，关 App 不丢现场。
- 每个便签的窗口位置 / 尺寸独立持久化（`Note.frameX/Y/W/H`）。
- `Float on top`（菜单栏切换）让所有浮窗常驻最上层。
- 双击标题栏可折叠（可在 Settings 关）。
- 失焦半透明（可在 Settings 关）。

<p align="center">
  <img src="docs/screenshots/stack-animation.gif" width="300" alt="Stack 层叠布局"><br>
  <sub><b>Stack</b> — 选中谁谁滑到最下方完整可见</sub>
</p>
<p align="center">
  <img src="docs/screenshots/tile-animation.gif" width="840" alt="Tile 平铺布局"><br>
  <sub><b>Tile</b> — 自动平铺成网格，拖动即可重排</sub>
</p>

### 编辑器
- 纯文本（`NSTextView` 包装的 `PlainTextEditor`）和 Markdown 双模式。
- Markdown 走 [gonzalezreal/Textual](https://github.com/gonzalezreal/textual) 渲染，
  支持「渲染态 ↔ 编辑态」一键切换。
- 全局字号可调（12–24，实时同步到所有打开窗口）。
- 新建便签可选直接进编辑态或先停在渲染态。

### 全局快捷键速记（Quick Capture）
- 默认 `⌘⇧N`，可在 Settings → Shortcuts 自定义
  （基于 [sindresorhus/KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)）。
- 三种取材模式：
  - **AX + 白名单**：通过辅助功能 API 抓 frontmost App 的选中文本（需授权 + 不能沙盒化）。
  - **仅剪贴板**：拉起前不读 AX，直接把当前剪贴板内容塞进输入框。
  - **关闭**：纯空白快速记一笔。
- 白名单按 bundle ID 配置，AX 仅对白名单内 App 启用。

### 中央管理窗口（Manager）
- `NSOutlineView` 原生侧栏：All Notes / 自定义分组 / Ungrouped / Trash。
- 拖拽便签到分组（多选拖动跟随 selection）。
- 系统 `.searchable` 全文搜索。
- 分组重命名 / 新建 / 右键移动。
- 多选批量改色 / 批量 Pin/Unpin / 批量打开为浮窗（≤ 8 防糊屏）。

### 回收站
- 删除走软删除，进 Trash。
- 启动时自动清理超过 N 天的旧 trash（默认 30 天，Settings 可调 7–365）。
- 对齐系统 Notes / Mail 行为。

### 导入 / 导出 / 备份
- 单条 Markdown export（`.md`）或多条到目录批量 export。
- File menu 提供整库 backup / restore，单文件 JSON 格式。
- Restore 按 UUID 去重，**不覆盖**当前数据。

### iCloud 同步（可选）
- Settings → iCloud Sync 开关，默认关闭；首次开启需重启。
- 启用后走 `NSPersistentCloudKitContainer`，跨 Mac 实时同步。
- 已验证中国区 iCloud（`gateway.icloud.com.cn`）。
- 内置 schema 部署助手（DEBUG）：自动 push schema 到 CloudKit Development，
  生产环境 promote 仍需在 [CloudKit Console](https://icloud.developer.apple.com)
  手动部署 — 详见 [CLAUDE.md](./CLAUDE.md#schema--cloudkit-deployment-workflow)。
- 开 DEBUG 还可跑 `Run migration self-test` 验证 lightweight migration 可行。

### 多语言
- 内置中文 / 英文，跟随系统或在 Settings → General 强制指定。

### 数据安全
- Core Data 启用 lightweight migration（`shouldInferMappingModelAutomatically`）。
- 加载失败时**不再静默销毁** — 会把 sqlite + shm + wal 三件套备份到
  `~/Desktop/Noticky-Recovery-{ts}/` 后弹出 NSAlert 再退出。
- 模型版本化：`Persistence/Schema/SchemaV{N}.swift` + `CoreDataSchema` 注册表，
  `SchemaVersion.current` 指向当前版本。

---

## 系统要求

- macOS 15.0+
- 自行构建：Xcode 16+、Swift 5.0+、[xcodegen](https://github.com/yonaskolb/XcodeGen)
- 发布：Apple Developer 账号（团队 ID `T8F5T6HKG8`）+ Developer ID 证书

---

## 项目结构

```
Sources/Noticky/
├─ App/                  # NotickyApp（自定义 main）、AppDelegate、MenuBarController
├─ Persistence/          # PersistenceController、Note、NoteGroup
│  └─ Schema/            # 版本化 Core Data schema
├─ Features/
│  ├─ Floating/          # 浮窗便签（FloatingNoteWindow、StickyPalette）
│  ├─ Notes/             # 编辑器（PlainTextEditor、MarkdownNoteEditor）
│  ├─ Capture/           # 全局快捷键速记 + AX/剪贴板取材
│  ├─ Manager/           # 中央管理窗口（NSOutlineView 侧栏）
│  ├─ Settings/          # 设置窗口（NSTabViewController + SwiftUI tabs）
│  └─ IO/                # 导入 / 导出 / 备份
└─ Resources/            # Info.plist、entitlements、AppIcon
scripts/                 # release.sh、ExportOptions.plist
project.yml              # xcodegen 项目定义
```

更深入的架构讲解（为什么 AppKit 外壳而不是 SwiftUI App、为什么不用 `.xcdatamodeld`、
重复踩过的坑等）见 [CLAUDE.md](./CLAUDE.md)。

---

## 构建与运行（开发）

```sh
# 1. 生成 Noticky.xcodeproj（.xcodeproj 不入库，每次拉代码或加文件后都要跑）
xcodegen

# 2. Debug 构建
xcodebuild -project Noticky.xcodeproj -scheme Noticky -configuration Debug build

# 3. 直接跑产物（保留 stderr，方便调菜单栏 App）
APP=$(find ~/Library/Developer/Xcode/DerivedData \
    -path "*Noticky*/Build/Products/Debug/Noticky.app/Contents/MacOS/Noticky" \
    | head -1)
pkill -f "Noticky.app/Contents/MacOS/Noticky" 2>/dev/null
"$APP" > /tmp/noticky.log 2>&1 &
disown

# 4. 退出（走 applicationShouldTerminate，会持久化窗口现场）
osascript -e 'tell application "Noticky" to quit'
```

直接在 Xcode 里 `⌘R` 也行，但 Debug 时建议走命令行 — 方便 tail `/tmp/noticky.log`，
菜单栏 App 在 Console.app / `log show` 里 NSLog 抓不到。

---

## 打包发布

`scripts/release.sh` 是一键脚本：archive → exportArchive (Developer ID 重签) →
公证 .app → staple → 打 DMG → 公证 DMG → staple。产物到 `dist/v<VERSION>/`：

```
dist/v1.0.0/
├─ Noticky.app
├─ Noticky-1.0.0.zip
└─ Noticky-1.0.0.dmg
```

脚本是幂等的，重跑安全。整个链路 5–15 分钟（公证排队为主）。

### 一次性配置（每台机器）

1. **Developer ID Application 证书** 在 keychain 里
   （团队 `T8F5T6HKG8` — Shenzhen Zhiqishidai Technology）：

   ```sh
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

   缺失则到 Xcode → Settings → Accounts → Manage Certificates →
   `+` → Developer ID Application 安装，或让 Admin 颁发并发 `.p12` 给你。

2. **Developer ID 配置文件**，名字必须是 `Noticky Developer ID`
   （`scripts/ExportOptions.plist` 按名字 lookup）。

   到 https://developer.apple.com/account/resources/profiles/add 创建：
   Distribution → Developer ID → App ID `tech.xvanturing.Noticky` →
   选 Developer ID Application 证书 → 命名 `Noticky Developer ID` →
   Generate → Download → 双击安装。

   > 因为 entitlements 里有 iCloud + Push Notifications，Xcode 强制要 profile，
   > 哪怕是 Developer ID 直接分发也跑不掉。

3. **notarytool 凭据** 存进 keychain。先到 https://appleid.apple.com →
   Sign-In and Security → App-Specific Passwords 生成专用密码：

   ```sh
   xcrun notarytool store-credentials "noticky-notary" \
     --apple-id  "<your-apple-id>" \
     --team-id   "T8F5T6HKG8" \
     --password  "<app-specific-password>"
   ```

   脚本默认找 keychain profile `noticky-notary`，可用
   `NOTARY_PROFILE=foo ./scripts/release.sh` 覆盖。

### 单次发布

```sh
./scripts/release.sh
```

跑完后：

```sh
# 挂 DMG → 拖到 /Applications → 首次右键 Open
open dist/v1.0.0/Noticky-1.0.0.dmg

# 验证版本 / 快捷键 / Settings 能开
# 没问题就打 tag 推上游
git tag v1.0.0
git push --tags
# 然后把 Noticky-1.0.0.dmg 上传到 GitHub Releases 或自有渠道
```

### 修改版本号

版本号读自 `project.yml` 的 `CFBundleShortVersionString`。改完跑 `xcodegen` 重新生成
工程文件，再走 `release.sh`。

### CloudKit schema 发布（独立流程）

⚠️ Release build 的 entitlement 是 `aps-environment=production`，老用户安装新版后
直接命中 CloudKit **Production** 环境。如果新版本动了 schema（`SchemaVersion.current`
升号），**必须先**把 schema 部署到 Production，否则同步会静默丢字段。

完整流程见 [CLAUDE.md → Schema → CloudKit deployment workflow](./CLAUDE.md#schema--cloudkit-deployment-workflow)。
关键步骤：

1. DEBUG build → Settings → iCloud Sync → `Run migration self-test` 验证。
2. DEBUG build → Settings → iCloud Sync → `Initialize Cloud schema (Development)`。
3. 手动到 [CloudKit Console](https://icloud.developer.apple.com) 把 schema 从
   Development promote 到 Production。
4. 再发版。

⚠️ CloudKit production schema 是 **append-only** — 一旦部署就拿不掉，加新字段只进不出。

---

## 致谢

- [gonzalezreal/Textual](https://github.com/gonzalezreal/textual) — Markdown 渲染。
- [sindresorhus/KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) —
  全局快捷键的录制与持久化。

---

## License

© 2026 xVanTuring.
