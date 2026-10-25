//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

public struct TextCheckingDataItem: Equatable {
    public enum DataType: UInt, Equatable, CustomStringConvertible {
        case link
        case address
        case phoneNumber
        case date
        case transitInformation
        case emailAddress

        // MARK: - CustomStringConvertible

        public var description: String {
            switch self {
            case .link:
                return ".link"
            case .address:
                return ".address"
            case .phoneNumber:
                return ".phoneNumber"
            case .date:
                return ".date"
            case .transitInformation:
                return ".transitInformation"
            case .emailAddress:
                return ".emailAddress"
            }
        }
    }

    public let dataType: DataType
    public let range: NSRange
    public let snippet: String
    public let url: URL

    /// Tellomi（TF43 P1）：长按链接卡片时用，弹和正文链接同一个链接菜单。
    public static func tellomiLink(url: URL) -> TextCheckingDataItem {
        TextCheckingDataItem(dataType: .link, range: NSRange(location: 0, length: 0), snippet: url.absoluteString, url: url)
    }

    private init(dataType: DataType, range: NSRange, snippet: String, url: URL) {
        self.dataType = dataType
        self.range = range
        self.snippet = snippet
        self.url = url
    }

    // Preserves the entire snippet even though the range is changed;
    // used when overlapping with other tappable attributes but only
    // in a subrange; the non-overlapping subrange remains tappable as
    // if it applied to the whole range.
    func copyInNewRange(_ newRange: NSRange) -> TextCheckingDataItem {
        return TextCheckingDataItem(
            dataType: dataType,
            range: newRange,
            snippet: snippet,
            url: url,
        )
    }

    public static func detectedItems(
        in text: String,
        using detector: NSDataDetector?,
    ) -> [TextCheckingDataItem] {
        guard let detector else {
            return []
        }
        return detector.matches(in: text, options: [], range: text.entireRange).compactMap { match in
            // Tellomi（产品 2026-10-24）：链接在第一个全角中文标点 / 右括号前结束（`TellomiLinkPunctuation`）。
            var matchRange = match.range
            var matchUrl = match.url
            if match.resultType.contains(.link) {
                guard let trimmed = TellomiLinkPunctuation.trimmedLink(range: matchRange, url: matchUrl, in: text, detector: detector) else {
                    return nil
                }
                matchRange = trimmed.range
                matchUrl = trimmed.url
            }

            if match.resultType.contains(.link) {
                // Tellomi（TF43 P1）：「打开baidu.com」从 baidu.com 开始（`TellomiSchemelessLink.leadingCjkLength`）。
                let raw = (text as NSString).substring(with: matchRange)
                let skip = TellomiSchemelessLink.leadingCjkLength(raw)
                if skip > 0 {
                    matchRange = NSRange(location: matchRange.location + skip, length: matchRange.length - skip)
                    let rest = (text as NSString).substring(with: matchRange)
                    matchUrl = URL(string: "http://" + rest) ?? matchUrl
                }
            }

            guard let snippet = (text as NSString).substring(with: matchRange).strippedOrNil else {
                owsFailDebug("Invalid snippet.")
                return nil
            }

            // Tellomi（TF43 P1）：没写协议的链接默认 https，像文件名的不算（`TellomiSchemelessLink`）。
            if match.resultType.contains(.link) {
                guard let resolved = TellomiSchemelessLink.resolve(snippet: snippet, url: matchUrl) else {
                    return nil
                }
                matchUrl = resolved
            }

            let dataType: DataType
            var customUrl: URL?
            let resultType: NSTextCheckingResult.CheckingType = match.resultType
            if resultType.contains(.orthography) {
                return nil
            } else if resultType.contains(.spelling) {
                return nil
            } else if resultType.contains(.grammar) {
                return nil
            } else if resultType.contains(.date) {
                dataType = .date

                // Skip building customUrl if we already have a URL.
                if matchUrl == nil {
                    // NSTextCheckingResult.date is in GMT.
                    guard let gmtDate = match.date else {
                        owsFailDebug("Missing date.")
                        return nil
                    }
                    // "calshow:" URLs expect GMT.
                    let timeInterval = gmtDate.timeIntervalSinceReferenceDate
                    // I'm not sure if there's official docs around these links.
                    guard let calendarUrl = URL(string: "calshow:\(timeInterval)") else {
                        owsFailDebug("Couldn't build calendarUrl.")
                        return nil
                    }
                    customUrl = calendarUrl
                }
            } else if resultType.contains(.address) {
                dataType = .address

                // Skip building a custom URL if we have a match URL.
                if matchUrl == nil {
                    // By default, build a query URL for Apple Maps.
                    customUrl = Self.buildAddressQueryUrl(
                        appScheme: "maps",
                        addressToQuery: snippet,
                    )
                }
            } else if resultType.contains(.link) {
                if
                    let url = matchUrl,
                    url.absoluteString.lowercased().hasPrefix("mailto:"),
                    !snippet.lowercased().hasPrefix("mailto:")
                {
                    dataType = .emailAddress
                } else {
                    dataType = .link
                }
            } else if resultType.contains(.quote) {
                return nil
            } else if resultType.contains(.dash) {
                return nil
            } else if resultType.contains(.replacement) {
                return nil
            } else if resultType.contains(.correction) {
                return nil
            } else if resultType.contains(.regularExpression) {
                return nil
            } else if resultType.contains(.phoneNumber) {
                dataType = .phoneNumber

                // Skip building customUrl if we already have a URL.
                if matchUrl == nil {
                    // https://developer.apple.com/library/archive/featuredarticles/iPhoneURLScheme_Reference/PhoneLinks/PhoneLinks.html
                    let characterSet = CharacterSet(charactersIn: "+0123456789")
                    guard let phoneNumber = snippet.components(separatedBy: characterSet.inverted).joined().nilIfEmpty else {
                        owsFailDebug("Invalid phoneNumber.")
                        return nil
                    }
                    let urlString = "tel:" + phoneNumber
                    guard let phoneNumberUrl = URL(string: urlString) else {
                        owsFailDebug("Couldn't build phoneNumberUrl.")
                        return nil
                    }
                    customUrl = phoneNumberUrl
                }
            } else if resultType.contains(.transitInformation) {
                dataType = .transitInformation

                // Skip building customUrl if we already have a URL.
                if matchUrl == nil {
                    guard
                        let components = match.components,
                        let airline = components[.airline]?.nilIfEmpty,
                        let flight = components[.flight]?.nilIfEmpty
                    else {
                        Logger.warn("Missing components.")
                        return nil
                    }
                    let query = airline + " " + flight
                    guard let urlEncodedQuery = query.encodeURIComponent else {
                        owsFailDebug("Could not URL encode query.")
                        return nil
                    }
                    let urlString = "https://www.google.com/?q=" + urlEncodedQuery
                    guard let transitUrl = URL(string: urlString) else {
                        owsFailDebug("Couldn't build transitUrl.")
                        return nil
                    }
                    customUrl = transitUrl
                }
            } else {
                owsFailDebug("Unknown link type: \(resultType.rawValue)")
                return nil
            }

            guard let url = customUrl ?? matchUrl else {
                owsFailDebug("Missing url: \(dataType).")
                return nil
            }

            return TextCheckingDataItem(
                dataType: dataType,
                range: matchRange,
                snippet: snippet,
                url: url,
            )
        }
    }

    /// Builds a URL for passing the given address to another app to query.
    ///
    /// - Parameter appScheme
    /// A scheme recognized by the app that should handle the address query.
    /// - Parameter addressToQuery
    /// The address the destination app should query.
    /// - Returns
    /// The URL, or `nil` if the URL could not be constructed.
    public static func buildAddressQueryUrl(
        appScheme: String,
        addressToQuery: String,
    ) -> URL? {
        var components = URLComponents()
        components.scheme = appScheme
        components.host = ""
        components.queryItems = [URLQueryItem(
            name: "q",
            value: addressToQuery,
        )]

        return components.url
    }
}
