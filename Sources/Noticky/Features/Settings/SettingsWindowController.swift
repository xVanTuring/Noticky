import AppKit
import SwiftUI

/// 设置窗口。AppKit 原生 `NSTabViewController` + SwiftUI 内容,**手动驱动窗口动画 resize**,
/// 复刻 macOS System Settings.app 的「顶部锚定 + 高度动画」效果。
///
/// 整个设置窗口完全脱离 SwiftUI `Settings { ... }` scene —— SwiftUI scene 那条路
/// 拿不到原生切 tab 的窗口动画(整个开源生态共识,见 sindresorhus/Settings、OpenEmu、
/// IINA+ 等),只能回到 NSTabViewController 子类自己 animate window.frame。
///
/// 关键点:
/// 1. 默认 NSTabViewController 切 tab 走 `setContentSize`,等价 `setFrame(animate:false)`
///    —— 没动画。`NSAnimationContext.runAnimationGroup` + `window.animator().setFrame(...)`
///    才能拿到 System Settings 的丝滑高度变化。
/// 2. 锚点:macOS Settings 顶部固定向下长,默认从中心缩放。手动 `frame.origin.y -= delta`
///    让 top 边不动。
/// 3. 每个 NSHostingController 设 `sizingOptions = .preferredContentSize`,SwiftUI 视图上的
///    `.frame(width:height:)` 自动同步到 `NSViewController.preferredContentSize`,我们就
///    能从 vc 取目标尺寸。
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func showWindow() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let tabVC = makeTabController()

        let w = NSWindow(contentViewController: tabVC)
        w.styleMask = [.titled, .closable]
        w.title = "Settings"
        w.center()
        w.delegate = self
        w.isReleasedWhenClosed = false

        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = w
    }

    private func makeTabController() -> NSTabViewController {
        let tabVC = AnimatedSettingsTabController()
        tabVC.tabStyle = .toolbar
        // 不要 crossfade —— 我们要的是「窗口高度动画」,内容直接切换。crossfade 让
        // content 模糊一下,反而不像系统 Settings。
        tabVC.transitionOptions = []

        tabVC.addTabViewItem(makeTab(GeneralTab(),     label: "General",     icon: "gearshape"))
        tabVC.addTabViewItem(makeTab(CaptureTab(),     label: "Capture",     icon: "doc.on.clipboard"))
        tabVC.addTabViewItem(makeTab(ShortcutsTab(),   label: "Shortcuts",   icon: "keyboard"))
        tabVC.addTabViewItem(makeTab(PermissionsTab(), label: "Permissions", icon: "lock.shield"))
        tabVC.addTabViewItem(makeTab(NotesTab(),       label: "Notes",       icon: "note.text"))
        tabVC.addTabViewItem(makeTab(ICloudTab(),      label: "iCloud Sync", icon: "icloud"))

        return tabVC
    }

    private func makeTab<V: View>(_ view: V, label: String, icon: String) -> NSTabViewItem {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = .preferredContentSize
        // NSTabViewController 会把 selected child VC 的 title 同步到 window.title。
        // NSHostingController 默认 title 为 nil → 显示 "untitled"。设上 label 后,
        // 窗口标题会跟着 tab 切换显示 "General"/"Shortcuts"/... ——  跟 macOS
        // System Settings.app 一致。
        host.title = label
        let item = NSTabViewItem(viewController: host)
        item.label = label
        item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        return item
    }

    func windowWillClose(_ notification: Notification) {
        // 释放 SwiftUI 视图树 + 各 NSHostingController,避免无主窗时还订阅 UserDefaults。
        window?.contentViewController = nil
        window = nil
    }
}

private final class AnimatedSettingsTabController: NSTabViewController {
    private var didInitialSize = false

    override func viewDidAppear() {
        super.viewDidAppear()
        // 首次出现:无动画直接 snap 到当前 tab 尺寸,免得从默认 size 跳到内容 size 那一闪。
        if !didInitialSize {
            resizeWindowToSelectedTab(animated: false)
            didInitialSize = true
        }
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        resizeWindowToSelectedTab(animated: true)
    }

    private func resizeWindowToSelectedTab(animated: Bool) {
        guard let window = view.window else { return }
        guard let item = tabView.selectedTabViewItem,
              let vc = item.viewController else { return }

        let target = vc.preferredContentSize
        guard target.width > 0, target.height > 0 else { return }

        let contentRect = NSRect(origin: .zero, size: target)
        let frameRect = window.frameRect(forContentRect: contentRect)

        var newFrame = window.frame
        // 顶部锚点:y origin 跟着减,top 边保持不动 —— 跟系统 Settings 一致。
        let deltaY = frameRect.height - newFrame.height
        newFrame.origin.y -= deltaY
        newFrame.size = frameRect.size

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                window.animator().setFrame(newFrame, display: true)
            }
        } else {
            window.setFrame(newFrame, display: true)
        }
    }
}
