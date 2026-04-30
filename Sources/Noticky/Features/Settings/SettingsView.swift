import SwiftUI
import AppKit
import ServiceManagement

/// 偏好的 UserDefaults key 集中在这里,避免散落各处拼错。
enum SettingsKey {
    static let fadeWhenInactive = "Noticky.fadeWhenInactive"
    static let noteSort = "Noticky.noteSort"
}

/// 笔记列表的排序方式 —— 影响 ManagerView 和菜单栏。
enum NoteSort: String, CaseIterable, Identifiable {
    case dateEdited
    case dateCreated
    case title

    var id: String { rawValue }
    var label: String {
        switch self {
        case .dateEdited: return "Date Edited"
        case .dateCreated: return "Date Created"
        case .title: return "Title"
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
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            ShortcutsTab()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            PermissionsTab()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
            NotesTab()
                .tabItem { Label("Notes", systemImage: "note.text") }
            ICloudTab()
                .tabItem { Label("iCloud Sync", systemImage: "icloud") }
        }
    }
}

// MARK: - General -------------------------------------------------------------

struct GeneralTab: View {
    @State private var launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    @AppStorage(SettingsKey.noteSort) private var noteSortRaw: String = NoteSort.dateEdited.rawValue
    @AppStorage(SettingsKey.fadeWhenInactive) private var fadeWhenInactive: Bool = true

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLoginEnabled },
                set: { setLaunchAtLogin($0) }
            ))

            Picker("Sort by:", selection: $noteSortRaw) {
                ForEach(NoteSort.allCases) { sort in
                    Text(sort.label).tag(sort.rawValue)
                }
            }
            .pickerStyle(.menu)

            Toggle(isOn: $fadeWhenInactive) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fade when inactive")
                    Text("失去焦点的便签切换为毛玻璃半透明,凸显当前活跃窗口。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 480, height: 220)
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

// MARK: - Shortcuts -----------------------------------------------------------

struct ShortcutsTab: View {
    var body: some View {
        Form {
            Section {
                row(action: "Quick Capture", shortcut: "⌘⇧N")
                row(action: "Show All Notes", shortcut: "⌘⇧0")
                row(action: "Open Settings", shortcut: "⌘,")
                row(action: "New Note (Manager / Capture)", shortcut: "⌘N")
                row(action: "Quit", shortcut: "⌘Q")
            } footer: {
                Text("Customizing shortcuts is on the roadmap.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 480, height: 320)
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

    var body: some View {
        Form {
            Section {
                permissionRow(
                    title: "辅助功能 (Accessibility)",
                    description: "按 ⌘⇧N 时读取当前 App 选中的文字,自动填入新便签。",
                    granted: accessibilityGranted,
                    openSettings: SelectionFetcher.requestAndOpenAccessibilitySettings
                )
            } footer: {
                Text("权限在「系统设置 → 隐私与安全性」里集中管理。点 Open 直达对应面板。")
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
                Text(granted ? "已授权" : "未授权")
                    .font(.caption)
                    .foregroundStyle(granted ? .green : .orange)
                    .padding(.top, 2)
            }

            Spacer(minLength: 8)

            Button(granted ? "Open" : "Open Settings") {
                openSettings()
            }
            .controlSize(.regular)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Notes ---------------------------------------------------------------

struct NotesTab: View {
    var body: some View {
        Form {
            Section {
                Text("More note defaults coming soon.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 480, height: 140)
    }
}

// MARK: - iCloud --------------------------------------------------------------

struct ICloudTab: View {
    var body: some View {
        Form {
            Section {
                Label("iCloud Sync is not available yet.", systemImage: "icloud.slash")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 480, height: 140)
    }
}
