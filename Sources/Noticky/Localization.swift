import Foundation
import Combine

/// 用户在 Settings 里选的语言。`.system` 表示跟随系统;`.english` / `.chinese`
/// 是显式覆盖。持久化在 UserDefaults(key 见 SettingsKey.appLanguage)。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case chinese

    var id: String { rawValue }

    static func from(_ raw: String) -> AppLanguage {
        AppLanguage(rawValue: raw) ?? .system
    }
}

/// 全局语言状态。SwiftUI 视图通过 `@ObservedObject private var loc =
/// LocalizationManager.shared` 订阅 —— 用户切换语言时 published `current` 变
/// → view 重渲染 → `L.t(...)` 取到新语言文案。
///
/// AppKit 部分(MenuBarController 的 NSMenu、AppDelegate 的 main menu)按需
/// rebuild,每次 build 时直接读 `L.t(...)` 即可。
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    @Published var current: AppLanguage

    private init() {
        let raw = UserDefaults.standard.string(forKey: "Noticky.appLanguage") ?? ""
        self.current = AppLanguage.from(raw)
    }

    /// `.system` 时按系统当前 locale 推断 —— 我们只支持中英,zh 开头视为中文,
    /// 其它都退回英文。这样新语言系统的用户也有可读的兜底。
    var effective: AppLanguage {
        if current != .system { return current }
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        return code.lowercased().hasPrefix("zh") ? .chinese : .english
    }

    func setLanguage(_ lang: AppLanguage) {
        guard lang != current else { return }
        current = lang
        UserDefaults.standard.set(lang.rawValue, forKey: "Noticky.appLanguage")
    }
}

/// 所有用户可见字符串的 key。raw value 用作 fallback —— 字典里查不到时直接
/// 显示 key 名,容易在 UI 上发现遗漏。
enum LocKey: String {
    // 通用
    case appName, ok, cancel, save, delete, untitled, emptyNote, restore
    case langFollowSystem, langEnglish, langChinese

    // MenuBar
    case menuNewNote, menuShowAllStickies, menuHideAllStickies
    case menuManageAllNotes, menuSettings, menuFloatOnTop, menuLayout, menuQuit

    // Layout modes
    case layoutFree, layoutStack, layoutTile

    // NoteSort
    case sortDateEdited, sortDateCreated, sortTitle

    // Settings tabs
    case tabGeneral, tabCapture, tabShortcuts, tabPermissions, tabNotes, tabICloud

    // Settings General
    case generalLaunchAtLogin, generalSortBy
    case generalFadeWhenInactive, generalFadeWhenInactiveDesc
    case generalDoubleClickCollapse, generalDoubleClickCollapseDesc
    case generalLanguage

    // Settings Shortcuts
    case shortcutsCustomizable, shortcutsSystem
    case shortcutQuickCapture, shortcutManageNotes, shortcutOpenSettings
    case shortcutNewNote, shortcutCloseWindow, shortcutDeleteNote
    case shortcutQuit, shortcutsRoadmap

    // Settings Permissions
    case permissionAccessibilityTitle, permissionAccessibilityDesc
    case permissionGranted, permissionNotGranted, permissionOpenSettings, permissionOpen, permissionFooter

    // Settings Capture
    case captureMethod, captureFooterAxWhitelist, captureFooterClipboardOnly, captureFooterDisabled
    case captureModeAxWhitelist, captureModeClipboardOnly, captureModeDisabled
    case captureWhitelistTitle, captureWhitelistHint

    // Settings Notes
    case notesDefaultColor, notesFontSize, notesDefaultSize, notesStartInEditMode
    case notesStartInEditModeDesc
    case noteSizeSmall, noteSizeMedium, noteSizeLarge

    // Settings iCloud placeholder
    case iCloudPlaceholder

    // Quick Capture
    case quickPlaceholder, quickSave, quickNewLine, quickCancel

    // Floating note popover
    case floatCollapse, floatExpand, floatDelete

    // Manager toolbar / sidebar
    case managerSearch, managerNewGroup, managerNewNote
    case managerOpenAsSticky, managerMoveToGroup, managerMoveNotesToGroup
    case managerUngrouped, managerRename, managerRenameAlertTitle, managerGroupNamePlaceholder
    case managerRenameMessage, managerNewGroupAlertTitle, managerNewGroupMessage, managerCreate
    case managerDeleteGroup
    case managerDeleteNote, managerDeleteCount
    case managerSelectNote, managerSelectNoteDesc
    case managerMultiSelected, managerMultiSelectedDesc

    // Accessibility prompt (NSAlert)
    case promptAxTitle, promptAxBody, promptAxOpen, promptAxNotNow

    // Trash
    case trashTitle, trashEmpty, trashEmptyDesc, trashEmptyButton
    case trashEmptyAlert, trashEmptyAlertMsg
    case trashDeleteAlert, trashDeleteAlertMsg, trashCannotUndo
    case trashDeletePermanentlyHelp, trashedRelative
}

/// 字符串查找器。`L.t(.foo)` 取无参数版本;`L.t(.foo, args)` 取 `String(format:)` 版本。
enum L {
    static func t(_ key: LocKey) -> String {
        let lang = LocalizationManager.shared.effective
        return strings[lang]?[key] ?? key.rawValue
    }

    static func t(_ key: LocKey, _ args: CVarArg...) -> String {
        let template = t(key)
        return String(format: template, arguments: args)
    }

    private static let strings: [AppLanguage: [LocKey: String]] = [
        .english: en,
        .chinese: zh
    ]

    private static let en: [LocKey: String] = [
        .appName: "Noticky", .ok: "OK", .cancel: "Cancel", .save: "Save",
        .delete: "Delete", .untitled: "Untitled", .emptyNote: "Empty Note",
        .restore: "Restore",
        .langFollowSystem: "Follow System", .langEnglish: "English", .langChinese: "简体中文",

        .menuNewNote: "New Note", .menuShowAllStickies: "Show All Stickies",
        .menuHideAllStickies: "Hide All Stickies", .menuManageAllNotes: "Manage All Notes",
        .menuSettings: "Settings…", .menuFloatOnTop: "Float on Top",
        .menuLayout: "Layout", .menuQuit: "Quit Noticky",

        .layoutFree: "Free Layout", .layoutStack: "Stack", .layoutTile: "Tile",

        .sortDateEdited: "Date Edited", .sortDateCreated: "Date Created", .sortTitle: "Title",

        .tabGeneral: "General", .tabCapture: "Capture", .tabShortcuts: "Shortcuts",
        .tabPermissions: "Permissions", .tabNotes: "Notes", .tabICloud: "iCloud Sync",

        .generalLaunchAtLogin: "Launch at login",
        .generalSortBy: "Sort by:",
        .generalFadeWhenInactive: "Fade when inactive",
        .generalFadeWhenInactiveDesc: "Floating notes fade to translucent when not focused, highlighting the active window.",
        .generalDoubleClickCollapse: "Double-click title to collapse",
        .generalDoubleClickCollapseDesc: "Double-click a sticky note's title strip to shrink the window to just the title bar; double-click again to expand. State is remembered per note.",
        .generalLanguage: "Language",

        .shortcutsCustomizable: "Customizable",
        .shortcutsSystem: "System",
        .shortcutQuickCapture: "Quick Capture",
        .shortcutManageNotes: "Manage All Notes",
        .shortcutOpenSettings: "Open Settings",
        .shortcutNewNote: "New Note (Manager / Capture)",
        .shortcutCloseWindow: "Close Window",
        .shortcutDeleteNote: "Delete Floating Note",
        .shortcutQuit: "Quit",
        .shortcutsRoadmap: "Customizing shortcuts is on the roadmap.",

        .permissionAccessibilityTitle: "Accessibility",
        .permissionAccessibilityDesc: "Required so ⌘⇧N can read the selected text from the frontmost app and prefill it into a new sticky.",
        .permissionGranted: "Granted",
        .permissionNotGranted: "Not granted",
        .permissionOpenSettings: "Open Settings",
        .permissionOpen: "Open",
        .permissionFooter: "Permissions are managed in System Settings → Privacy & Security. Open jumps you straight to the relevant pane.",

        .captureMethod: "Capture mode:",
        .captureModeAxWhitelist: "Accessibility + Clipboard whitelist",
        .captureModeClipboardOnly: "Clipboard only",
        .captureModeDisabled: "Disabled",
        .captureFooterAxWhitelist: "By default, capture selected text via Accessibility. Apps in the whitelist use ⌘C / clipboard instead, then restore the previous clipboard contents. Useful for apps like WeChat that don't expose AX selection.",
        .captureFooterClipboardOnly: "Always synthesize ⌘C and read the pasteboard. Doesn't require Accessibility. The previous clipboard contents are restored after.",
        .captureFooterDisabled: "⌘⇧N opens an empty capture window without trying to read selected text.",
        .captureWhitelistTitle: "Clipboard whitelist (one bundle ID per line)",
        .captureWhitelistHint: "Examples: com.tencent.xinWeChat, com.microsoft.VSCode",

        .notesDefaultColor: "Default color",
        .notesFontSize: "Editor font size",
        .notesDefaultSize: "Default window size",
        .notesStartInEditMode: "Open notes in edit mode",
        .notesStartInEditModeDesc: "When you open a note, jump straight into the editable source view instead of the rendered Markdown preview.",
        .noteSizeSmall: "Small (240×240)",
        .noteSizeMedium: "Medium (280×280)",
        .noteSizeLarge: "Large (360×360)",
        .iCloudPlaceholder: "iCloud Sync is not available yet.",

        .quickPlaceholder: "Quick note…",
        .quickSave: "Save", .quickNewLine: "New line", .quickCancel: "Cancel",

        .floatCollapse: "Collapse", .floatExpand: "Expand", .floatDelete: "Delete note",

        .managerSearch: "Search all notes",
        .managerNewGroup: "New Group",
        .managerNewNote: "New Note",
        .managerOpenAsSticky: "Open as Sticky",
        .managerMoveToGroup: "Move to Group",
        .managerMoveNotesToGroup: "Move %d Notes to Group",
        .managerUngrouped: "Ungrouped",
        .managerRename: "Rename",
        .managerRenameAlertTitle: "Rename Group",
        .managerGroupNamePlaceholder: "Group name",
        .managerRenameMessage: "Enter a new name for the group.",
        .managerNewGroupAlertTitle: "New Group",
        .managerNewGroupMessage: "Enter a name for the new group.",
        .managerCreate: "Create",
        .managerDeleteGroup: "Delete Group",
        .managerDeleteNote: "Delete",
        .managerDeleteCount: "Delete %d Notes",
        .managerSelectNote: "Select a note",
        .managerSelectNoteDesc: "Pick a note from the sidebar, or ⌘N to create one.",
        .managerMultiSelected: "%d notes selected",
        .managerMultiSelectedDesc: "Right-click in the sidebar to delete or move them.",

        .promptAxTitle: "Enable Accessibility to auto-fill selected text",
        .promptAxBody: "Noticky needs the Accessibility permission to read the selected text from the frontmost app and prefill it when you press ⌘⇧N.\n\nOpen System Settings → Privacy & Security → Accessibility and enable Noticky. Then press ⌘⇧N again.",
        .promptAxOpen: "Open System Settings",
        .promptAxNotNow: "Not Now",

        .trashTitle: "Trash",
        .trashEmpty: "Trash is empty",
        .trashEmptyDesc: "Notes you delete will appear here for 30 days.",
        .trashEmptyButton: "Empty Trash",
        .trashEmptyAlert: "Empty Trash?",
        .trashEmptyAlertMsg: "This permanently deletes all notes in Trash. This can't be undone.",
        .trashDeleteAlert: "Delete this note permanently?",
        .trashDeleteAlertMsg: "This can't be undone.",
        .trashCannotUndo: "This can't be undone.",
        .trashDeletePermanentlyHelp: "Delete permanently",
        .trashedRelative: "Trashed %@"
    ]

    private static let zh: [LocKey: String] = [
        .appName: "Noticky", .ok: "确定", .cancel: "取消", .save: "保存",
        .delete: "删除", .untitled: "未命名", .emptyNote: "空便签",
        .restore: "还原",
        .langFollowSystem: "跟随系统", .langEnglish: "English", .langChinese: "简体中文",

        .menuNewNote: "新建便签", .menuShowAllStickies: "显示所有便签",
        .menuHideAllStickies: "隐藏所有便签", .menuManageAllNotes: "管理所有便签",
        .menuSettings: "设置…", .menuFloatOnTop: "悬浮置顶",
        .menuLayout: "布局", .menuQuit: "退出 Noticky",

        .layoutFree: "自由布局", .layoutStack: "堆叠", .layoutTile: "平铺",

        .sortDateEdited: "编辑时间", .sortDateCreated: "创建时间", .sortTitle: "标题",

        .tabGeneral: "通用", .tabCapture: "抓取", .tabShortcuts: "快捷键",
        .tabPermissions: "权限", .tabNotes: "便签", .tabICloud: "iCloud 同步",

        .generalLaunchAtLogin: "开机自动启动",
        .generalSortBy: "排序方式:",
        .generalFadeWhenInactive: "失焦时半透明",
        .generalFadeWhenInactiveDesc: "失去焦点的便签切换为毛玻璃半透明,凸显当前活跃窗口。",
        .generalDoubleClickCollapse: "双击标题折叠",
        .generalDoubleClickCollapseDesc: "双击便签顶部标题区,把窗口收成只剩标题条;再双击展开。状态会跟着便签一起记。",
        .generalLanguage: "语言",

        .shortcutsCustomizable: "可自定义",
        .shortcutsSystem: "系统",
        .shortcutQuickCapture: "快速捕获",
        .shortcutManageNotes: "管理所有便签",
        .shortcutOpenSettings: "打开设置",
        .shortcutNewNote: "新建便签(管理 / 捕获)",
        .shortcutCloseWindow: "关闭窗口",
        .shortcutDeleteNote: "删除当前便签(浮窗)",
        .shortcutQuit: "退出",
        .shortcutsRoadmap: "自定义快捷键将在后续版本支持。",

        .permissionAccessibilityTitle: "辅助功能",
        .permissionAccessibilityDesc: "按 ⌘⇧N 时读取当前 App 选中的文字,自动填入新便签。",
        .permissionGranted: "已授权",
        .permissionNotGranted: "未授权",
        .permissionOpenSettings: "打开系统设置",
        .permissionOpen: "打开",
        .permissionFooter: "权限在「系统设置 → 隐私与安全性」里集中管理。点 Open 直达对应面板。",

        .captureMethod: "抓取方式:",
        .captureModeAxWhitelist: "辅助功能 + 复制粘贴白名单",
        .captureModeClipboardOnly: "纯复制粘贴",
        .captureModeDisabled: "关闭自动抓取",
        .captureFooterAxWhitelist: "默认通过「辅助功能」抓取选中文本;白名单里的 App 改用合成 ⌘C 读剪贴板,然后自动还原原本的剪贴板内容。适合微信等不暴露 AX 选区的 App。",
        .captureFooterClipboardOnly: "永远合成 ⌘C 读剪贴板,不依赖辅助功能权限。读完会还原原本的剪贴板内容。",
        .captureFooterDisabled: "⌘⇧N 直接打开空白 capture 输入框,不抓取任何选中文本。",
        .captureWhitelistTitle: "剪贴板白名单(每行一个 bundle ID)",
        .captureWhitelistHint: "常见示例:com.tencent.xinWeChat、com.microsoft.VSCode",

        .notesDefaultColor: "默认颜色",
        .notesFontSize: "编辑器字号",
        .notesDefaultSize: "默认窗口尺寸",
        .notesStartInEditMode: "打开便签直接进入编辑态",
        .notesStartInEditModeDesc: "打开便签时直接显示可编辑的 Markdown 源码,而不是先看渲染预览。",
        .noteSizeSmall: "小 (240×240)",
        .noteSizeMedium: "中 (280×280)",
        .noteSizeLarge: "大 (360×360)",
        .iCloudPlaceholder: "iCloud 同步暂不可用。",

        .quickPlaceholder: "快速便签…",
        .quickSave: "保存", .quickNewLine: "换行", .quickCancel: "取消",

        .floatCollapse: "折叠", .floatExpand: "展开", .floatDelete: "删除便签",

        .managerSearch: "搜索所有便签",
        .managerNewGroup: "新建分组",
        .managerNewNote: "新建便签",
        .managerOpenAsSticky: "打开为浮窗",
        .managerMoveToGroup: "移动到分组",
        .managerMoveNotesToGroup: "将 %d 条便签移到分组",
        .managerUngrouped: "未分组",
        .managerRename: "重命名",
        .managerRenameAlertTitle: "重命名分组",
        .managerGroupNamePlaceholder: "分组名",
        .managerRenameMessage: "为分组输入一个新名字。",
        .managerNewGroupAlertTitle: "新建分组",
        .managerNewGroupMessage: "为新分组输入一个名字。",
        .managerCreate: "创建",
        .managerDeleteGroup: "删除分组",
        .managerDeleteNote: "删除",
        .managerDeleteCount: "删除 %d 条便签",
        .managerSelectNote: "选择一条便签",
        .managerSelectNoteDesc: "从侧边栏选一条便签,或者按 ⌘N 新建。",
        .managerMultiSelected: "已选中 %d 条便签",
        .managerMultiSelectedDesc: "在侧边栏右键以删除或移动它们。",

        .promptAxTitle: "开启辅助功能以自动填入选中文本",
        .promptAxBody: "Noticky 需要「辅助功能」权限才能在你按下 ⌘⇧N 时,读取当前 App 里选中的文字并自动填入。\n\n打开「系统设置 → 隐私与安全性 → 辅助功能」,把 Noticky 勾上即可。授权后再按 ⌘⇧N 就能用了。",
        .promptAxOpen: "打开系统设置",
        .promptAxNotNow: "暂不开启",

        .trashTitle: "回收站",
        .trashEmpty: "回收站为空",
        .trashEmptyDesc: "删除的便签会保留 30 天。",
        .trashEmptyButton: "清空回收站",
        .trashEmptyAlert: "清空回收站?",
        .trashEmptyAlertMsg: "这会永久删除回收站里的所有便签,操作无法撤销。",
        .trashDeleteAlert: "彻底删除这条便签?",
        .trashDeleteAlertMsg: "操作无法撤销。",
        .trashCannotUndo: "操作无法撤销。",
        .trashDeletePermanentlyHelp: "彻底删除",
        .trashedRelative: "%@删除"
    ]
}
