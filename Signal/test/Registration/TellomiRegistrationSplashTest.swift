//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalUI
import XCTest

@testable import Signal
@testable import SignalServiceKit

/// Tellomi（owner 2026-09-27，`docs/product/BRAND.md`「开屏」、`docs/brand/README.md`「插画」「开屏轮播」）：
/// 欢迎页上面是四张 Open Doodles（黑白）轮播，下面一排小圆点、字标 Tellomi（不放任何句子），不放「协议与隐私政策」链接；
/// 「继续」（苹果原生蓝）「换了新手机？」照旧。
@MainActor
final class TellomiRegistrationSplashTest: SignalBaseTest {

    private final class PresenterSpy: RegistrationSplashPresenter {
        func continueFromSplash() {}
        func setHasOldDevice(_ hasOldDevice: Bool) {}
        func switchToDeviceLinkingMode() {}
    }

    private let illustrationNames = [
        "tellomi_splash_swinging",
        "tellomi_splash_selfie",
        "tellomi_splash_loving",
        "tellomi_splash_float",
    ]

    private func allSubviews(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }

    private func makeSplash() -> (RegistrationSplashViewController, PresenterSpy) {
        let presenter = PresenterSpy()
        let splash = RegistrationSplashViewController(presenter: presenter)
        splash.loadViewIfNeeded()
        splash.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        splash.view.layoutIfNeeded()
        return (splash, presenter)
    }

    private func localized(_ key: String) -> String {
        OWSLocalizedString(key, comment: "")
    }

    private func carousel(in splash: UIViewController) throws -> TellomiSplashCarouselView {
        try XCTUnwrap(allSubviews(of: splash.view).compactMap { $0 as? TellomiSplashCarouselView }.first, "开屏上面是轮播")
    }

    /// 放进一个真窗口里（轮播只在上屏时自动播），不接系统的「减弱动态效果」，由用例指定。
    private func makeCarouselOnScreen(reduceMotion: Bool) -> (UIWindow, TellomiSplashCarouselView) {
        let carousel = TellomiSplashCarouselView(isReduceMotionEnabled: { reduceMotion })
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let root = UIViewController()
        window.rootViewController = root
        root.view.addSubview(carousel)
        carousel.frame = CGRect(x: 0, y: 0, width: 402, height: 420)
        window.makeKeyAndVisible()
        carousel.layoutIfNeeded()
        return (window, carousel)
    }

    // MARK: - 字标、链接、按钮

    func testSplashShowsOnlyTheWordmarkUnderTheCarousel() throws {
        let (splash, _) = makeSplash()
        let views = allSubviews(of: splash.view)

        let wordmark = try XCTUnwrap(
            views.compactMap { $0 as? UIImageView }.first { $0.accessibilityIdentifier == "tellomi.splash.wordmark" },
            "轮播下面是字标",
        )
        XCTAssertNotNil(wordmark.image, "字标资源要在 asset catalog 里")
        XCTAssertTrue(wordmark.isAccessibilityElement)
        XCTAssertEqual(wordmark.accessibilityLabel, "Tellomi")
        // owner 2026-09-27 定稿的字标 Tell@mi（Inter 540 + 图标里的 @）：viewBox 9188.9×2167.5。只约束高度，宽高比取图本身。
        let image = try XCTUnwrap(wordmark.image)
        XCTAssertEqual(Double(image.size.width / image.size.height), 9188.9 / 2167.5, accuracy: 0.01, "字标照旧")
        XCTAssertEqual(Double(wordmark.frame.size.height), 40, accuracy: 0.5, "按高度 40pt 排")

        let carousel = try carousel(in: splash)
        XCTAssertLessThan(
            carousel.convert(carousel.bounds, to: splash.view).maxY,
            wordmark.convert(wordmark.bounds, to: splash.view).minY,
            "字标在轮播下面",
        )

        let titleText = localized("ONBOARDING_SPLASH_TITLE")
        let sentences = views.compactMap { $0 as? UILabel }.filter { $0.text == titleText }
        XCTAssertTrue(sentences.isEmpty, "不放任何句子（「让隐私与您形影不离……」去掉）")
    }

    func testSplashNoLongerHasTheTermsAndPrivacyLink() {
        let (splash, _) = makeSplash()
        let linkTitle = localized("ONBOARDING_SPLASH_TERM_AND_PRIVACY_POLICY")
        let links = allSubviews(of: splash.view).compactMap { $0 as? UIButton }.filter { $0.configuration?.title == linkTitle }
        XCTAssertTrue(links.isEmpty, "「协议与隐私政策」链接去掉（首次打开的隐私提示和号码页勾选里都有）")
    }

    func testSplashKeepsContinueAndNewPhoneLink() {
        let (splash, _) = makeSplash()
        let titles = allSubviews(of: splash.view).compactMap { ($0 as? UIButton)?.configuration?.title }
        XCTAssertTrue(titles.contains(CommonStrings.continueButton), "「继续」照旧")
        XCTAssertTrue(titles.contains(localized("ONBOARDING_SPLASH_NEW_PHONE_LINK_TITLE")), "「换了新手机？」照旧")
    }

    /// owner 2026-09-27：开屏的「继续」保持苹果原生蓝（systemBlue），不用 Signal 的 ultramarine；只改这一个按钮，不动全局 tint。
    func testContinueButtonIsSystemBlue() throws {
        let (splash, _) = makeSplash()
        let continueButton = try XCTUnwrap(
            allSubviews(of: splash.view).compactMap { $0 as? UIButton }.first { $0.configuration?.title == CommonStrings.continueButton },
        )
        XCTAssertEqual(continueButton.configuration?.baseBackgroundColor, UIColor.systemBlue)
    }

    // MARK: - 轮播（docs/brand/README.md「开屏轮播」）

    func testCarouselHasTheFourDoodlesInOrderInBothAppearances() throws {
        XCTAssertEqual(TellomiSplashCarouselView.illustrationNames, illustrationNames, "荡秋千 → 自拍 → 捧心 → 悬浮")

        let (splash, _) = makeSplash()
        let carousel = try carousel(in: splash)
        XCTAssertEqual(carousel.pageImageViews.count, 4)
        for name in illustrationNames {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let image = try XCTUnwrap(
                    UIImage(named: name, in: .main, compatibleWith: UITraitCollection(userInterfaceStyle: style)),
                    "\(name) 要有浅色 / 深色两个外观（\(style.rawValue)）",
                )
                // Open Doodles 原图都是 1024×768。
                XCTAssertEqual(Double(image.size.width / image.size.height), 1024.0 / 768.0, accuracy: 0.01, name)
            }
        }
    }

    func testCarouselTimingConstants() {
        XCTAssertEqual(TellomiSplashCarouselView.autoAdvanceInterval, 3, "每张停 3 秒")
        XCTAssertEqual(TellomiSplashCarouselView.slideDuration, 0.35, accuracy: 0.001)
    }

    func testPageIndicatorHasFourDotsInInkNotAccentBlue() throws {
        let (splash, _) = makeSplash()
        let carousel = try carousel(in: splash)
        XCTAssertEqual(carousel.pageControl.numberOfPages, 4)
        XCTAssertEqual(carousel.pageControl.currentPage, 0)
        let current = try XCTUnwrap(carousel.pageControl.currentPageIndicatorTintColor, "圆点用墨 / 灰，不用系统默认色")
        let others = try XCTUnwrap(carousel.pageControl.pageIndicatorTintColor)
        XCTAssertNotEqual(current, UIColor.Signal.accent)
        XCTAssertNotEqual(others, UIColor.Signal.accent)
    }

    func testCarouselLoopsFromTheLastPageBackToTheFirst() {
        let (window, carousel) = makeCarouselOnScreen(reduceMotion: true)
        defer { window.isHidden = true }
        var pages: [Int] = []
        for _ in 0..<5 {
            carousel.showNextPage(animated: false)
            pages.append(carousel.currentPage)
        }
        XCTAssertEqual(pages, [1, 2, 3, 0, 1], "第 4 张后面接第 1 张")
        XCTAssertEqual(carousel.pageControl.currentPage, 1)
        XCTAssertEqual(carousel.visiblePageImage, UIImage(named: illustrationNames[1]), "画面也跟着到第 2 张")
    }

    func testAutoAdvancesOnScreenAndPausesWhileTouched() throws {
        let (window, carousel) = makeCarouselOnScreen(reduceMotion: false)
        defer { window.isHidden = true }
        let fireDate = try XCTUnwrap(carousel.autoAdvanceFireDate, "上屏就开始自动播")
        XCTAssertEqual(fireDate.timeIntervalSinceNow, 3, accuracy: 0.5)

        carousel.userInteractionBegan()
        XCTAssertNil(carousel.autoAdvanceFireDate, "手指按住时暂停")

        carousel.userInteractionEnded()
        let resumeDate = try XCTUnwrap(carousel.autoAdvanceFireDate, "松手后继续")
        XCTAssertEqual(resumeDate.timeIntervalSinceNow, 3, accuracy: 0.5, "松手 3 秒后继续")

        carousel.removeFromSuperview()
        XCTAssertNil(carousel.autoAdvanceFireDate, "不在屏幕上就不播")
    }

    func testReduceMotionTurnsOffAutoAdvanceButSwipingStillWorks() {
        let (window, carousel) = makeCarouselOnScreen(reduceMotion: true)
        defer { window.isHidden = true }
        XCTAssertNil(carousel.autoAdvanceFireDate, "减弱动态效果时不自动播")
        carousel.userInteractionEnded()
        XCTAssertNil(carousel.autoAdvanceFireDate, "松手后也不自动播")
        XCTAssertTrue(carousel.scrollView.isScrollEnabled, "只能手动滑")
        XCTAssertTrue(carousel.scrollView.isPagingEnabled)
    }

    func testIllustrationsAreHiddenFromVoiceOver() throws {
        let (splash, _) = makeSplash()
        let carousel = try carousel(in: splash)
        XCTAssertTrue(carousel.accessibilityElementsHidden, "插画是装饰，读屏跳过（整页读字标「Tellomi」）")
    }

    // MARK: - 旧插画不再用

    func testOldIllustrationsAreGone() {
        XCTAssertNil(UIImage(named: "tellomi_splash_casual_chat"), "unDraw 那张删掉")
        XCTAssertNil(UIImage(named: "onboarding_splash_hero"), "Signal 原版插画删掉")
    }

    /// iPad 关联设备的欢迎页（ProvisioningSplashViewController）是另一页：插画换成第一张 Open Doodles，静态。
    func testIPadProvisioningSplashUsesTheFirstDoodle() throws {
        let splash = ProvisioningSplashViewController(provisioningController: .preview())
        splash.loadViewIfNeeded()
        let hero = try XCTUnwrap(
            allSubviews(of: splash.view).compactMap { $0 as? UIImageView }.first { $0.accessibilityIdentifier == "tellomi.provisioningSplash.illustration" },
        )
        XCTAssertEqual(hero.image, UIImage(named: "tellomi_splash_swinging"))
        XCTAssertTrue(hero.accessibilityElementsHidden, "插画是装饰")
    }
}
