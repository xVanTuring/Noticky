import SwiftUI
import AppKit
import ServiceManagement
import KeyboardShortcuts

/// 偏好的 UserDefaults key 集中在这里,避免散落各处拼错。
enum SettingsKey {
    static let fadeWhenInactive = "Noticky.fadeWhenInactive"
    static let noteSort = "Noticky.noteSort"
    static let captureMode = "Noticky.captureMode"
    /// 换行分隔的 bundle ID 列表。换行而非 JSON,UserDefaults plist 里直接可读,
    /// SwiftUI 用一个 TextEditor 就能编辑,没必要为此引入 codable 中间层。
    static let clipboardWhitelist = "Noticky.clipboardWhitelist"
    static let doubleClickTitleToCollapse = "Noticky.doubleClickTitleToCollapse"
    static let appLanguage = "Noticky.appLanguage"

    // 新建便签默认行为
    static let defaultColorIndex = "Noticky.defaultColorIndex"   // Int (0..5,对应 StickyPalette)
    static let noteFontSize = "Noticky.noteFontSize"             // Int (12..24,编辑态 NSTextView 字号)
    static let defaultNoteSize = "Noticky.defaultNoteSize"       // String raw,DefaultNoteSize enum
    static let startInEditMode = "Noticky.startInEditMode"       // Bool,新便签直接进编辑态(默认 false:渲染态)

    /// iCloud 同步开关。改这个值后必须重启 Noticky —— PersistenceController
    /// 在 init 时一次性读 + 决定走 NSPersistentContainer 还是
    /// NSPersistentCloudKitContainer,运行时无法热切换。
    static let iCloudSyncEnabled = "Noticky.iCloudSyncEnabled"   // Bool

    /// 回收站保留天数。超过这个天数的 trashed 笔记会在启动时被
    /// `purgeExpiredTrash` 真删。范围 7-365,未设默认 30(对齐 Notes/Mail)。
    static let trashRetentionDays = "Noticky.trashRetentionDays" // Int

    /// 上次成功推到 CloudKit Development 环境的 schema 版本号(SchemaVersion.rawValue)。
    /// **仅 DEBUG 用** —— 给开发者在 Settings → iCloud Sync 里看"本机推过的版本
    /// vs 当前 SchemaVersion.current"是否一致,提醒发布前要重新 push schema
    /// 并到 CloudKit Console 把 Dev → Prod 部署一遍。终端用户 release build 看不到这块。
    static let cloudKitDeployedSchemaVersion = "Noticky.cloudKitDeployedSchemaVersion" // String
}

/// 回收站保留天数的取值范围 + 默认值。集中在这里,SettingsView Stepper 和
/// `purgeExpiredTrash` 都引用,避免散落。
enum TrashRetention {
    static let defaultDays = 30
    static let range = 7...365
    /// UserDefaults 没设时返回默认值;`.integer(forKey:)` 默认会返回 0,要显式
    /// 拦截一下。
    static var current: Int {
        let raw = UserDefaults.standard.integer(forKey: SettingsKey.trashRetentionDays)
        guard range.contains(raw) else { return defaultDays }
        return raw
    }
}

/// 新建便签时浮窗的默认尺寸预设。Settings 用 picker 选,FloatingNoteWindowController.show
/// 在 note 没有 savedFrame 时用这个值作为初始 contentSize。
enum DefaultNoteSize: String, CaseIterable, Identifiable {
    case small, medium, large

    var id: String { rawValue }
    var size: NSSize {
        switch self {
        case .small:  return NSSize(width: 240, height: 240)
        case .medium: return NSSize(width: 280, height: 280)
        case .large:  return NSSize(width: 360, height: 360)
        }
    }
    var label: String {
        switch self {
        case .small:  return L.t(.noteSizeSmall)
        case .medium: return L.t(.noteSizeMedium)
        case .large:  return L.t(.noteSizeLarge)
        }
    }
    static func from(_ raw: String) -> DefaultNoteSize {
        DefaultNoteSize(rawValue: raw) ?? .medium
    }
}

/// ⌘⇧N 抓选中文本的策略。
/// - `axWithWhitelist`:默认走 Accessibility;白名单里的 bundle ID 改走剪贴板合成。
/// - `clipboardOnly`:统统合成 ⌘C,不碰 AX(也不需要辅助功能权限)。
/// - `disabled`:不抓,⌘⇧N 直接开空 capture。
enum CaptureMode: String, CaseIterable, Identifiable {
    case axWithWhitelist
    case clipboardOnly
    case disabled

    var id: String { rawValue }
    var label: String {
        switch self {
        case .axWithWhitelist: return L.t(.captureModeAxWhitelist)
        case .clipboardOnly:   return L.t(.captureModeClipboardOnly)
        case .disabled:        return L.t(.captureModeDisabled)
        }
    }

    static func from(_ raw: String) -> CaptureMode {
        CaptureMode(rawValue: raw) ?? .axWithWhitelist
    }
}

/// 解析 / 写回 `SettingsKey.clipboardWhitelist`(换行分隔的 bundle ID)。
/// trim 空行 + whitespace,大小写敏感(macOS bundle ID 实际就是大小写敏感)。
enum ClipboardWhitelist {
    static func parse(_ raw: String) -> [String] {
        raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func contains(_ raw: String, bundleID: String) -> Bool {
        parse(raw).contains(bundleID)
    }
}

/// 笔记列表的排序方式 —— 影响 ManagerView 和菜单栏。
enum NoteSort: String, CaseIterable, Identifiable {
    case dateEdited
    case dateCreated
    case title

    var id: String { rawValue }
    var label: String {
        switch self {
        case .dateEdited: return L.t(.sortDateEdited)
        case .dateCreated: return L.t(.sortDateCreated)
        case .title:       return L.t(.sortTitle)
        }
    }

    static func from(_ raw: String) -> NoteSort {
        NoteSort(rawValue: raw) ?? .dateEdited
    }
}

// MARK: - Root ----------------------------------------------------------------

/// 设置窗口根视图。SwiftUI Settings scene + TabView,系统会渲染成 macOS 原生
/// 「图标 toolbar + 切 tab 时窗口高度动画」样式 —— 跟 System Settings.app 一致。
/// 每个 tab 视图自己 `.frame(width:480, height:X)`,SwiftUI 用这个驱动窗口尺寸。
struct SettingsView: View {
    @ObservedObject private var loc = LocalizationManager.shared

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label(L.t(.tabGeneral), systemImage: "gearshape") }
            CaptureTab()
                .tabItem { Label(L.t(.tabCapture), systemImage: "doc.on.clipboard") }
            ShortcutsTab()
                .tabItem { Label(L.t(.tabShortcuts), systemImage: "keyboard") }
            PermissionsTab()
                .tabItem { Label(L.t(.tabPermissions), systemImage: "lock.shield") }
            NotesTab()
                .tabItem { Label(L.t(.tabNotes), systemImage: "note.text") }
            ICloudTab()
                .tabItem { Label(L.t(.tabICloud), systemImage: "icloud") }
        }
    }
}

// MARK: - General -------------------------------------------------------------

struct GeneralTab: View {
    @State private var launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    @AppStorage(SettingsKey.noteSort) private var noteSortRaw: String = NoteSort.dateEdited.rawValue
    @AppStorage(SettingsKey.fadeWhenInactive) private var fadeWhenInactive: Bool = true
    @AppStorage(SettingsKey.doubleClickTitleToCollapse) private var doubleClickToCollapse: Bool = false
    @AppStorage(SettingsKey.trashRetentionDays) private var trashRetentionDays: Int = TrashRetention.defaultDays
    @ObservedObject private var loc = LocalizationManager.shared

    var body: some View {
        Form {
            Toggle(L.t(.generalLaunchAtLogin), isOn: Binding(
                get: { launchAtLoginEnabled },
                set: { setLaunchAtLogin($0) }
            ))

            Picker(L.t(.generalSortBy), selection: $noteSortRaw) {
                ForEach(NoteSort.allCases) { sort in
                    Text(sort.label).tag(sort.rawValue)
                }
            }
            .pickerStyle(.menu)

            // 语言:跟随系统 / English / 简体中文。setLanguage 是 @Published,
            // 切换瞬间所有订阅 LocalizationManager 的 view 重渲染,无需重启。
            Picker(L.t(.generalLanguage), selection: Binding(
                get: { loc.current },
                set: { loc.setLanguage($0) }
            )) {
                Text(L.t(.langFollowSystem)).tag(AppLanguage.system)
                Text(L.t(.langEnglish)).tag(AppLanguage.english)
                Text(L.t(.langChinese)).tag(AppLanguage.chinese)
            }
            .pickerStyle(.menu)

            Toggle(isOn: $fadeWhenInactive) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.t(.generalFadeWhenInactive))
                    Text(L.t(.generalFadeWhenInactiveDesc))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle(isOn: $doubleClickToCollapse) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.t(.generalDoubleClickCollapse))
                    Text(L.t(.generalDoubleClickCollapseDesc))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // 回收站保留天数。Stepper bind 到 @AppStorage,改一下立即落 UserDefaults,
            // 下次启动 purgeExpiredTrash 用新值。当前已在回收站里超期的下次启动才清。
            Stepper(value: Binding(
                get: { trashRetentionDays > 0 ? trashRetentionDays : TrashRetention.defaultDays },
                set: { trashRetentionDays = $0 }
            ), in: TrashRetention.range, step: 1) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.t(.generalTrashRetention, trashRetentionDays > 0 ? trashRetentionDays : TrashRetention.defaultDays))
                    Text(L.t(.generalTrashRetentionDesc))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 480, height: 400)
    }

    /// SMAppService.mainApp 要求 App 已正确签名 + 在 /Applications 之类标准位置。
    /// Debug 构建可能注册失败 —— catch 之后用 service.status 反查真实状态,UI 跟着走。
    private func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled, service.status != .enabled {
                try service.register()
            } else if !enabled, service.status == .enabled {
                try service.unregister()
            }
        } catch {
            NSLog("Noticky: launch at login toggle failed: %@", "\(error)")
        }
        launchAtLoginEnabled = service.status == .enabled
    }
}

// MARK: - Capture -------------------------------------------------------------

/// ⌘⇧N 抓取策略 + 剪贴板白名单编辑。三选一模式 + 一个换行分隔的 bundle ID 列表
/// (列表只在「AX + 白名单」模式下展示,纯剪贴板/关闭模式下白名单无意义)。
struct CaptureTab: View {
    @AppStorage(SettingsKey.captureMode) private var captureModeRaw: String = CaptureMode.axWithWhitelist.rawValue
    @AppStorage(SettingsKey.clipboardWhitelist) private var whitelistRaw: String = ""
    @ObservedObject private var loc = LocalizationManager.shared

    private var mode: CaptureMode { CaptureMode.from(captureModeRaw) }

    var body: some View {
        Form {
            Section {
                Picker(L.t(.captureMethod), selection: $captureModeRaw) {
                    ForEach(CaptureMode.allCases) { m in
                        Text(m.label).tag(m.rawValue)
                    }
                }
                .pickerStyle(.menu)
            } footer: {
                Text(modeFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if mode == .axWithWhitelist {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L.t(.captureWhitelistTitle))
                            .font(.callout.weight(.medium))
                        TextEditor(text: $whitelistRaw)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 120)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                            )
                        Text(L.t(.captureWhitelistHint))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 480, height: mode == .axWithWhitelist ? 380 : 180)
    }

    private var modeFooter: String {
        switch mode {
        case .axWithWhitelist: return L.t(.captureFooterAxWhitelist)
        case .clipboardOnly:   return L.t(.captureFooterClipboardOnly)
        case .disabled:        return L.t(.captureFooterDisabled)
        }
    }
}

// MARK: - Shortcuts -----------------------------------------------------------

struct ShortcutsTab: View {
    @ObservedObject private var loc = LocalizationManager.shared

    var body: some View {
        Form {
            // 可自定义。库自己读写 UserDefaults,改完立刻 re-register 全局热键 ——
            // AppDelegate 那侧 onKeyDown 不需要重新订阅。
            Section(L.t(.shortcutsCustomizable)) {
                HStack {
                    Text(L.t(.shortcutQuickCapture))
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .quickCapture)
                }
            }

            // menu / window 派发的快捷键。短期内不打算让用户改 —— 它们是 macOS
            // 标准约定,改了反而增加困惑。后续如果有需求再单独迁这一组。
            Section(L.t(.shortcutsSystem)) {
                row(action: L.t(.shortcutManageNotes),   shortcut: "⌘⇧0")
                row(action: L.t(.shortcutOpenSettings),  shortcut: "⌘,")
                row(action: L.t(.shortcutNewNote),       shortcut: "⌘N")
                row(action: L.t(.shortcutCloseWindow),   shortcut: "⌘W")
                row(action: L.t(.shortcutDeleteNote),    shortcut: "⌘D")
                row(action: L.t(.shortcutQuit),          shortcut: "⌘Q")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 480, height: 420)
    }

    private func row(action: String, shortcut: String) -> some View {
        HStack {
            Text(action)
            Spacer()
            Text(shortcut)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Permissions ---------------------------------------------------------

/// 系统授权管理。目前只有 Accessibility(决定 ⌘⇧N 能否抓选中文字)。
/// 状态用 `AXIsProcessTrusted()` 实时取,**不缓存** —— 用户去系统设置勾掉,
/// 切回这窗口立刻能看到红色未授权状态。`didBecomeActive` 通知触发重读。
struct PermissionsTab: View {
    @State private var accessibilityGranted: Bool = SelectionFetcher.isTrusted
    @ObservedObject private var loc = LocalizationManager.shared

    var body: some View {
        Form {
            Section {
                permissionRow(
                    title: L.t(.permissionAccessibilityTitle),
                    description: L.t(.permissionAccessibilityDesc),
                    granted: accessibilityGranted,
                    openSettings: SelectionFetcher.requestAndOpenAccessibilitySettings
                )
            } footer: {
                Text(L.t(.permissionFooter))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 480, height: 240)
        // 用户去系统设置勾完授权切回 Noticky 时刷新一次。AX 状态进程内是
        // 实时生效的,只是 SwiftUI 的 @State 不会自动复算 —— 必须显式 poke。
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            accessibilityGranted = SelectionFetcher.isTrusted
        }
        .onAppear {
            accessibilityGranted = SelectionFetcher.isTrusted
        }
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        description: String,
        granted: Bool,
        openSettings: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
                .font(.title2)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(granted ? L.t(.permissionGranted) : L.t(.permissionNotGranted))
                    .font(.caption)
                    .foregroundStyle(granted ? .green : .orange)
                    .padding(.top, 2)
            }

            Spacer(minLength: 8)

            Button(granted ? L.t(.permissionOpen) : L.t(.permissionOpenSettings)) {
                openSettings()
            }
            .controlSize(.regular)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Notes ---------------------------------------------------------------

struct NotesTab: View {
    @AppStorage(SettingsKey.defaultColorIndex) private var defaultColorIndex: Int = 0
    @AppStorage(SettingsKey.noteFontSize) private var noteFontSize: Int = 14
    @AppStorage(SettingsKey.defaultNoteSize) private var defaultNoteSizeRaw: String = DefaultNoteSize.medium.rawValue
    @AppStorage(SettingsKey.startInEditMode) private var startInEditMode: Bool = false
    @ObservedObject private var loc = LocalizationManager.shared

    var body: some View {
        Form {
            // 颜色:6 圆点 HStack。点中带 accent ring,跟浮窗 ⋯ 菜单的颜色 picker 一致。
            LabeledContent(L.t(.notesDefaultColor)) {
                HStack(spacing: 8) {
                    ForEach(StickyPalette.allCases) { palette in
                        Button {
                            defaultColorIndex = Int(palette.rawValue)
                        } label: {
                            Circle()
                                .fill(palette.color)
                                .frame(width: 22, height: 22)
                                .overlay(
                                    Circle().stroke(
                                        defaultColorIndex == Int(palette.rawValue)
                                            ? Color.accentColor
                                            : Color.black.opacity(0.15),
                                        lineWidth: defaultColorIndex == Int(palette.rawValue) ? 2 : 1
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // 字号:Stepper 12..24。新建 / 已打开的编辑器都会通过 PlainTextEditor
            // 的 @AppStorage + updateNSView 同步刷新。
            Stepper(value: $noteFontSize, in: 12...24, step: 1) {
                LabeledContent(L.t(.notesFontSize)) {
                    Text("\(noteFontSize) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            Picker(L.t(.notesDefaultSize), selection: $defaultNoteSizeRaw) {
                ForEach(DefaultNoteSize.allCases) { size in
                    Text(size.label).tag(size.rawValue)
                }
            }
            .pickerStyle(.menu)

            Toggle(isOn: $startInEditMode) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.t(.notesStartInEditMode))
                    Text(L.t(.notesStartInEditModeDesc))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 480, height: 320)
    }
}

// MARK: - iCloud --------------------------------------------------------------

/// iCloud Sync 偏好。结构:
///   1. 顶部 Toggle 开关 + 说明 + 重启提示(toggle 改了但还没重启时显示)。
///   2. 状态区(只在已经按开启 + 进程当前实际是 CloudKit 模式时显示):
///      账户状态 / Activity / 上次同步 / Container / Refresh 按钮。
///   3. 没启用时显示一段 hint。
///
/// "开关 toggle 状态" 与 "进程当前是否是 CloudKit 模式" 是两个独立信号:用户刚
/// 勾上但没重启,前者 true、后者 false —— 这种情况下只显示重启提示,状态区不渲染。
struct ICloudTab: View {
    @ObservedObject private var loc = LocalizationManager.shared
    @ObservedObject private var monitor = CloudKitSyncMonitor.shared
    @AppStorage(SettingsKey.iCloudSyncEnabled) private var enabledPref: Bool = false
    @AppStorage(SettingsKey.cloudKitDeployedSchemaVersion) private var deployedSchemaVersion: String = ""
    @State private var schemaInitMessage: String?
    @State private var schemaInitFailed: Bool = false
    @State private var migrationTestMessage: String?
    @State private var migrationTestFailed: Bool = false
    @State private var migrationTestRunning: Bool = false

    /// 进程启动时 PersistenceController 决定的 mode。这个值不会随 toggle 改变,
    /// 与 enabledPref 不一致时说明用户改了开关但还没重启。
    private var actuallyRunningCloudKit: Bool {
        PersistenceController.shared.cloudKitEnabled
    }

    var body: some View {
        Form {
            Section {
                Toggle(L.t(.iCloudEnable), isOn: $enabledPref)
            } footer: {
                Text(L.t(.iCloudEnableDesc))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if enabledPref != actuallyRunningCloudKit {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L.t(.iCloudRestartRequired)).fontWeight(.medium)
                            Text(L.t(.iCloudRestartHint))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "arrow.clockwise.circle")
                            .foregroundStyle(.orange)
                    }
                }
            }

            if actuallyRunningCloudKit {
                Section {
                    LabeledContent(L.t(.iCloudAccountStatusLabel)) {
                        HStack(spacing: 6) {
                            Image(systemName: accountIcon)
                                .foregroundStyle(accountTint)
                            Text(monitor.accountStatus.localizedLabel)
                                .foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent(L.t(.iCloudActivityLabel)) {
                        Text(activitySummary)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent(L.t(.iCloudLastSyncLabel)) {
                        Text(lastSyncText)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent(L.t(.iCloudContainerLabel)) {
                        Text(CloudKitConfig.containerIdentifier)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    HStack {
                        Spacer()
                        Button(L.t(.iCloudRefresh)) {
                            monitor.refreshAccountStatus()
                        }
                        if monitor.accountStatus != .available {
                            Button(L.t(.iCloudOpenAccountSettings)) {
                                openIcloudSettings()
                            }
                        }
                    }
                } footer: {
                    Text(L.t(.iCloudFooter))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                #if DEBUG
                schemaDebugSection
                migrationTesterSection
                #endif
            } else if !enabledPref {
                Section {
                    Label(L.t(.iCloudDisabledHint), systemImage: "icloud.slash")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: dynamicHeight)
    }

    /// 内容多寡浮动:开关+只读 hint 时矮一些,启用+状态区时高一些。
    /// DEBUG 构建时多两段(schema 跟踪 + migration tester)。
    private var dynamicHeight: CGFloat {
        #if DEBUG
        if actuallyRunningCloudKit { return 800 }
        #else
        if actuallyRunningCloudKit { return 460 }
        #endif
        if enabledPref != actuallyRunningCloudKit { return 280 }
        return 220
    }

    #if DEBUG
    /// CloudKit Development 环境的 schema 推送 + 部署版本跟踪。
    /// 每次 SchemaVersion.current 升级后必须重跑,否则新字段在云上不存在,
    /// sync 会忽略它们。Push 成功后还要去 CloudKit Console 把 Dev 部署到 Production。
    @ViewBuilder
    private var schemaDebugSection: some View {
        Section {
            LabeledContent(L.t(.iCloudSchemaCurrent)) {
                Text(SchemaVersion.current.rawValue)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            LabeledContent(L.t(.iCloudSchemaDeployed)) {
                Text(deployedSchemaVersion.isEmpty
                     ? L.t(.iCloudSchemaDeployedNever)
                     : deployedSchemaVersion)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(deployedSchemaVersion == SchemaVersion.current.rawValue
                                     ? Color.secondary : Color.orange)
            }
            if !deployedSchemaVersion.isEmpty,
               deployedSchemaVersion != SchemaVersion.current.rawValue {
                Label {
                    Text(L.t(.iCloudSchemaNeedsRedeploy))
                        .font(.callout)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            Button(L.t(.iCloudInitSchema)) {
                initializeSchema()
            }
            if let msg = schemaInitMessage {
                Label(msg, systemImage: schemaInitFailed ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(schemaInitFailed ? Color.red : Color.green)
                    .font(.callout)
            }
        } header: {
            Text(L.t(.iCloudSchemaSection))
        } footer: {
            Text(L.t(.iCloudInitSchemaHint))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// Lightweight migration 端到端自检。每次 bumping SchemaVersion.current 之前
    /// 跑一次确认升级链路能跑通(SchemaMigrationTester 会拿合成的旧版 store 走
    /// 一遍真实迁移)。
    @ViewBuilder
    private var migrationTesterSection: some View {
        Section {
            Button(L.t(.iCloudMigrationTest)) {
                runMigrationTest()
            }
            .disabled(migrationTestRunning)
            if migrationTestRunning {
                Label(L.t(.iCloudMigrationTestRunning), systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else if let msg = migrationTestMessage {
                Label(msg, systemImage: migrationTestFailed ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(migrationTestFailed ? Color.red : Color.green)
                    .font(.callout)
            }
        } footer: {
            Text(L.t(.iCloudMigrationTestHint))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
    #endif

    /// 后台 thread 推 schema —— 这个调用是同步 + 网络阻塞,主线程跑会卡 UI。
    /// 成功后 Cloud Console 里能看到 record types(`CD_Note`、`CD_NoteGroup`)+
    /// 默认 zone (`com.apple.coredata.cloudkit.zone`) 出现。
    /// 成功后把 SchemaVersion.current.rawValue 写进 UserDefaults,
    /// 下次进 Settings 能看到 "deployed=X | current=Y" 的对比。
    private func initializeSchema() {
        schemaInitMessage = nil
        schemaInitFailed = false
        let pushedVersion = SchemaVersion.current.rawValue
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try PersistenceController.shared.initializeCloudKitSchema()
                DispatchQueue.main.async {
                    schemaInitMessage = L.t(.iCloudInitSchemaSuccess)
                    schemaInitFailed = false
                    deployedSchemaVersion = pushedVersion
                    monitor.refreshAccountStatus()
                }
            } catch {
                let desc = (error as NSError).localizedDescription
                DispatchQueue.main.async {
                    schemaInitMessage = L.t(.iCloudInitSchemaFailed, desc)
                    schemaInitFailed = true
                }
            }
        }
    }

    /// 同步执行 SchemaMigrationTester.run() —— Core Data 操作放到后台 queue,
    /// 防止短暂阻塞 UI(实际开销 < 1s,但保险起见还是不在 main 上跑)。
    private func runMigrationTest() {
        migrationTestRunning = true
        migrationTestMessage = nil
        migrationTestFailed = false
        #if DEBUG
        DispatchQueue.global(qos: .userInitiated).async {
            let result = SchemaMigrationTester.run()
            DispatchQueue.main.async {
                migrationTestRunning = false
                switch result {
                case .passed(let msg):
                    migrationTestMessage = L.t(.iCloudMigrationTestPass, msg)
                    migrationTestFailed = false
                case .failed(let msg):
                    migrationTestMessage = L.t(.iCloudMigrationTestFail, msg)
                    migrationTestFailed = true
                }
            }
        }
        #endif
    }

    private var accountIcon: String {
        switch monitor.accountStatus {
        case .available:               return "checkmark.icloud"
        case .noAccount, .restricted:  return "icloud.slash"
        default:                       return "icloud"
        }
    }

    private var accountTint: Color {
        switch monitor.accountStatus {
        case .available:                                   return .green
        case .noAccount, .restricted, .temporarilyUnavailable: return .orange
        default:                                           return .secondary
        }
    }

    /// 把三类事件(setup/import/export)拼成一行人话。最近发生的优先显示,
    /// import / export 是日常状态,setup 只在初始化阶段出现一次。
    private var activitySummary: String {
        let parts: [(String, CloudKitSyncMonitor.EventState)] = [
            (L.t(.iCloudEventImport), monitor.importState),
            (L.t(.iCloudEventExport), monitor.exportState),
            (L.t(.iCloudEventSetup),  monitor.setupState)
        ]
        let active = parts.compactMap { name, state -> String? in
            switch state {
            case .idle: return nil
            case .running:           return "\(name): \(L.t(.iCloudActivityRunning))"
            case .succeeded:         return "\(name): \(L.t(.iCloudActivitySucceeded))"
            case .failed(let msg):   return "\(name): \(L.t(.iCloudActivityFailed)) — \(msg)"
            }
        }
        return active.isEmpty ? L.t(.iCloudActivityIdle) : active.joined(separator: "\n")
    }

    private var lastSyncText: String {
        guard let date = monitor.lastSyncDate else { return L.t(.iCloudLastSyncNever) }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// 打开 System Settings → Apple ID 面板。新版 macOS Settings.app 的
    /// deep link;失败时退化到普通 System Settings。
    private func openIcloudSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings")
            ?? URL(string: "x-apple.systempreferences:")!
        NSWorkspace.shared.open(url)
    }
}
