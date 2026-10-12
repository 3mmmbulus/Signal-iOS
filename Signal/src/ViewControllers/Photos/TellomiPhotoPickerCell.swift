//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

/// Tellomi（tellomi/tellomi#1261 P-8，照 Telegram `MediaPickerGridItem` 的格子）：正方形缩略图；右上角编号勾
/// （29 的圆区，离上、右各 3；右上角 44 × 44 整块都算点勾；白色 1.5 描边 + 阴影，选中填强调色并显示第几张）；视频右下角时长；实况照片左上角小图标。
/// 点勾选上 / 取消；点照片本身由网格决定（打开整本相册的查看器，V-1）。
final class TellomiPhotoPickerCell: UICollectionViewCell {

    static let reuseIdentifier = "TellomiPhotoPickerCell"

    private enum Metrics {
        static let checkInset: CGFloat = 3
        /// 右上角这么大一块都算点勾（owner 2026-09-28：29 的触摸区，手指落在圆旁边一点就进了预览）。
        /// 照 Telegram Android `PhotoAttachPhotoCell` 42dp 的 checkFrame，iOS 取 44（系统最小触摸目标）。
        static let checkHitSize: CGFloat = 44
    }

    private let imageView = UIImageView()
    private let durationLabel = UILabel()
    private let livePhotoBadge = UIImageView(image: UIImage(systemName: "livephoto"))
    private let check = TellomiNumberedCheck()

    /// 点了右上角的勾。
    var onCheckTapped: (() -> Void)?

    private(set) var itemId: String?
    private var thumbnailRequest: TellomiPhotoPickerRequest?
    private(set) var selectionNumber: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)

        contentView.backgroundColor = .Signal.secondaryBackground
        contentView.clipsToBounds = true

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        contentView.addSubview(imageView)

        durationLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        durationLabel.textColor = .white
        durationLabel.layer.shadowColor = UIColor.black.cgColor
        durationLabel.layer.shadowOpacity = 0.5
        durationLabel.layer.shadowRadius = 2
        durationLabel.layer.shadowOffset = .zero
        contentView.addSubview(durationLabel)

        livePhotoBadge.tintColor = .white
        livePhotoBadge.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        livePhotoBadge.layer.shadowColor = UIColor.black.cgColor
        livePhotoBadge.layer.shadowOpacity = 0.5
        livePhotoBadge.layer.shadowRadius = 2
        livePhotoBadge.layer.shadowOffset = .zero
        livePhotoBadge.isHidden = true
        contentView.addSubview(livePhotoBadge)

        check.addAction(UIAction { [weak self] _ in self?.onCheckTapped?() }, for: .touchUpInside)
        contentView.addSubview(check)

        setSelectionNumber(nil, accentColor: .Signal.accent, animated: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = contentView.bounds
        let size = contentView.bounds.size
        check.frame = CGRect(
            x: size.width - TellomiNumberedCheck.touchSize - Metrics.checkInset,
            y: Metrics.checkInset,
            width: TellomiNumberedCheck.touchSize,
            height: TellomiNumberedCheck.touchSize,
        )
        let extraHit = Metrics.checkHitSize - TellomiNumberedCheck.touchSize - Metrics.checkInset
        check.hitAreaOutsets = UIEdgeInsets(top: Metrics.checkInset, left: extraHit, bottom: extraHit, right: Metrics.checkInset)
        livePhotoBadge.sizeToFit()
        livePhotoBadge.frame.origin = CGPoint(x: 6, y: 6)
        durationLabel.sizeToFit()
        durationLabel.frame.origin = CGPoint(x: size.width - durationLabel.frame.width - 6, y: size.height - durationLabel.frame.height - 4)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailRequest?.cancel()
        thumbnailRequest = nil
        imageView.image = nil
        itemId = nil
    }

    func configure(
        item: TellomiPhotoPickerItem,
        selectionNumber: Int?,
        accentColor: UIColor,
        library: TellomiPhotoPickerLibrary,
        thumbnailSize: CGSize,
    ) {
        itemId = item.id
        durationLabel.isHidden = !item.isVideo
        livePhotoBadge.isHidden = !item.isLivePhoto
        durationLabel.text = item.isVideo ? Self.formatDuration(item.duration) : nil
        setSelectionNumber(selectionNumber, accentColor: accentColor, animated: false)

        isAccessibilityElement = false
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = .button
        imageView.accessibilityLabel = item.isVideo
            ? String.nonPluralLocalizedStringWithFormat(
                OWSLocalizedString("IMAGE_PICKER_TELLOMI_VIDEO_FORMAT", comment: "Accessibility label for a video in the photo picker. Embeds {{ duration }}."),
                Self.formatDuration(item.duration),
            )
            : OWSLocalizedString("IMAGE_PICKER_TELLOMI_PHOTO", comment: "Accessibility label for a photo in the photo picker.")

        thumbnailRequest?.cancel()
        thumbnailRequest = library.requestThumbnail(for: item, targetSize: thumbnailSize) { [weak self] image in
            guard let self, self.itemId == item.id else { return }
            if let image {
                self.imageView.image = image
            }
        }
        setNeedsLayout()
    }

    func setSelectionNumber(_ number: Int?, accentColor: UIColor, animated: Bool) {
        selectionNumber = number
        check.setNumber(number, accentColor: accentColor, animated: animated)
    }

    /// m:ss；一小时以上 h:mm:ss。
    static func formatDuration(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%d:%02d", minutes, seconds)
    }
}

/// 编号勾（P-8）：29 pt 的触摸区里一个 24 pt 的圆，白色 1.5 pt 描边 + 阴影；没选是半透明的空圈，选中填强调色并显示第几张，
/// 选上时弹一下。选图网格的格子和「只看已选」的卡片共用。
final class TellomiNumberedCheck: UIControl {

    static let touchSize: CGFloat = 29
    static let visualSize: CGFloat = 24
    static let borderWidth: CGFloat = 1.5

    private let circle = UIView()
    private let numberLabel = UILabel()
    private var number: Int?

    /// 触摸区在 frame 之外再往四边扩多少（看得见的圆不动）。选图格子里把右上角整块角区都算进来。
    var hitAreaOutsets: UIEdgeInsets = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)

        circle.isUserInteractionEnabled = false
        circle.layer.cornerRadius = Self.visualSize / 2
        circle.layer.borderWidth = Self.borderWidth
        circle.layer.borderColor = UIColor.white.cgColor
        circle.layer.shadowColor = UIColor.black.cgColor
        circle.layer.shadowOpacity = 0.3
        circle.layer.shadowRadius = 2
        circle.layer.shadowOffset = .zero
        addSubview(circle)

        numberLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        numberLabel.textColor = .white
        numberLabel.textAlignment = .center
        circle.addSubview(numberLabel)

        isAccessibilityElement = true
        accessibilityLabel = OWSLocalizedString("IMAGE_PICKER_TELLOMI_SELECT", comment: "Accessibility label for the numbered check on a photo in the photo picker.")
        setNumber(nil, accentColor: .Signal.accent, animated: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let outsets = hitAreaOutsets
        let hitArea = bounds.inset(by: UIEdgeInsets(top: -outsets.top, left: -outsets.left, bottom: -outsets.bottom, right: -outsets.right))
        return hitArea.contains(point)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = (bounds.width - Self.visualSize) / 2
        circle.frame = CGRect(x: inset, y: (bounds.height - Self.visualSize) / 2, width: Self.visualSize, height: Self.visualSize)
        numberLabel.frame = circle.bounds
    }

    func setNumber(_ number: Int?, accentColor: UIColor, animated: Bool) {
        let wasSelected = self.number != nil
        self.number = number
        numberLabel.text = number.map { "\($0)" }
        circle.backgroundColor = number != nil ? accentColor : UIColor.black.withAlphaComponent(0.12)
        accessibilityTraits = number != nil ? [.button, .selected] : .button
        accessibilityValue = number.map {
            String.nonPluralLocalizedStringWithFormat(
                OWSLocalizedString("IMAGE_PICKER_TELLOMI_SELECTED_NUMBER_FORMAT", comment: "Accessibility value of a selected photo's check in the photo picker. Embeds {{ its place in the selection }}."),
                OWSFormat.formatInt($0),
            )
        }
        if animated, number != nil, !wasSelected {
            circle.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.55, initialSpringVelocity: 0) {
                self.circle.transform = .identity
            }
        }
    }

    var numberTextForTesting: String? { numberLabel.text }
}

#if TESTABLE_BUILD

extension TellomiPhotoPickerCell {
    var checkFrameForTesting: CGRect { check.frame }
    var numberTextForTesting: String? { check.numberTextForTesting }
    var durationTextForTesting: String? { durationLabel.isHidden ? nil : durationLabel.text }
    var isShowingLivePhotoBadgeForTesting: Bool { !livePhotoBadge.isHidden }
    var livePhotoBadgeFrameForTesting: CGRect { livePhotoBadge.frame }

    func tapCheckForTesting() {
        onCheckTapped?()
    }

    /// 在格子坐标里的这一点按下去，落到的是不是勾（和真实点按走同一条 hitTest）。
    func isCheckHitForTesting(at point: CGPoint) -> Bool {
        layoutIfNeeded()
        guard let view = hitTest(point, with: nil) else { return false }
        return view === check || view.isDescendant(of: check)
    }
}

#endif
