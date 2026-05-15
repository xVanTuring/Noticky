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
/// 3. KVO 把 `canCheckForUpdates` / `lastUpdateCheckDate` 镜像到
///    `@Published` 属性,Settings → Updates tab 能跟着自动刷新。
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

    /// 底层 controller。Settings tab 直接通过它调 `checkForUpdates(_:)`,
    /// Sparkle 会显示自带的 "checking..." / "up to date" / "update available"
    /// 三态 UI。
    let controller: SPUStandardUpdaterController

    private var cancellables: Set<AnyCancellable> = []
    private let delegate: UpdaterDelegate

    private init() {
        let delegate = UpdaterDelegate()
        self.delegate = delegate
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )

        let updater = controller.updater
        canCheck = updater.canCheckForUpdates
        lastChecked = updater.lastUpdateCheckDate

        // Sparkle 把这俩属性标了 KVO-compliant,镜像到 @Published 让
        // SwiftUI Form 订阅得上。
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheck = $0 }
            .store(in: &cancellables)
        updater.publisher(for: \.lastUpdateCheckDate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.lastChecked = $0 }
            .store(in: &cancellables)
    }

    /// 是否启用自动检查。SwiftUI 的 @AppStorage("Noticky.updater.autoCheck")
    /// 跟这个 setter 互为镜像 —— Sparkle 还会把同一个值写到它自己的 defaults
    /// domain,我们用 getter 从 Sparkle 读,setter 同步两边,任何一侧改了
    /// 另一侧都能感知。
    var autoCheck: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// 用户点 "Check Now"。Sparkle 全程接管 UI 包括 "已是最新" 提示。
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// 启动时静默触发:只有真的有更新可用才弹 UI,"已是最新" 不打扰用户。
    /// 用户在 Settings 关闭 auto-check 的话这里会被 Sparkle 自己跳过。
    func checkInBackground() {
        controller.updater.checkForUpdatesInBackground()
    }
}

/// "Include pre-releases" 偏好到 Sparkle channel 的映射。release.sh 对
/// pre-release item 写 `<sparkle:channel>beta</sparkle:channel>`;不带 channel
/// 标记的视为 stable,任何时候都纳入考虑。
///
/// 返回 `["beta"]` 表示"额外允许 beta channel" —— stable 仍然始终允许。
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        let includePrereleases = UserDefaults.standard.bool(forKey: "Noticky.updater.includePrereleases")
        return includePrereleases ? ["beta"] : []
    }
}
