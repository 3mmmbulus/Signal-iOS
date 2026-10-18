//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// Tellomi（chat-telegram-parity F03）：跳到日期的日历。有消息的日子才能选（其余灰掉），选了就收起、跳到那天的第一条。
///
/// Telegram 两端点消息之间的日期、搜索栏的日历都能选一天跳过去（安卓 `CalendarActivity` / `AlertsCreator.createCalendarPickerDialog`，
/// iOS `CalendarMessageScreen`）。它们的月历还带每天的图片缩略图；这里先用系统日历（iOS 16 起 `UICalendarView`，iOS 15 `UIDatePicker`），
/// 和安卓 Tellomi 用的 Signal 跳日期选择器一样只管选日子，缩略图记作 F03 的后续。
final class TellomiJumpToDateViewController: OWSViewController {

    private let days: Set<Date>
    private let initialDay: Date
    private let calendar: Calendar
    private let onPick: (Date) -> Void
    private var didPick = false

    init(days: Set<Date>, initialDay: Date, calendar: Calendar = .current, onPick: @escaping (Date) -> Void) {
        self.days = days
        self.initialDay = calendar.startOfDay(for: initialDay)
        self.calendar = calendar
        self.onPick = onPick
        super.init()
    }

    /// 包一层导航栏、按底部弹层弹出。
    static func present(from presenter: UIViewController, days: Set<Date>, initialDay: Date, onPick: @escaping (Date) -> Void) {
        let navigationController = OWSNavigationController(rootViewController: TellomiJumpToDateViewController(days: days, initialDay: initialDay, onPick: onPick))
        if let sheet = navigationController.sheetPresentationController {
            if #available(iOS 16, *) {
                sheet.detents = [.custom { _ in Self.sheetHeight }, .large()]
            } else {
                sheet.detents = [.medium(), .large()]
            }
            sheet.prefersGrabberVisible = true
        }
        presenter.present(navigationController, animated: true)
    }

    /// 弹层高度：放得下一个月（6 行）的日历和导航栏。
    static let sheetHeight: CGFloat = 480

    /// 日历上这一天能不能选：会话里那天有消息。
    static func canSelect(_ components: DateComponents?, days: Set<Date>, calendar: Calendar) -> Bool {
        guard let components, let date = calendar.date(from: components) else {
            return false
        }
        return days.contains(calendar.startOfDay(for: date))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .Signal.groupedBackground
        title = OWSLocalizedString(
            "TELLOMI_JUMP_TO_DATE",
            comment: "Tellomi (chat-telegram-parity F03): title of the calendar that jumps to a day in the conversation, and the search bar's button that opens it.",
        )
        navigationItem.leftBarButtonItem = .cancelButton { [weak self] in
            self?.dismiss(animated: true)
        }

        let today = calendar.startOfDay(for: Date())
        let earliest = days.min() ?? today
        let latest = max(days.max() ?? today, today)

        let content: UIView
        if #available(iOS 16, *) {
            let calendarView = UICalendarView()
            calendarView.calendar = calendar
            calendarView.availableDateRange = DateInterval(start: earliest, end: calendar.date(byAdding: .day, value: 1, to: latest) ?? latest)
            calendarView.visibleDateComponents = calendar.dateComponents([.year, .month, .day], from: initialDay)
            let selection = UICalendarSelectionSingleDate(delegate: self)
            if days.contains(initialDay) {
                selection.selectedDate = calendar.dateComponents([.year, .month, .day], from: initialDay)
            }
            calendarView.selectionBehavior = selection
            content = calendarView
        } else {
            let picker = UIDatePicker()
            picker.datePickerMode = .date
            picker.preferredDatePickerStyle = .inline
            picker.calendar = calendar
            picker.minimumDate = earliest
            picker.maximumDate = latest
            picker.date = initialDay
            picker.addAction(UIAction { [weak self, weak picker] _ in
                guard let self, let picker else { return }
                self.pick(picker.date)
            }, for: .valueChanged)
            content = picker
        }

        view.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            content.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            content.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    private func pick(_ date: Date) {
        guard !didPick else {
            return
        }
        didPick = true
        let day = calendar.startOfDay(for: date)
        let onPick = self.onPick
        dismiss(animated: true) {
            onPick(day)
        }
    }
}

@available(iOS 16, *)
extension TellomiJumpToDateViewController: UICalendarSelectionSingleDateDelegate {
    func dateSelection(_ selection: UICalendarSelectionSingleDate, canSelectDate dateComponents: DateComponents?) -> Bool {
        Self.canSelect(dateComponents, days: days, calendar: calendar)
    }

    func dateSelection(_ selection: UICalendarSelectionSingleDate, didSelectDate dateComponents: DateComponents?) {
        guard let dateComponents, let date = calendar.date(from: dateComponents) else {
            return
        }
        pick(date)
    }
}
