import Foundation
import Sparkle
import Combine

/// Sparkle 2 的 SwiftUI-friendly 薄封装。整个更新流程(拉 appcast、EdDSA
/// 校验、下载、out-of-process 安装、重启)都交给 `SPUStandardUpdaterController`
/// 跑 Sparkle 自己的原生 UI;我们只负责:
///
/// 1. controller 的生命周期(单例,App 启动到退出一直活着)。
/// 2. 通过 `SPUUpdaterDelegate.allowedChannels(for:)` 把
///    "include pre-releases" 偏好映射到 Sparkle 的 channel 机制
///    (release.sh 给 beta item 写 `<sparkle:channel>beta</sparkle:channel>`)。
/// 3. KVO 把 `canCheckForUpdates` / `lastUpdateCheckDate` / `updateCheckInterval`
///    镜像到 `@Published` 属性,Settings → Updates tab 能跟着自动刷新。
/// 4. **Gentle reminders**:后台(scheduled)检查发现新版本时,**不弹** Sparkle
///    的更新窗口,只把版本号记到 `availableVersion`,由 MenuBarController 在
///    托盘菜单里显示一个入口,等用户主动点。用户点了再走 Sparkle 的下载/安装
///    UI。用户主动 "Check Now" 不受影响,照常立即弹窗。
///
/// **不在 main thread 之外用**。`SPUStandardUpdaterController` 内部假设
/// 主线程驱动,跨线程会 deadlock。
final class UpdaterService: ObservableObject {
    static let shared = UpdaterService()

    let currentVersion: String =
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"

    let currentBuild: String =
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"

    /// 镜像 `controller.updater.canCheckForUpdates`。Settings tab 拿这个
    /// 禁用/启用 "Check Now" 按钮(检查进行中时变成 false)。
    @Published private(set) var canCheck: Bool = true

    /// 镜像 `controller.updater.lastUpdateCheckDate`。
    @Published private(set) var lastChecked: Date?

    /// 镜像 `controller.updater.updateCheckInterval`(秒)。Settings 的频率
    /// 选择器读它显示当前选项。
    @Published private(set) var checkInterval: TimeInterval = 86400

    /// 后台静默检查发现、但还没被用户处理的更新版本号(`displayVersionString`)。
    /// `nil` 表示当前没有待处理更新。MenuBarController 订阅它决定托盘里是否
    /// 显示「有可用更新」入口,以及图标上是否点个角标。
    @Published private(set) var availableVersion: String?

    /// 底层 controller。Settings tab 直接通过它调 `checkForUpdates(_:)`,
    /// Sparkle 会显示自带的 "checking..." / "up to date" / "update available"
    /// 三态 UI。
    let controller: SPUStandardUpdaterController

    private var cancellables: Set<AnyCancellable> = []
    private let delegate: UpdaterDelegate

    private init() {
        let delegate = UpdaterDelegate()
        self.delegate = delegate
        // userDriverDelegate 也指给同一个 delegate —— 它同时实现
        // SPUStandardUserDriverDelegate 提供 gentle reminders。
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: delegate
        )

        let updater = controller.updater
        canCheck = updater.canCheckForUpdates
        lastChecked = updater.lastUpdateCheckDate
        checkInterval = updater.updateCheckInterval

        // delegate 在后台发现/用户处理掉更新时回调回来。Sparkle 的 user driver
        // 回调在主线程,直接写 @Published 即可。
        delegate.onUpdateFound = { [weak self] version in self?.availableVersion = version }
        delegate.onUpdateHandled = { [weak self] in self?.availableVersion = nil }

        // Sparkle 把这几个属性标了 KVO-compliant,镜像到 @Published 让
        // SwiftUI Form 订阅得上。
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheck = $0 }
            .store(in: &cancellables)
        updater.publisher(for: \.lastUpdateCheckDate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.lastChecked = $0 }
            .store(in: &cancellables)
        updater.publisher(for: \.updateCheckInterval)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.checkInterval = $0 }
            .store(in: &cancellables)
    }

    /// 是否启用自动检查。SwiftUI 的 @AppStorage("Noticky.updater.autoCheck")
    /// 跟这个 setter 互为镜像 —— Sparkle 还会把同一个值写到它自己的 defaults
    /// domain,我们用 getter 从 Sparkle 读,setter 同步两边,任何一侧改了
    /// 另一侧都能感知。开了之后 Sparkle 会按 `updateInterval` 自动跑后台检查。
    var autoCheck: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// 定期检查间隔(秒)。映射 Sparkle 的 `updateCheckInterval` —— 这个值由
    /// Sparkle 自己持久化到它的 defaults domain,我们**不另存一份**,也不在
    /// 启动时回写(那会覆盖用户偏好,见 SPUUpdater.h 的说明)。改了之后 Sparkle
    /// 自动重排下一次检查。下限 1 小时,低于会被 Sparkle 夹住。
    func setUpdateInterval(_ seconds: TimeInterval) {
        controller.updater.updateCheckInterval = seconds
    }

    /// 用户点 "Check Now"。Sparkle 全程接管 UI 包括 "已是最新" 提示。
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// 启动时静默触发:只有真的有更新可用才走 gentle reminder(记到
    /// `availableVersion`,托盘显示入口),"已是最新" 不打扰用户。
    /// 用户在 Settings 关闭 auto-check 的话这里会被 Sparkle 自己跳过。
    func checkInBackground() {
        controller.updater.checkForUpdatesInBackground()
    }

    /// 用户从托盘点「有可用更新」时调。走一次 user-initiated 检查,Sparkle
    /// 会把之前后台发现的那个更新带 UI 重新呈现(下载/安装提示)。
    func showAvailableUpdate() {
        controller.checkForUpdates(nil)
    }
}

/// Sparkle 两个 delegate 的合并实现:
/// - `SPUUpdaterDelegate`:把 "Include pre-releases" 偏好映射到 channel。
/// - `SPUStandardUserDriverDelegate`:gentle reminders —— 后台检查发现更新时
///   不让 Sparkle 自己弹窗,改由我们在托盘显示入口。
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    /// 后台发现一个待处理更新(传 displayVersionString)。
    var onUpdateFound: ((String) -> Void)?
    /// 用户已看到/处理了更新提示,或更新会话结束 —— 清掉托盘标记。
    var onUpdateHandled: (() -> Void)?

    // MARK: SPUUpdaterDelegate

    /// "Include pre-releases" 偏好到 Sparkle channel 的映射。release.sh 对
    /// pre-release item 写 `<sparkle:channel>beta</sparkle:channel>`;不带
    /// channel 标记的视为 stable,任何时候都纳入考虑。
    ///
    /// 返回 `["beta"]` 表示"额外允许 beta channel" —— stable 仍然始终允许。
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        let includePrereleases = UserDefaults.standard.bool(forKey: "Noticky.updater.includePrereleases")
        return includePrereleases ? ["beta"] : []
    }

    // MARK: SPUStandardUserDriverDelegate (gentle reminders)

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// 后台(scheduled)检查发现更新时:一律返回 false,不让 Sparkle 弹自己的
    /// 更新窗口。我们改在 `standardUserDriverWillHandleShowingUpdate` 里记下版本,
    /// 托盘显示入口。注意:user-initiated 检查不会走这个回调,照常弹窗。
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    /// `handleShowingUpdate == false` 表示上面那个回调把这次更新交给了我们 ——
    /// 这就是后台静默发现更新的 gentle reminder 路径,记下版本号通知托盘。
    /// user-initiated 检查时 `handleShowingUpdate == true`,跳过。
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        if !handleShowingUpdate {
            onUpdateFound?(update.displayVersionString)
        }
    }

    /// 用户已经看到/处理了这次更新提示(点了托盘入口走 Sparkle UI、或选择了
    /// 安装/跳过)。清掉托盘标记。
    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        onUpdateHandled?()
    }

    /// 更新会话结束(用户跳过/出错/装完)的兜底清理。
    func standardUserDriverWillFinishUpdateSession() {
        onUpdateHandled?()
    }
}
