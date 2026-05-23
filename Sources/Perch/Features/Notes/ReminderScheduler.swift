import Foundation
import UserNotifications
import AppKit

/// 笔记提醒调度。封装 `UNUserNotificationCenter`:
/// - 第一次设提醒时弹系统授权对话框,被拒就 NSAlert 引导去系统设置
/// - 一条笔记最多一个 pending request,identifier = `id(for:)`
/// - 通知点击回调由 `AppDelegate` 注入到 `tapHandler`,把对应笔记的浮窗弹出
///
/// **不在 init 时请求授权**。LSUIElement App 启动就弹通知权限对话框很烦,只有
/// 用户真在 UI 上点了「设提醒」才请求,跟 macOS 通用的 just-in-time 体验一致。
///
/// 调度信息(pending request)由 macOS 系统自身持久化,App 重启甚至机器重启
/// 后仍保留,我们这边不需要重新注册。`Note.reminderDate` 字段是冗余记忆,
/// 给 UI 显示和 CloudKit 跨设备用 —— 同账号另一台 Mac 第一次见到这条笔记时
/// 可以选择「重新调度」(目前 MVP 没做主动重调,只在用户改提醒时同步)。
final class ReminderScheduler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ReminderScheduler()

    private let center = UNUserNotificationCenter.current()

    /// 通知点击回调。`AppDelegate.applicationDidFinishLaunching` 注入实现:
    /// 按 UUID 在 viewContext 找笔记,调 `floating.show(note:)`。
    var tapHandler: ((UUID) -> Void)?

    private override init() {
        super.init()
        center.delegate = self
    }

    /// 请求授权。返回 true 表示已授权(已经授权过 / 用户刚点了 Allow);false
    /// 表示被拒或不可用。调用方在 false 时应弹引导对话框 + 不要写库。
    func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            // alert + sound 即可:我们只要 banner + 默认提示音。badge 不用 ——
            // LSUIElement App 没 Dock icon 显示 badge,申请了也是浪费授权范围。
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        @unknown default:
            return false
        }
    }

    /// 设/改提醒。同 noteID 已有 pending request 直接覆盖。
    /// `fireAt` <= now 时直接当成「清掉」处理,避免立刻 fire 让用户摸不着头脑。
    func schedule(noteID: UUID, title: String, body: String, fireAt: Date) {
        let id = identifier(for: noteID)
        // 先撤掉旧 request(覆盖语义)。withIdentifiers: 没有时静默,无副作用。
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])

        guard fireAt > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? L.t(.appName) : title
        content.body = body
        content.sound = .default
        // userInfo 只塞 UUID 字符串。didReceive 时按这个找 Note。
        content.userInfo = [Self.userInfoNoteIDKey: noteID.uuidString]

        // UNCalendarNotificationTrigger 的绝对时间路径:System 跨重启/sleep 也能
        // 在精确时间点 fire。用 TimeInterval 触发器在系统 wake 后会有偏差。
        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: fireAt
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)

        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        center.add(request) { error in
            if let error {
                NSLog("Perch: failed to schedule reminder: %@", "\(error)")
            }
        }
    }

    /// 撤掉一条笔记的 pending + delivered。删笔记 / 用户清提醒 / 进回收站时调。
    func cancel(noteID: UUID) {
        let id = identifier(for: noteID)
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    /// 当前授权状态。UI 用来决定要不要先 prompt(纯查询不会引发对话框)。
    func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// 引导用户去系统设置开通知。授权被拒后调用。
    static func openNotificationSettings() {
        // macOS 14+ 的通知面板深链。Apple 没有官方 anchor 文档,但这条 URL
        // 在 macOS 13/14/15 都生效,失败时退回隐私与安全主面板。
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// App 在前台时收到通知 —— 默认系统会吞掉 banner,这里强制显示。
    /// 用户正盯着 Perch 时也能看到提醒,跟在后台一致。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// 用户点了通知。userInfo 里抽 UUID,转给 tapHandler。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard
            let raw = response.notification.request.content.userInfo[Self.userInfoNoteIDKey] as? String,
            let uuid = UUID(uuidString: raw)
        else { return }
        // 切回 main —— tapHandler 会走 Core Data + AppKit。
        DispatchQueue.main.async { [weak self] in
            self?.tapHandler?(uuid)
        }
    }

    // MARK: - Internals

    private static let userInfoNoteIDKey = "noteUUID"

    private func identifier(for noteID: UUID) -> String {
        "Noticky.reminder.\(noteID.uuidString)"
    }
}
