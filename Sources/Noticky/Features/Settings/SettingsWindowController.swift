import AppKit
import SwiftUI

/// Settings 窗口。AppKit 原生 NSTabViewController + NSHostingController(SwiftUI),
/// **手动驱动窗口动画 resize**。
///
/// 关键点:
/// 1. 默认 NSTabViewController 切 tab 调 `setContentSize`,等价 `setFrame(animate:false)`
///    —— 没动画。要拿到系统 Settings.app 那种丝滑变高效果,必须 override 切换钩子,
///    用 `NSAnimationContext.runAnimationGroup + window.animator().setFrame(...)`。
/// 2. 锚点:macOS 系统 Settings **顶部固定向下长**,默认从中心缩放。我们手动改
///    `frame.origin.y -= delta`,让 top 边不动。
/// 3. 让每个 NSHostingController 设 `sizingOptions = .preferredContentSize`,
///    这样 SwiftUI 视图上的 `.frame(width:height:)` 会被自动同步到
///    NSViewController.preferredContentSize,我们就能从 vc 拿到目标尺寸。
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
        // 不要 crossfade —— 我们想要的是「窗口高度动画」,内容直接切换。
        // crossfade 反而让 content 模糊一下,不符合系统 Settings 行为。
        tabVC.transitionOptions = []

        tabVC.addTabViewItem(makeTab(GeneralTab(),   label: "General",     icon: "gearshape"))
        tabVC.addTabViewItem(makeTab(ShortcutsTab(), label: "Shortcuts",   icon: "keyboard"))
        tabVC.addTabViewItem(makeTab(NotesTab(),     label: "Notes",       icon: "note.text"))
        tabVC.addTabViewItem(makeTab(ICloudTab(),    label: "iCloud Sync", icon: "icloud"))

        return tabVC
    }

    private func makeTab<V: View>(_ view: V, label: String, icon: String) -> NSTabViewItem {
        let host = NSHostingController(rootView: view)
        // 让 SwiftUI .frame() 自动同步到 preferredContentSize,AnimatedSettingsTabController
        // 切 tab 时就能从 vc 拿到目标尺寸去算 frame。
        host.sizingOptions = .preferredContentSize
        let item = NSTabViewItem(viewController: host)
        item.label = label
        item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        return item
    }

    func windowWillClose(_ notification: Notification) {
        // 释放 SwiftUI 视图树 + 各 NSHostingController,免得无主窗时还订阅 UserDefaults。
        window?.contentViewController = nil
        window = nil
    }
}

/// NSTabViewController 子类,把切 tab 时的窗口 resize 改成顶部锚点 + 动画。
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
        // 用户切 tab → 走动画。第一次还没 didInitialSize 时(如果发生在 viewDidAppear 之前)
        // 也按 animated 走,看到的是从某个尺寸渐变,不会闪烁。
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
