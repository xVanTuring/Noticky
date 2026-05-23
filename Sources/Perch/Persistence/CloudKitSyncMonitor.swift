import Foundation
import CoreData
import CloudKit
import Combine

/// CloudKit 同步状态聚合器。Settings → iCloud Sync tab 用它显示:
///   - iCloud 账户状态(已登录 / 未登录 / 受限 / 临时不可用)
///   - 最近一次 setup / import / export 事件结果
///   - 上次成功同步时间
///
/// 实现方式:
///   - 监听 `NSPersistentCloudKitContainer.eventChangedNotification`(setup /
///     import / export 三类事件,每种都有 startDate/endDate/error)。
///   - 启动时 + 收到 `CKAccountChanged` 时调一次 `CKContainer.accountStatus(...)`。
///
/// 不在跑 CloudKit 模式(本地 NSPersistentContainer)时整个对象 idle —— 所有字段
/// 保持初值,UI 直接显示「未启用」。
@MainActor
final class CloudKitSyncMonitor: ObservableObject {
    enum AccountStatus: Equatable {
        case unknown
        case available
        case noAccount
        case restricted
        case couldNotDetermine
        case temporarilyUnavailable

        var localizedLabel: String {
            switch self {
            case .unknown:                 return L.t(.iCloudAccountUnknown)
            case .available:               return L.t(.iCloudAccountAvailable)
            case .noAccount:               return L.t(.iCloudAccountNone)
            case .restricted:              return L.t(.iCloudAccountRestricted)
            case .couldNotDetermine:       return L.t(.iCloudAccountUnknown)
            case .temporarilyUnavailable:  return L.t(.iCloudAccountTempUnavail)
            }
        }
    }

    enum EventState: Equatable {
        case idle
        case running
        case succeeded
        case failed(message: String)
    }

    static let shared = CloudKitSyncMonitor()

    @Published private(set) var enabled: Bool
    @Published private(set) var accountStatus: AccountStatus = .unknown
    @Published private(set) var setupState: EventState = .idle
    @Published private(set) var importState: EventState = .idle
    @Published private(set) var exportState: EventState = .idle
    @Published private(set) var lastSyncDate: Date?

    private var cancellables: Set<AnyCancellable> = []

    private init() {
        self.enabled = PersistenceController.shared.cloudKitEnabled

        guard enabled else { return }

        // CloudKit container 事件 —— 同步生命周期的真相源。一个 event 进入
        // 时 endDate 是 nil(running),收到第二条同 identifier 的有 endDate
        // 才算结束。我们简单把每条 notification 都当作「最新状态」用,没必要
        // 跟踪 identifier 配对,因为 NSPersistentCloudKitContainer 已经只在
        // 状态切换时 post。
        NotificationCenter.default
            .publisher(for: NSPersistentCloudKitContainer.eventChangedNotification)
            .sink { [weak self] note in
                self?.handleEvent(note)
            }
            .store(in: &cancellables)

        // iCloud 账户变化 —— 用户在系统设置里登入/登出会发这条。
        NotificationCenter.default
            .publisher(for: .CKAccountChanged)
            .sink { [weak self] _ in
                self?.refreshAccountStatus()
            }
            .store(in: &cancellables)

        refreshAccountStatus()
    }

    /// 用户在 Settings 点 "Refresh status" 时手动触发。
    func refreshAccountStatus() {
        let container = CKContainer(identifier: CloudKitConfig.containerIdentifier)
        container.accountStatus { [weak self] status, _ in
            DispatchQueue.main.async {
                self?.accountStatus = Self.map(status)
            }
        }
    }

    private static func map(_ status: CKAccountStatus) -> AccountStatus {
        switch status {
        case .available:               return .available
        case .noAccount:               return .noAccount
        case .restricted:              return .restricted
        case .couldNotDetermine:       return .couldNotDetermine
        case .temporarilyUnavailable:  return .temporarilyUnavailable
        @unknown default:              return .unknown
        }
    }

    private func handleEvent(_ note: Notification) {
        guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event else { return }

        let state: EventState = {
            if event.endDate == nil { return .running }
            if let error = event.error {
                return .failed(message: (error as NSError).localizedDescription)
            }
            return .succeeded
        }()

        switch event.type {
        case .setup:  setupState = state
        case .import: importState = state
        case .export: exportState = state
        @unknown default: break
        }

        // export 成功 = 把本地变更推上去成功;import 成功 = 拉远端变更下来成功。
        // 都算「同步完成」一次,以更晚那次为准。
        if case .succeeded = state, event.type == .import || event.type == .export {
            lastSyncDate = event.endDate
        }
    }
}
