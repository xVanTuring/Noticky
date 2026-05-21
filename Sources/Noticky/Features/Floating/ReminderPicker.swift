import SwiftUI

/// 铃铛 popover 内容:DatePicker + Set / Clear / Cancel。`currentReminder` 决定
/// 默认显示时间(已设过用上次的,没设过用 1 小时后),以及是否显示 Clear 按钮。
struct ReminderPicker: View {
    let currentReminder: Date?
    let onSet: (Date) -> Void
    let onClear: () -> Void
    let onCancel: () -> Void
    @State private var date: Date

    init(
        currentReminder: Date?,
        onSet: @escaping (Date) -> Void,
        onClear: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.currentReminder = currentReminder
        self.onSet = onSet
        self.onClear = onClear
        self.onCancel = onCancel
        // 默认值:有现成值且在未来 → 用它;否则 1 小时后整点附近。
        // DatePicker 的 `in: Date()...` 范围会拒绝过去时间,所以这里
        // 必须 max(suggested, now + 60s) 确保初值合法。
        let suggested = currentReminder ?? Date().addingTimeInterval(3600)
        let floor = Date().addingTimeInterval(60)
        _date = State(initialValue: max(suggested, floor))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.t(.reminderSetTitle))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            DatePicker(
                "",
                selection: $date,
                in: Date()...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.compact)
            .labelsHidden()

            HStack(spacing: 8) {
                if currentReminder != nil {
                    Button(role: .destructive) {
                        onClear()
                    } label: {
                        Text(L.t(.reminderClear))
                    }
                }
                Spacer()
                Button(L.t(.cancel)) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(L.t(.reminderSet)) { onSet(date) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 280)
    }
}
