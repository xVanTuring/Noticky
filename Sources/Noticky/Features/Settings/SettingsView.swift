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

// 各 tab SwiftUI 视图。改 internal 让 SettingsWindowController 的
// NSHostingController 能用。每个都给 .frame(width:480, height:X) 让
// NSHostingController 推算出 preferredContentSize → 驱动 NSTabViewController
// 切 tab 时窗口动画 resize。

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
