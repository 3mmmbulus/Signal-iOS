//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import UniformTypeIdentifiers
import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// Tellomi（tellomi/tellomi#1520 C-7）：相机快门上方的胶片条——拍下的按先后排，点一张交回那一张（相机再把预览页停在它上面）。
@MainActor
final class TellomiCaptureFilmstripTests: SignalBaseTest {

    func testShowsEachCaptureAsAPhotoButton() throws {
        let filmstrip = TellomiCaptureFilmstrip()
        let captures = try (0..<3).map { try capture(color: colors[$0]) }

        filmstrip.update(captures: captures, animated: false)

        XCTAssertEqual(filmstrip.itemCount, 3)
        let cells = cellViews(in: filmstrip)
        XCTAssertEqual(cells.count, 3)
        for cell in cells {
            XCTAssertTrue(cell.isAccessibilityElement)
            XCTAssertEqual(cell.accessibilityLabel, CommonStrings.attachmentTypePhoto)
            XCTAssertTrue(cell.accessibilityTraits.contains(.button))
        }
    }

    func testTappingACaptureHandsBackThatOne() throws {
        let filmstrip = TellomiCaptureFilmstrip()
        let captures = try (0..<3).map { try capture(color: colors[$0]) }
        filmstrip.update(captures: captures, animated: false)
        var tapped: [AttachmentApprovalItem] = []
        filmstrip.onTapItem = { tapped.append($0) }

        filmstrip.tapItemForTesting(at: 1)

        XCTAssertEqual(tapped.count, 1)
        XCTAssertTrue(tapped.first === captures[1])
    }

    /// 同一批拍下的再交一次（比如回到相机时）不重建格子；多拍一张才重建。
    func testTheSameCapturesKeepTheirCells() throws {
        let filmstrip = TellomiCaptureFilmstrip()
        let captures = try (0..<2).map { try capture(color: colors[$0]) }
        filmstrip.update(captures: captures, animated: false)
        let before = cellViews(in: filmstrip)

        filmstrip.update(captures: captures, animated: false)
        XCTAssertTrue(zip(before, cellViews(in: filmstrip)).allSatisfy { $0 === $1 })

        filmstrip.update(captures: captures + [try capture(color: colors[2])], animated: false)
        XCTAssertEqual(filmstrip.itemCount, 3)
        XCTAssertEqual(cellViews(in: filmstrip).count, 3)
    }

    func testNothingCapturedLeavesTheStripEmpty() throws {
        let filmstrip = TellomiCaptureFilmstrip()
        filmstrip.update(captures: [try capture(color: colors[0])], animated: false)

        filmstrip.update(captures: [], animated: false)

        XCTAssertEqual(filmstrip.itemCount, 0)
        XCTAssertTrue(cellViews(in: filmstrip).isEmpty)
    }

    /// 给人看的截图（TELLOMI_SHOTS=1 时才跑）：取景框底下、快门上方的样子。写到 `TELLOMI_SHOTS_DIR/<屏宽>/`。
    func testShotOfTheFilmstrip() async throws {
        guard ProcessInfo.processInfo.environment["TELLOMI_SHOTS"] == "1" else {
            throw XCTSkip("只在 TELLOMI_SHOTS=1 时截图")
        }
        let root = ProcessInfo.processInfo.environment["TELLOMI_SHOTS_DIR"] ?? NSTemporaryDirectory()
        let width = UIScreen.main.bounds.size.width
        let directory = URL(fileURLWithPath: root).appendingPathComponent("\(Int(width))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 160))
        let host = UIViewController()
        host.view.backgroundColor = .black
        window.rootViewController = host
        let filmstrip = TellomiCaptureFilmstrip()
        filmstrip.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(filmstrip)
        NSLayoutConstraint.activate([
            filmstrip.leadingAnchor.constraint(equalTo: host.view.leadingAnchor, constant: 16),
            filmstrip.trailingAnchor.constraint(equalTo: host.view.trailingAnchor, constant: -16),
            filmstrip.centerYAnchor.constraint(equalTo: host.view.centerYAnchor),
        ])
        filmstrip.update(captures: try colors.map { try capture(color: $0) }, animated: false)
        window.isHidden = false
        window.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 500_000_000)

        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("camera-capture-filmstrip.png"))
        window.isHidden = true
    }

    // MARK: -

    private let colors: [UIColor] = [.systemTeal, .systemOrange, .systemPurple, .systemGreen, .systemPink]

    private func capture(color: UIColor) throws -> AttachmentApprovalItem {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 90, height: 160)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 90, height: 160))
        }
        let data = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".jpg")
        try data.write(to: url)
        let attachment = try PreviewableAttachment.imageAttachment(
            dataSource: DataSourcePath(fileUrl: url, ownership: .owned),
            dataUTI: UTType.jpeg.identifier,
        )
        return AttachmentApprovalItem(attachment: attachment, canSave: true)
    }

    private func cellViews(in view: UIView) -> [GalleryRailCellView] {
        if let cell = view as? GalleryRailCellView {
            return [cell]
        }
        return view.subviews.flatMap { cellViews(in: $0) }
    }
}
