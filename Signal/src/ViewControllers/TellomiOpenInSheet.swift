//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

/// Tellomi（spec attachment-files-location L-11）：「用…打开」——本机装了的地图 App 排成一行，点一个就去那儿；
/// 从「分享」进来时下面多「分享」和「复制地址」两个按钮。
///
/// 照 Telegram `OpenInOptionsScreen` 的排法（独立实现）：左上关闭（44，距边 16）、标题「用…打开」居中（semibold 17，
/// 中线 y = 38）、App 一格 80 × 112 从 y = 82 起（图标 64 圆角 16 在 (8, 12)，名字 medium 12 在 y = 80）、少于 5 个时居中
/// （2 个间距 64、3 个 32、其它 8），按钮高 52、左右 30、主题色。
/// 和 Telegram 不同：Telegram 从 App Store 下载各家图标；这里不联网，图标画成各家颜色的方块 + 名字的第一个字。
final class TellomiOpenInSheet: UIViewController {

    struct Action {
        let title: String
        let isPrimary: Bool
        let handler: () -> Void
    }

    private let apps: [TellomiMapApp]
    private let actions: [Action]
    private let onSelect: (TellomiMapApp) -> Void

    init(apps: [TellomiMapApp], actions: [Action], onSelect: @escaping (TellomiMapApp) -> Void) {
        self.apps = apps
        self.actions = actions
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static let optionSize = CGSize(width: 80, height: 112)
    static let optionsTop: CGFloat = 82
    static let buttonHeight: CGFloat = 52
    static let buttonSideInset: CGFloat = 30

    static func optionSpacing(count: Int) -> CGFloat {
        switch count {
        case 2: return 64
        case 3: return 32
        default: return 8
        }
    }

    private let titleLabel = UILabel()
    private let closeButton = UIButton()
    private let scrollView = UIScrollView()
    private(set) var optionButtons = [UIButton]()
    private(set) var actionButtons = [UIButton]()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .Signal.groupedBackground

        titleLabel.text = OWSLocalizedString("LOCATION_VIEW_TELLOMI_OPEN_IN", comment: "Title of the sheet that lists the map apps on this device to open a shared location in.")
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .Signal.label
        titleLabel.textAlignment = .center
        view.addSubview(titleLabel)

        var closeConfiguration: UIButton.Configuration
        if #available(iOS 26, *) {
            closeConfiguration = .glass()
        } else {
            closeConfiguration = .gray()
        }
        closeConfiguration.cornerStyle = .capsule
        closeConfiguration.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        closeConfiguration.baseForegroundColor = .Signal.label
        closeButton.configuration = closeConfiguration
        closeButton.accessibilityLabel = CommonStrings.dismissButton
        closeButton.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .primaryActionTriggered)
        view.addSubview(closeButton)

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        view.addSubview(scrollView)
        for app in apps {
            let button = Self.makeOptionButton(app)
            button.addAction(UIAction { [weak self] _ in self?.didSelect(app) }, for: .primaryActionTriggered)
            scrollView.addSubview(button)
            optionButtons.append(button)
        }

        for action in actions {
            var configuration: UIButton.Configuration
            if action.isPrimary {
                if #available(iOS 26, *) {
                    configuration = .prominentGlass()
                } else {
                    configuration = .filled()
                }
                configuration.baseBackgroundColor = .Signal.accent
                configuration.baseForegroundColor = .white
            } else {
                configuration = .plain()
                configuration.baseForegroundColor = .Signal.accent
            }
            configuration.cornerStyle = .capsule
            var title = AttributedString(action.title)
            title.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
            configuration.attributedTitle = title
            let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true) {
                    action.handler()
                }
            })
            view.addSubview(button)
            actionButtons.append(button)
        }

        if #available(iOS 16, *), let sheet = sheetPresentationController {
            sheet.detents = [.custom(identifier: .init("tellomiOpenIn")) { [weak self] _ in self?.contentHeight }]
            sheet.prefersGrabberVisible = false
        }
    }

    /// 内容高（不含底部安全区；表单自己加上）。
    var contentHeight: CGFloat {
        var height = Self.optionsTop + Self.optionSize.height + 22
        if !actions.isEmpty {
            height += CGFloat(actions.count) * Self.buttonHeight + CGFloat(actions.count - 1) * 8 + 12
        } else {
            height += 8
        }
        return height
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = view.bounds.width

        closeButton.frame = CGRect(x: 16, y: 16, width: 44, height: 44)
        let titleSize = titleLabel.sizeThatFits(CGSize(width: width - 32 - 60 * 2, height: .greatestFiniteMagnitude))
        titleLabel.frame = CGRect(x: (width - titleSize.width) / 2, y: 38 - titleSize.height / 2, width: titleSize.width, height: titleSize.height)

        scrollView.frame = CGRect(x: 0, y: Self.optionsTop, width: width, height: Self.optionSize.height)
        let count = optionButtons.count
        let spacing = Self.optionSpacing(count: count)
        let optionInset: CGFloat = 2
        let rowWidth = CGFloat(count) * Self.optionSize.width + CGFloat(max(0, count - 1)) * spacing
        let startX = count < 5 ? max(0, (width - rowWidth) / 2) : optionInset
        for (index, button) in optionButtons.enumerated() {
            button.frame = CGRect(origin: CGPoint(x: startX + CGFloat(index) * (Self.optionSize.width + spacing), y: 0), size: Self.optionSize)
        }
        scrollView.contentSize = CGSize(width: max(width, rowWidth + optionInset * 2), height: Self.optionSize.height)

        var y = scrollView.frame.maxY + 22
        for button in actionButtons {
            button.frame = CGRect(x: Self.buttonSideInset, y: y, width: width - Self.buttonSideInset * 2, height: Self.buttonHeight)
            y += Self.buttonHeight + 8
        }
    }

    private func didSelect(_ app: TellomiMapApp) {
        dismiss(animated: true) { [onSelect] in
            onSelect(app)
        }
    }

    // MARK: - Options

    private static func makeOptionButton(_ app: TellomiMapApp) -> UIButton {
        let button = UIButton(type: .system)
        button.accessibilityLabel = app.displayName

        let icon = UIImageView(image: icon(for: app))
        icon.frame = CGRect(x: 8, y: 12, width: 64, height: 64)
        icon.layer.cornerRadius = 16
        icon.layer.cornerCurve = .continuous
        icon.clipsToBounds = true
        icon.isUserInteractionEnabled = false
        button.addSubview(icon)

        let label = UILabel(frame: CGRect(x: 0, y: 80, width: optionSize.width, height: 16))
        label.text = app.displayName
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .Signal.label
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.75
        label.isUserInteractionEnabled = false
        button.addSubview(label)
        return button
    }

    /// 不联网取各家图标：各家颜色的圆角方块 + 名字的第一个字（苹果地图画地图图标）。
    static func icon(for app: TellomiMapApp) -> UIImage {
        let size = CGSize(square: 64)
        let color: UIColor
        switch app.kind {
        case .appleMaps: color = UIColor(rgbHex: 0x34C759)
        case .amap: color = UIColor(rgbHex: 0x1A7DFF)
        case .baidu: color = UIColor(rgbHex: 0x4E6EF2)
        case .tencent: color = UIColor(rgbHex: 0x00B386)
        case .google: color = UIColor(rgbHex: 0xEA4335)
        }
        return UIGraphicsImageRenderer(size: size).image { _ in
            color.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            if app.kind == .appleMaps {
                let glyph = UIImage(systemName: "map.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold))?
                    .withTintColor(.white, renderingMode: .alwaysOriginal)
                glyph?.draw(at: CGPoint(x: (size.width - (glyph?.size.width ?? 0)) / 2, y: (size.height - (glyph?.size.height ?? 0)) / 2))
            } else {
                let monogram = String(app.displayName.prefix(1)) as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 28, weight: .semibold),
                    .foregroundColor: UIColor.white,
                ]
                let textSize = monogram.size(withAttributes: attributes)
                monogram.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2), withAttributes: attributes)
            }
        }
    }
}
