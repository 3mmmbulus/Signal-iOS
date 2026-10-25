//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// Tellomi（chat-telegram-parity F03 / 清单 7.2 F03b）：跳到日期的月历。有消息的日子才能选（其余灰掉），选了就收起、跳到那天的第一条。
///
/// 照 Telegram 两端的行为（只看行为，没搬代码）：月份竖着往下排，最新的月在最下面，每天那格铺着当天第一张图片或视频的缩略图，
/// 没有媒体的日子只显示数字。缩略图按月在显示到时才取（`loadThumbnails`），取不到原图时用模糊占位。
final class TellomiJumpToDateViewController: OWSViewController {

    typealias ThumbnailLoader = ([Date]) -> [Date: ReferencedAttachment]

    private let days: Set<Date>
    private let initialDay: Date
    private let calendar: Calendar
    private let loadThumbnails: ThumbnailLoader?
    private let onPick: (Date) -> Void
    private var didPick = false
    private var didScrollToInitialDay = false

    private let months: [TellomiMonthGrid]
    private var requestedMonths = Set<Date>()
    private var thumbnails = [Date: UIImage]()

    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = Self.spacing
        layout.minimumLineSpacing = Self.spacing
        layout.sectionInset = UIEdgeInsets(top: 4, left: 0, bottom: 16, right: 0)
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(TellomiJumpToDateDayCell.self, forCellWithReuseIdentifier: TellomiJumpToDateDayCell.reuseIdentifier)
        collectionView.register(
            TellomiJumpToDateMonthHeader.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: TellomiJumpToDateMonthHeader.reuseIdentifier,
        )
        return collectionView
    }()

    private static let spacing: CGFloat = 4

    init(
        days: Set<Date>,
        initialDay: Date,
        calendar: Calendar = .current,
        loadThumbnails: ThumbnailLoader? = nil,
        onPick: @escaping (Date) -> Void,
    ) {
        self.days = days
        self.initialDay = calendar.startOfDay(for: initialDay)
        self.calendar = calendar
        self.loadThumbnails = loadThumbnails
        self.onPick = onPick
        let today = calendar.startOfDay(for: Date())
        self.months = TellomiMonthGrid.months(
            from: min(days.min() ?? today, self.initialDay),
            to: max(days.max() ?? today, self.initialDay),
            calendar: calendar,
        )
        super.init()
    }

    /// 包一层导航栏、按底部弹层弹出。
    static func present(
        from presenter: UIViewController,
        days: Set<Date>,
        initialDay: Date,
        loadThumbnails: ThumbnailLoader? = nil,
        onPick: @escaping (Date) -> Void,
    ) {
        let viewController = TellomiJumpToDateViewController(days: days, initialDay: initialDay, loadThumbnails: loadThumbnails, onPick: onPick)
        let navigationController = OWSNavigationController(rootViewController: viewController)
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
    static let sheetHeight: CGFloat = 520

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

        let weekdayRow = UIStackView()
        weekdayRow.axis = .horizontal
        weekdayRow.distribution = .fillEqually
        for symbol in TellomiMonthGrid.weekdaySymbols(calendar: calendar) {
            let label = UILabel()
            label.text = symbol
            label.textAlignment = .center
            label.font = .dynamicTypeFootnote
            label.textColor = .Signal.secondaryLabel
            weekdayRow.addArrangedSubview(label)
        }

        view.addSubview(weekdayRow)
        view.addSubview(collectionView)
        weekdayRow.translatesAutoresizingMaskIntoConstraints = false
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            weekdayRow.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            weekdayRow.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            weekdayRow.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            collectionView.topAnchor.constraint(equalTo: weekdayRow.bottomAnchor, constant: 4),
            collectionView.leadingAnchor.constraint(equalTo: weekdayRow.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: weekdayRow.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        guard let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout, collectionView.bounds.width > 0 else {
            return
        }
        let side = floor((collectionView.bounds.width - Self.spacing * 6) / 7)
        let itemSize = CGSize(width: side, height: side)
        if layout.itemSize != itemSize {
            layout.itemSize = itemSize
            layout.headerReferenceSize = CGSize(width: collectionView.bounds.width, height: 40)
            layout.invalidateLayout()
        }

        if !didScrollToInitialDay, let indexPath = indexPath(of: initialDay) {
            didScrollToInitialDay = true
            collectionView.layoutIfNeeded()
            collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
        }
    }

    private func indexPath(of day: Date) -> IndexPath? {
        for (section, month) in months.enumerated() {
            if let item = month.item(of: day, calendar: calendar) {
                return IndexPath(item: item, section: section)
            }
        }
        return nil
    }

    private func day(at indexPath: IndexPath) -> Date? {
        guard months.indices.contains(indexPath.section) else {
            return nil
        }
        return months[indexPath.section].day(at: indexPath.item, calendar: calendar)
    }

    /// 这个月第一次露出来时取缩略图：先查出每天第一张媒体，再逐张异步解出小图。
    private func requestThumbnailsIfNeeded(section: Int) {
        guard let loadThumbnails, months.indices.contains(section) else {
            return
        }
        let month = months[section]
        guard !requestedMonths.contains(month.monthStart) else {
            return
        }
        requestedMonths.insert(month.monthStart)

        let daysInMonth = (0..<month.itemCount).compactMap { month.day(at: $0, calendar: calendar) }.filter { days.contains($0) }
        guard !daysInMonth.isEmpty else {
            return
        }
        let attachments = loadThumbnails(daysInMonth)
        for (day, attachment) in attachments {
            Task { @MainActor [weak self] in
                let image = await attachment.getThumbnailImage(quality: .small)
                guard let self, let image else {
                    return
                }
                self.thumbnails[day] = image
                self.reloadVisibleCell(for: day)
            }
        }
    }

    private func reloadVisibleCell(for day: Date) {
        guard
            let indexPath = indexPath(of: day),
            let cell = collectionView.cellForItem(at: indexPath) as? TellomiJumpToDateDayCell
        else {
            return
        }
        configure(cell, day: day)
    }

    private func configure(_ cell: TellomiJumpToDateDayCell, day: Date?) {
        guard let day else {
            cell.configureBlank()
            return
        }
        let dayNumber = calendar.component(.day, from: day)
        let thumbnail = thumbnails[day]
        let isSelectable = days.contains(day)
        cell.configure(
            dayNumber: dayNumber,
            thumbnail: thumbnail,
            isSelectable: isSelectable,
            isHighlightedDay: day == initialDay,
            isToday: calendar.isDateInToday(day),
        )

        let dateText = DateFormatter.localizedString(from: day, dateStyle: .long, timeStyle: .none)
        if thumbnail != nil {
            let format = OWSLocalizedString(
                "TELLOMI_JUMP_TO_DATE_DAY_HAS_MEDIA_FORMAT",
                comment: "Tellomi (audit 7.2, F03b): accessibility label of a day in the jump-to-date calendar that shows a photo or video thumbnail. Embeds {{ the date }}.",
            )
            cell.accessibilityLabel = String(format: format, dateText)
        } else {
            cell.accessibilityLabel = dateText
        }
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

// MARK: - UICollectionViewDataSource, UICollectionViewDelegate

extension TellomiJumpToDateViewController: UICollectionViewDataSource, UICollectionViewDelegate {

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        months.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        months[section].itemCount
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: TellomiJumpToDateDayCell.reuseIdentifier, for: indexPath)
        if let cell = cell as? TellomiJumpToDateDayCell {
            configure(cell, day: day(at: indexPath))
        }
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath,
    ) -> UICollectionReusableView {
        let view = collectionView.dequeueReusableSupplementaryView(
            ofKind: kind,
            withReuseIdentifier: TellomiJumpToDateMonthHeader.reuseIdentifier,
            for: indexPath,
        )
        if let header = view as? TellomiJumpToDateMonthHeader {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate("yMMMM")
            header.label.text = formatter.string(from: months[indexPath.section].monthStart)
        }
        return view
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        requestThumbnailsIfNeeded(section: indexPath.section)
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard let day = day(at: indexPath) else {
            return false
        }
        return days.contains(day)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let day = day(at: indexPath) else {
            return
        }
        pick(day)
    }
}

// MARK: - Cells

/// 月历里的一天：有缩略图就铺满、数字用白字压在上面；不能选的日子数字灰掉。
private final class TellomiJumpToDateDayCell: UICollectionViewCell {

    static let reuseIdentifier = "TellomiJumpToDateDayCell"

    private let imageView = UIImageView()
    private let dimmingView = UIView()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        contentView.layer.cornerRadius = 8
        contentView.clipsToBounds = true

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        dimmingView.backgroundColor = UIColor.black.withAlphaComponent(0.25)
        label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = true

        for subview in [imageView, dimmingView, label] {
            contentView.addSubview(subview)
            subview.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                subview.topAnchor.constraint(equalTo: contentView.topAnchor),
                subview.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                subview.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                subview.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            ])
        }
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        configureBlank()
    }

    func configureBlank() {
        imageView.image = nil
        imageView.isHidden = true
        dimmingView.isHidden = true
        label.text = nil
        contentView.layer.borderWidth = 0
        contentView.backgroundColor = .clear
        isAccessibilityElement = false
        accessibilityLabel = nil
        accessibilityTraits = []
    }

    func configure(dayNumber: Int, thumbnail: UIImage?, isSelectable: Bool, isHighlightedDay: Bool, isToday: Bool) {
        isAccessibilityElement = true
        imageView.image = thumbnail
        imageView.isHidden = thumbnail == nil
        dimmingView.isHidden = thumbnail == nil
        label.text = "\(dayNumber)"
        let font: UIFont = UIFont.dynamicTypeBody
        label.font = isToday || isHighlightedDay ? font.semibold() : font

        if thumbnail != nil {
            label.textColor = .white
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowOpacity = 0.5
            label.layer.shadowRadius = 2
            label.layer.shadowOffset = .zero
        } else {
            label.textColor = isSelectable ? (isToday ? UIColor.Signal.accent : UIColor.Signal.label) : UIColor.Signal.tertiaryLabel
            label.layer.shadowOpacity = 0
        }

        contentView.backgroundColor = isSelectable && thumbnail == nil ? UIColor.Signal.secondaryGroupedBackground : .clear
        contentView.layer.borderColor = UIColor.Signal.accent.cgColor
        contentView.layer.borderWidth = isHighlightedDay ? 2 : 0
        accessibilityTraits = isSelectable ? .button : .notEnabled
    }
}

private final class TellomiJumpToDateMonthHeader: UICollectionReusableView {

    static let reuseIdentifier = "TellomiJumpToDateMonthHeader"

    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .dynamicTypeHeadline
        label.textColor = .Signal.label
        label.adjustsFontForContentSizeCategory = true
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        accessibilityTraits = .header
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
