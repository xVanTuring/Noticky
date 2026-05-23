import AppKit
import SwiftUI
import CoreData

/// 集中管理窗口 —— 不像浮窗是常驻便签,而是一个标准的 titled NSWindow,
/// 用户从菜单栏点 "Show All Notes" 唤出来,左边是分组+笔记列表,右边显示
/// 选中笔记的渲染内容。一个 App 同一时间只有一个实例。
final class ManagerWindowController: NSObject, NSWindowDelegate {
    private let context: NSManagedObjectContext
    private let floating: FloatingNotesRegistry
    private var window: NSWindow?

    init(context: NSManagedObjectContext, floating: FloatingNotesRegistry) {
        self.context = context
        self.floating = floating
        super.init()
    }

    func showWindow() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let host = NSHostingController(
            rootView: ManagerView(floating: floating)
                .environment(\.managedObjectContext, context)
        )

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title = "Perch"
        w.titlebarAppearsTransparent = true
        w.contentViewController = host
        w.setContentSize(NSSize(width: 900, height: 600))
        w.minSize = NSSize(width: 600, height: 400)
        w.center()
        w.delegate = self
        w.isReleasedWhenClosed = false

        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = w
    }

    func windowWillClose(_ notification: Notification) {
        // 释放 SwiftUI 视图树,下次 show 重建。NSHostingController 会持有 FetchRequest
        // 订阅,不释放会重复占内存。
        window?.contentViewController = nil
        window = nil
    }
}
