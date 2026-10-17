//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

public import CoreLocation
import Foundation

/// Tellomi（spec attachment-files-location L-11）：从今天的消息格式里认出「位置消息」。
///
/// 位置消息还没有结构化字段（ADR #1123 / L-9 未写），Signal 各端发的都是「一张地图截图 + 一段文字」，
/// 文字最后一行是 `https://maps.google.com/maps?q=<纬度>,<经度>`（逗号常被编码成 `%2C`）：
/// - Signal-iOS：`地址（多行）` + 空行 + 链接，没有名称（上游 `Location.messageText`）；
/// - Signal-Android：`[名称\n][地址\n]链接`，没有空行（上游 `SignalPlace.getDescription()`；现在名称总是空，老版本选地点时有）；
/// - Tellomi（L-11 起）：选了一个地点发 `名称\n单行地址\n链接`（同 Android 带名称的格式），其它照 Signal-iOS。
///
/// 所以：链接上面隔了空行 → 没有名称、上面全是地址；没隔空行且有两行以上 → 第一行是名称、其余是地址；只有一行 → 地址。
/// 是否「正好一张图」由调用方（`CVComponentState`）判断；这里只看文字。
public struct TellomiLocationMessage: Equatable {
    public let latitude: Double
    public let longitude: Double
    /// 地点名称：只有「选了一个地点」发的才有（Telegram 的 venue）。
    public let name: String?
    /// 一行地址。
    public let address: String?

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// 有名称 = 地点：气泡在图下写名称 + 地址；没有 = 普通位置：只画地图，时间压在图上（Telegram 同）。
    public var isPlace: Bool { name != nil }

    /// 链接上面最多几行字。上游 iOS 的地址最多五六行；再多就当是用户自己写的文字，不改它的样子。
    private static let maxTextLines = 6
    private static let maxLineLength = 300

    public static func parse(body: String) -> TellomiLocationMessage? {
        var lines = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        guard let linkLine = lines.popLast(), let (latitude, longitude) = coordinate(fromMapsLink: linkLine) else {
            return nil
        }

        var hasBlankLineBeforeLink = false
        while lines.last?.isEmpty == true {
            lines.removeLast()
            hasBlankLineBeforeLink = true
        }
        let textLines = lines.filter { !$0.isEmpty }
        guard textLines.count <= maxTextLines, textLines.allSatisfy({ $0.count <= maxLineLength }) else {
            return nil
        }

        let name: String?
        let addressLines: [String]
        if !hasBlankLineBeforeLink, textLines.count >= 2 {
            name = textLines[0]
            addressLines = Array(textLines.dropFirst())
        } else {
            name = nil
            addressLines = textLines
        }
        return TellomiLocationMessage(
            latitude: latitude,
            longitude: longitude,
            name: name,
            address: joinedAddress(addressLines),
        )
    }

    // MARK: - 会话列表、通知、引用回复（spec §3.3.1）

    /// 「位置」：会话列表、通知和引用回复里，位置消息只写这一个词，不写名称、地址和链接。Telegram 两端都这样，地点也一样
    /// （iOS `MessageContentKind` 的 `.location` → `Message.Location`，Android `MessageObject` 的 geo / venue →
    /// `AttachLocation`）。和位置页的标题用同一条文案。
    public static var localizedTitle: String {
        OWSLocalizedString("ATTACHMENT_KEYBOARD_LOCATION", comment: "A button to select a location from the Attachment Keyboard")
    }

    /// 会话列表与通知：「📍 位置」，同别的附件「📷 照片」的写法。
    public static var previewText: String {
        "📍 " + localizedTitle
    }

    /// 引用回复里引用的是不是一条位置：正文认得出、引用的附件是一张静态图（气泡那边的判断在 `CVComponentState.tellomiLocation`，
    /// 引用里看不到别的附件，只能看这两样）。
    public static func isQuotedLocation(body: String?, attachmentMimeType: String?) -> Bool {
        guard
            let body,
            let mimeType = attachmentMimeType,
            MimeTypeUtil.isSupportedImageMimeType(mimeType),
            !MimeTypeUtil.isSupportedDefinitelyAnimatedMimeType(mimeType)
        else {
            return false
        }
        return parse(body: body) != nil
    }

    /// `https://maps.google.com/maps?q=<纬度>,<经度>`（Signal 各端发的那种）里的坐标。整行必须就是这个链接。
    static func coordinate(fromMapsLink line: String) -> (latitude: Double, longitude: Double)? {
        guard
            !line.contains(where: { $0.isWhitespace }),
            let components = URLComponents(string: line),
            let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
            components.host?.lowercased() == "maps.google.com",
            ["", "/", "/maps"].contains(components.path),
            let query = components.queryItems?.first(where: { $0.name == "q" })?.value
        else {
            return nil
        }
        let parts = query.split(separator: ",", omittingEmptySubsequences: false)
        guard
            parts.count == 2,
            let latitude = Double(parts[0].trimmingCharacters(in: .whitespaces)),
            let longitude = Double(parts[1].trimmingCharacters(in: .whitespaces)),
            latitude.isFinite, longitude.isFinite,
            (-90...90).contains(latitude), (-180...180).contains(longitude)
        else {
            return nil
        }
        return (latitude, longitude)
    }

    /// 上游 iOS 的多行地址并成一行：拉丁文字之间用「, 」，两边都是汉字 / 假名 / 谚文时不加（「上海市静安区南京西路」）。
    private static func joinedAddress(_ lines: [String]) -> String? {
        guard var result = lines.first else {
            return nil
        }
        for line in lines.dropFirst() {
            let isCJKJoin = result.last.map(isCJK) == true && line.first.map(isCJK) == true
            result += (isCJKJoin ? "" : ", ") + line
        }
        return result
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
                return true
            default:
                return false
            }
        }
    }
}
