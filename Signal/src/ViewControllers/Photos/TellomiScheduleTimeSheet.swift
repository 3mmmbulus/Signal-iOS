//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// Tellomi（tellomi/tellomi#1519 M-4）：「定时发送」的时间选择——底部弹出，日期时间滚轮 + 「今天 / 明天 / 某天 HH:mm 发送」按钮。
///
/// 照 Telegram 两端（只读，代码是自己写的）：
/// - 标题「定时发送」，收藏（Saved Messages）里叫「设置提醒」，按钮字跟着换（iOS `Conversation.SetReminder.*`，安卓 `SetReminder`）；
/// - 最早 = 现在抹掉秒 + 1 分钟，最晚 = 一年后，按分钟选（iOS `ChatScheduleTimeScreen` `next1MinDate` / 365 天；安卓 `minDate = 60000`、天轮 365）；
/// - 打开时默认下一个整 5 分钟（iOS `next5MinDate`：正好是 5 的倍数就再加 5）；
/// - 按钮「今天 X 发送 / 明天 X 发送 / 某天 X 发送」（iOS `SendToday` / `SendTomorrow` / `SendOn`）；
/// - 点的时候已经过了最早时间（选完停了一会儿）就悄悄推到最早（安卓 `checkScheduleDate`）。
/// 滚轮用系统 `UIDatePicker`（`.dateAndTime`、`.wheels`，同 TG iOS 旧版 `ChatScheduleTimeController`；安卓是自己的三个滚轮）。
/// 「静音发送」「对方上线时发送」「重复」不做（spec D4；重复是 TG 付费功能）。
final class TellomiScheduleTimeSheet: UIViewController {

    private let isReminder: Bool
    private let onSchedule: (Date) -> Void
    private let now: () -> Date

    private let titleLabel = UILabel()
    private let datePicker = UIDatePicker()
    private lazy var closeButton: UIButton = {
        var configuration = UIButton.Configuration.gray()
        configuration.image = Theme.iconImage(.buttonX)
        configuration.baseForegroundColor = .Signal.label
        configuration.cornerStyle = .capsule
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        button.accessibilityLabel = CommonStrings.cancelButton
        return button
    }()

    private lazy var confirmButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.baseBackgroundColor = .Signal.accent
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .large
        configuration.buttonSize = .large
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            self?.didTapConfirm()
        })
        return button
    }()

    /// - Parameter isReminder: 收藏（给自己）里叫「设置提醒」。
    init(isReminder: Bool, now: @escaping () -> Date = { Date() }, onSchedule: @escaping (Date) -> Void) {
        self.isReminder = isReminder
        self.now = now
        self.onSchedule = onSchedule
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 底部弹出（系统 sheet，高度贴着内容；字号调大时跟着高，放不下就到最高）。iOS 15 没有自定义高度：用整页。
    func present(from presenter: UIViewController) {
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            if #available(iOS 16.0, *) {
                let width = presenter.view.bounds.width
                sheet.detents = [.custom(identifier: .init("tellomiScheduleTime")) { [weak self] context in
                    guard let self else { return context.maximumDetentValue }
                    return min(self.contentHeight(width: width), context.maximumDetentValue)
                }]
            } else {
                sheet.detents = [.large()]
            }
            sheet.prefersGrabberVisible = false
            sheet.preferredCornerRadius = 24
        }
        presenter.present(self, animated: true)
    }

    /// 内容要多高（不含底部安全区，系统另加）。
    func contentHeight(width: CGFloat) -> CGFloat {
        loadViewIfNeeded()
        let size = view.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel,
        )
        return ceil(size.height)
    }

    // MARK: - Keeping the earliest time fresh

    /// 开着的时候每 15 秒把最早时间往后挪（同 TG iOS 旧版选时间：过去的时间不给选），按钮字跟着变。
    private var refreshTimer: Timer?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMinimumDate() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refreshMinimumDate() {
        let minimum = Self.minimumDate(now: now())
        guard datePicker.minimumDate != minimum else { return }
        datePicker.minimumDate = minimum
        if datePicker.date < minimum {
            datePicker.setDate(minimum, animated: true)
        }
        updateConfirmTitle()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .Signal.groupedBackground

        titleLabel.text = Self.title(isReminder: isReminder)
        titleLabel.font = .dynamicTypeHeadline
        titleLabel.textColor = .Signal.label
        titleLabel.textAlignment = .center
        titleLabel.adjustsFontForContentSizeCategory = true

        let now = now()
        datePicker.datePickerMode = .dateAndTime
        datePicker.preferredDatePickerStyle = .wheels
        datePicker.minuteInterval = 1
        datePicker.minimumDate = Self.minimumDate(now: now)
        datePicker.maximumDate = Self.maximumDate(now: now)
        datePicker.date = Self.defaultDate(now: now)
        datePicker.addAction(UIAction { [weak self] _ in
            self?.refreshMinimumDate()
            self?.updateConfirmTitle()
        }, for: .valueChanged)

        for subview in [closeButton, titleLabel, datePicker, confirmButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        let margins = view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            closeButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            closeButton.widthAnchor.constraint(equalToConstant: 36),
            closeButton.heightAnchor.constraint(equalToConstant: 36),

            titleLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: closeButton.trailingAnchor, constant: 8),

            datePicker.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 16),
            datePicker.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            datePicker.trailingAnchor.constraint(equalTo: margins.trailingAnchor),

            confirmButton.topAnchor.constraint(greaterThanOrEqualTo: datePicker.bottomAnchor, constant: 16),
            confirmButton.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            confirmButton.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            confirmButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
        updateConfirmTitle()
    }

    private func updateConfirmTitle() {
        confirmButton.configuration?.title = Self.confirmTitle(for: datePicker.date, now: now(), isReminder: isReminder)
    }

    private func didTapConfirm() {
        let date = Self.clamped(datePicker.date, now: now())
        let onSchedule = self.onSchedule
        guard presentingViewController != nil else {
            onSchedule(date)
            return
        }
        dismiss(animated: true) { onSchedule(date) }
    }

    // MARK: - Rules

    static func title(isReminder: Bool) -> String {
        isReminder
            ? OWSLocalizedString("TELLOMI_SCHEDULE_SET_REMINDER", comment: "Long-press send menu item and sheet title in Saved Messages (note to self): choose a time to send this note to yourself, as a reminder.")
            : OWSLocalizedString("TELLOMI_SCHEDULE_MESSAGE", comment: "Long-press send menu item and sheet title: choose a time to send this message later.")
    }

    /// 最早：现在抹掉秒 + 1 分钟。
    static func minimumDate(now: Date, calendar: Calendar = .current) -> Date {
        let minute = calendar.dateInterval(of: .minute, for: now)?.start ?? now
        return minute.addingTimeInterval(60)
    }

    /// 最晚：一年（365 天）后。
    static func maximumDate(now: Date) -> Date {
        now.addingTimeInterval(365 * .day)
    }

    /// 默认：下一个整 5 分钟；现在正好在整 5 分钟上就再往后 5 分钟。
    static func defaultDate(now: Date, calendar: Calendar = .current) -> Date {
        let minuteStart = calendar.dateInterval(of: .minute, for: now)?.start ?? now
        let minute = calendar.component(.minute, from: minuteStart)
        let add = minute % 5 == 0 ? 5 : 5 - minute % 5
        return minuteStart.addingTimeInterval(TimeInterval(add) * 60)
    }

    /// 点「发送」时选的时间已经早于最早时间：推到最早（不提示）。
    static func clamped(_ date: Date, now: Date, calendar: Calendar = .current) -> Date {
        max(date, minimumDate(now: now, calendar: calendar))
    }

    static func confirmTitle(for date: Date, now: Date, isReminder: Bool, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let timeFormatter = DateFormatter()
        timeFormatter.locale = locale
        timeFormatter.calendar = calendar
        timeFormatter.timeZone = calendar.timeZone
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short
        let time = timeFormatter.string(from: date)

        if calendar.isDate(date, inSameDayAs: now) {
            return String.nonPluralLocalizedStringWithFormat(
                isReminder
                    ? OWSLocalizedString("TELLOMI_SCHEDULE_REMIND_TODAY_FORMAT", comment: "Button in the reminder time sheet (Saved Messages) when the chosen time is today. Embeds {{time}}.")
                    : OWSLocalizedString("TELLOMI_SCHEDULE_SEND_TODAY_FORMAT", comment: "Button in the schedule time sheet when the chosen time is today. Embeds {{time}}."),
                time,
            )
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return String.nonPluralLocalizedStringWithFormat(
                isReminder
                    ? OWSLocalizedString("TELLOMI_SCHEDULE_REMIND_TOMORROW_FORMAT", comment: "Button in the reminder time sheet (Saved Messages) when the chosen time is tomorrow. Embeds {{time}}.")
                    : OWSLocalizedString("TELLOMI_SCHEDULE_SEND_TOMORROW_FORMAT", comment: "Button in the schedule time sheet when the chosen time is tomorrow. Embeds {{time}}."),
                time,
            )
        }
        let dateFormatter = DateFormatter()
        dateFormatter.locale = locale
        dateFormatter.calendar = calendar
        dateFormatter.timeZone = calendar.timeZone
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .none
        return String.nonPluralLocalizedStringWithFormat(
            isReminder
                ? OWSLocalizedString("TELLOMI_SCHEDULE_REMIND_ON_FORMAT", comment: "Button in the reminder time sheet (Saved Messages) for a day after tomorrow. Embeds {{date}} and {{time}}.")
                : OWSLocalizedString("TELLOMI_SCHEDULE_SEND_ON_FORMAT", comment: "Button in the schedule time sheet for a day after tomorrow. Embeds {{date}} and {{time}}."),
            dateFormatter.string(from: date),
            time,
        )
    }

#if TESTABLE_BUILD
    func refreshMinimumDateForTesting() { refreshMinimumDate() }
    var confirmTitleForTesting: String? { confirmButton.configuration?.title }
    var datePickerForTesting: UIDatePicker { datePicker }
    func tapConfirmForTesting() { didTapConfirm() }
#endif
}
