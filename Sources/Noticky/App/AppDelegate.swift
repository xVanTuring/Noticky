import AppKit
import SwiftUI
import CoreData

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController!
    private var capture: CaptureWindowController!
    private var hotKey: HotKeyManager!
    private let floating = FloatingNotesRegistry()
    private var manager: ManagerWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let context = PersistenceController.shared.container.viewContext

        manager = ManagerWindowController(context: context, floating: floating)
        menuBar = MenuBarController(context: context, floating: floating, manager: manager)
        capture = CaptureWindowController(context: context)

        hotKey = HotKeyManager()
        hotKey.register(combo: .captureDefault) { [weak self] in
            self?.capture.toggle()
        }

        restorePinnedNotes(in: context)
    }

    /// 启动时把上次还在浮窗状态的笔记自动恢复出来。`isPinned` 一字段同时表达
    /// 「当前是否有浮窗」和「下次启动是否自动显示」—— 用户手动 × 关掉就置 false,
    /// 从列表点开/新建就置 true。
    private func restorePinnedNotes(in context: NSManagedObjectContext) {
        let request = NSFetchRequest<Note>(entityName: "Note")
        // Swift 的 NSPredicate(format:) 不认 ObjC 字面量 YES,SQLite 里 isPinned 是
        // INTEGER 0/1。用 NSNumber 显式包装最稳。
        request.predicate = NSPredicate(format: "isPinned == %@", NSNumber(value: true))
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        guard let pinned = try? context.fetch(request) else { return }
        for note in pinned {
            floating.show(note: note)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 退出 hook 必须比 windowWillClose 早 —— `applicationShouldTerminate` 在
    /// 系统开始关 windows 之前调,这时打 isTerminating flag,后续每个浮窗的
    /// windowWillClose → onClose 会跳过把 isPinned 清成 false 的写库逻辑,
    /// 下次启动 restorePinnedNotes 才能 fetch 到这些笔记。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        floating.isTerminating = true
        return .terminateNow
    }
}
