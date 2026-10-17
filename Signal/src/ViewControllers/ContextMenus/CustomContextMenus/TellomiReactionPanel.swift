//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// 回应条原地展开后的全部表情（tellomi/tellomi 交互审计 A-06，owner 2026-10-17）。
///
/// Telegram 两端在长按菜单里点 ⌄（iOS 也可以往下拉）时，回应条就地长成表情面板，不另弹一层。
/// 面板里的东西和上游的表情 Sheet（`EmojiPickerSheet`）一样：搜索、「回应设置」、按分类的表情网格、分类跳转条，
/// 只是住在回应条的玻璃底板里。
final class TellomiReactionPanel: UIView {

    /// 选中一个表情：表情本身，和它在窗口里的位置 / 字号（给回应飞入用；拿不到就是 nil）。
    var onSelect: ((EmojiWithSkinTones, ReactionFlyIn.Source?) -> Void)?
    /// 点了「回应设置」。
    var onConfigure: (() -> Void)?

    /// 表情网格每格的字号（`EmojiPickerCollectionView` 的 `EmojiCell`）。
    static let gridEmojiFontSize: CGFloat = 32
    static let headerHeight: CGFloat = 52

    private let collectionView: EmojiPickerCollectionView
    private lazy var sectionToolbar = EmojiPickerSectionToolbar(delegate: self)

    private lazy var searchBar: UISearchBar = {
        let searchBar = UISearchBar()
        searchBar.placeholder = OWSLocalizedString("HOME_VIEW_CONVERSATION_SEARCHBAR_PLACEHOLDER", comment: "Placeholder text for search bar which filters conversations.")
        searchBar.delegate = self
        searchBar.searchBarStyle = .minimal
        return searchBar
    }()

    private lazy var configureButton: UIButton = {
        let button = UIButton()
        button.setImage(Theme.iconImage(.emojiSettings), for: .normal)
        button.tintColor = UIColor.Signal.label
        button.accessibilityLabel = OWSLocalizedString("CONFIGURE_REACTIONS", comment: "Configure reactions title text")
        button.addAction(
            UIAction { [weak self] _ in self?.onConfigure?() },
            for: .primaryActionTriggered,
        )
        return button
    }()

    init(message: TSMessage?) {
        collectionView = EmojiPickerCollectionView(message: message)
        super.init(frame: .zero)

        let header = UIStackView(arrangedSubviews: [searchBar, configureButton])
        header.axis = .horizontal
        header.spacing = 8
        header.alignment = .center
        header.isLayoutMarginsRelativeArrangement = true
        header.layoutMargins = UIEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 12)
        addSubview(header)
        header.translatesAutoresizingMaskIntoConstraints = false

        collectionView.pickerDelegate = self
        collectionView.alwaysBounceVertical = true
        addSubview(collectionView)
        collectionView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(sectionToolbar)
        sectionToolbar.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight - 4),

            collectionView.topAnchor.constraint(equalTo: header.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),

            sectionToolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            sectionToolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            sectionToolbar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])

        if #available(iOS 26, *) {
            let scrollInteraction = UIScrollEdgeElementContainerInteraction()
            scrollInteraction.scrollView = collectionView
            scrollInteraction.edge = .bottom
            sectionToolbar.addInteraction(scrollInteraction)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 最后一行表情能滚到分类条上面。
        let bottomInset = sectionToolbar.frame.height + 4
        if collectionView.contentInset.bottom != bottomInset {
            collectionView.contentInset.bottom = bottomInset
            collectionView.verticalScrollIndicatorInsets.bottom = bottomInset
        }
    }

    /// 读屏：展开后焦点先到搜索框。
    var firstAccessibilityElement: UIView { searchBar }
}

// MARK: - EmojiPickerCollectionViewDelegate

extension TellomiReactionPanel: EmojiPickerCollectionViewDelegate {
    func emojiPicker(_ emojiPicker: EmojiPickerCollectionView, didSelectEmoji emoji: EmojiWithSkinTones) {
        var source: ReactionFlyIn.Source?
        if
            let indexPath = emojiPicker.indexPathsForSelectedItems?.first,
            let cell = emojiPicker.cellForItem(at: indexPath),
            let window = cell.window
        {
            source = ReactionFlyIn.Source(frameInWindow: cell.convert(cell.bounds, to: window), fontSize: Self.gridEmojiFontSize)
            emojiPicker.deselectItem(at: indexPath, animated: false)
            // 由飞的那个接着走；面板随后淡出。
            cell.contentView.isHidden = true
        }
        ImpactHapticFeedback.impactOccurred(style: .light)
        searchBar.resignFirstResponder()
        onSelect?(emoji, source)
    }

    func emojiPicker(_ emojiPicker: EmojiPickerCollectionView, didScrollToSection section: EmojiPickerSection) {
        switch section {
        case .messageEmoji, .recentEmoji:
            sectionToolbar.setSelectedSection(0)
        case .emojiCategory(let categoryIndex):
            sectionToolbar.setSelectedSection(categoryIndex + (emojiPicker.hasRecentEmoji ? 1 : 0))
        }
    }

    func emojiPickerWillBeginDragging(_ emojiPicker: EmojiPickerCollectionView) {
        searchBar.resignFirstResponder()
    }
}

// MARK: - EmojiPickerSectionToolbarDelegate

extension TellomiReactionPanel: EmojiPickerSectionToolbarDelegate {
    func emojiPickerSectionToolbar(_ sectionToolbar: EmojiPickerSectionToolbar, didSelectSection section: Int) {
        let finalSection: EmojiPickerSection
        if section == 0, collectionView.hasRecentEmoji {
            finalSection = .recentEmoji
        } else {
            finalSection = .emojiCategory(categoryIndex: section - (collectionView.hasRecentEmoji ? 1 : 0))
        }
        if let searchText = collectionView.searchText, !searchText.isEmpty {
            searchBar.text = nil
            collectionView.searchText = nil
            // 网格要先换回分类再滚。
            collectionView.performBatchUpdates(nil) { _ in
                self.collectionView.scrollToSectionHeader(finalSection, animated: false)
            }
        } else {
            collectionView.scrollToSectionHeader(finalSection, animated: false)
        }
    }

    func emojiPickerSectionToolbarShouldShowRecentsSection(_ sectionToolbar: EmojiPickerSectionToolbar) -> Bool {
        collectionView.hasRecentEmoji
    }
}

// MARK: - UISearchBarDelegate

extension TellomiReactionPanel: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        collectionView.searchText = searchText
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
}
