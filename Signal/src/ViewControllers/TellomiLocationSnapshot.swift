//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import MapKit
import SignalServiceKit
import SignalUI

/// Tellomi（spec attachment-files-location L-11）：发送端画位置消息里的那张地图。
///
/// 照 Telegram 气泡里的地图（`ChatMessageMapBubbleContentNode` + `MapResources.fetchMapSnapshotResource`，各自独立实现）：
/// - 宽 × 半宽（300 × 150 pt，Telegram 手机上气泡地图最宽 300、高 = 宽 × 0.5），收到的一端不用再裁；
/// - 跨度 0.003°、不画兴趣点、浅色地图（图会发给别人，不跟发送方的深色模式走）；
/// - 气球形大头针：圆头 + 尖，尖落在这个点上；圆头的颜色和图标同位置页列表（地点按类别，普通位置是主题色 + 大头针）；
///   气球中心在图中心上方 10 pt（Telegram 同），所以这个点在图中心下方一点。
/// 老客户端（Signal、更早的 Tellomi）照样把它当一张图显示。
enum TellomiLocationSnapshot {

    /// 图的大小（pt）；按屏幕倍数出图。
    static let size = CGSize(width: 300, height: 150)

    static let span = MKCoordinateSpan(latitudeDelta: 0.003, longitudeDelta: 0.003)

    struct Pin {
        let color: UIColor
        let symbolName: String

        /// 普通位置（发送当前位置、地图上选的点）。
        static var location: Pin { Pin(color: .Signal.accent, symbolName: "mappin") }

        /// 选的地点：按类别配色和图标（同位置页的列表）。
        static func place(category: MKPointOfInterestCategory?) -> Pin {
            let (symbolName, color) = TellomiLocationIcons.category(category)
            return Pin(color: color, symbolName: symbolName)
        }
    }

    // MARK: - Pin geometry

    static let pinHeadDiameter: CGFloat = 44
    /// 圆头底边到尖的距离。
    static let pinTailLength: CGFloat = 9
    /// 气球（圆头顶到尖）的中心在图中心上方多少（Telegram：大头针中心在图中心上方 10 pt）。
    static let pinCenterAboveMapCenter: CGFloat = 10

    /// 这个点（大头针的尖）应该在图里的什么位置。
    static var tipPoint: CGPoint {
        let pinHeight = pinHeadDiameter + pinTailLength
        return CGPoint(x: size.width / 2, y: size.height / 2 - pinCenterAboveMapCenter + pinHeight / 2)
    }

    // MARK: - Snapshot

    @MainActor
    static func generate(coordinate: CLLocationCoordinate2D, pin: Pin) async throws -> UIImage {
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: mapCenter(forTipAt: coordinate), span: span)
        options.size = size
        options.mapType = .standard
        options.pointOfInterestFilter = .excludingAll
        options.showsBuildings = true
        options.traitCollection = UITraitCollection(userInterfaceStyle: .light)

        let snapshot = try await MKMapSnapshotter(options: options).start()
        return render(map: snapshot.image, tip: snapshot.point(for: coordinate), pin: pin)
    }

    /// 地图中心往北挪一点，让 `coordinate` 落在 `tipPoint`（MapKit 按纬度跨度定比例：图高 = `span.latitudeDelta`）。
    /// 实际落点以截图里算出来的为准（`snapshot.point(for:)`），这里只是让它大致在那儿。
    static func mapCenter(forTipAt coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let point = MKMapPoint(coordinate)
        let north = MKMapPoint(CLLocationCoordinate2D(latitude: min(85, coordinate.latitude + span.latitudeDelta / 2), longitude: coordinate.longitude))
        let south = MKMapPoint(CLLocationCoordinate2D(latitude: max(-85, coordinate.latitude - span.latitudeDelta / 2), longitude: coordinate.longitude))
        let mapPointsPerPoint = (south.y - north.y) / size.height
        let offset = tipPoint.y - size.height / 2
        return MKMapPoint(x: point.x, y: point.y - offset * mapPointsPerPoint).coordinate
    }

    /// 地图 + 尖在 `tip` 的大头针。
    static func render(map: UIImage, tip: CGPoint, pin: Pin) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = map.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            map.draw(in: CGRect(origin: .zero, size: size))
            drawPin(pin, tip: tip, in: context.cgContext)
        }
    }

    static func drawPin(_ pin: Pin, tip: CGPoint, in context: CGContext) {
        let radius = pinHeadDiameter / 2
        let headCenter = CGPoint(x: tip.x, y: tip.y - pinTailLength - radius)

        // 地上的影子：尖下面一个扁圆。
        context.saveGState()
        context.setFillColor(UIColor.black.withAlphaComponent(0.22).cgColor)
        context.fillEllipse(in: CGRect(x: tip.x - 5, y: tip.y - 2, width: 10, height: 4))
        context.restoreGState()

        // 气球：圆头和尖一笔画出来，带一点投影。
        let balloon = UIBezierPath()
        let tailHalfAngle: CGFloat = .pi / 7
        balloon.addArc(
            withCenter: headCenter,
            radius: radius,
            startAngle: .pi / 2 + tailHalfAngle,
            endAngle: .pi / 2 - tailHalfAngle,
            clockwise: true,
        )
        balloon.addLine(to: tip)
        balloon.close()

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 4, color: UIColor.black.withAlphaComponent(0.3).cgColor)
        context.setFillColor(pin.color.cgColor)
        context.addPath(balloon.cgPath)
        context.fillPath()
        context.restoreGState()

        let configuration = UIImage.SymbolConfiguration(pointSize: radius * 0.86, weight: .bold)
        if let glyph = UIImage(systemName: pin.symbolName, withConfiguration: configuration)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
            glyph.draw(at: CGPoint(x: headCenter.x - glyph.size.width / 2, y: headCenter.y - glyph.size.height / 2))
        }
    }
}
