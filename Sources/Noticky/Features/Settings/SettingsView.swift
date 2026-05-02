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
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 480, height: 340)
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

struct ICloudTab: View {
    @ObservedObject private var loc = LocalizationManager.shared

    var body: some View {
        Form {
            Section {
                Label(L.t(.iCloudPlaceholder), systemImage: "icloud.slash")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 480, height: 140)
    }
}
