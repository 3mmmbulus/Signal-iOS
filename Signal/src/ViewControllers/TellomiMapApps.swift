//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import MapKit
import SignalServiceKit

/// Tellomi（spec attachment-files-location L-11）：「路线」和「用其它 App 打开」只列本机装了的地图 App。
///
/// 照 Telegram `OpenInOptions.availableOpenInOptions`（独立实现）：苹果地图总在；别的用 `canOpenURL` 看装没装
/// （URL scheme 要写进 Signal-Info.plist 的 `LSApplicationQueriesSchemes`）；只有一个时直接打开，不弹选择。
/// Telegram 列的是海外常用的（谷歌、Waze、Yandex…），这里换成大陆常用的高德、百度、腾讯，加上谷歌。
///
/// 坐标照原样传（L-10 坐标系未定）：大陆的 MapKit 地图 / 搜索给的是 GCJ-02，所以高德 `dev=0`、百度 `coord_type=gcj02`、
/// 腾讯默认 GCJ-02；境外两者相同。用 CLLocationManager 直接发的「当前位置」（WGS-84）在大陆会偏几百米，等 ADR #1123 定。
struct TellomiMapApp: Equatable {

    enum Kind: CaseIterable {
        case appleMaps
        case amap
        case baidu
        case tencent
        case google
    }

    enum Directions {
        case driving
        case walking
    }

    let kind: Kind

    /// 查是否装了用的 scheme；苹果地图没有（总在）。
    var queryScheme: String? {
        switch kind {
        case .appleMaps: return nil
        case .amap: return "iosamap"
        case .baidu: return "baidumap"
        case .tencent: return "qqmap"
        case .google: return "comgooglemaps"
        }
    }

    /// 各家自己的名字；中文界面写中文名（高德地图…），其它写英文名。品牌名，不进翻译表。
    var displayName: String {
        let isChinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true
        switch kind {
        case .appleMaps: return isChinese ? "Apple 地图" : "Apple Maps"
        case .amap: return isChinese ? "高德地图" : "Amap"
        case .baidu: return isChinese ? "百度地图" : "Baidu Maps"
        case .tencent: return isChinese ? "腾讯地图" : "Tencent Maps"
        case .google: return isChinese ? "谷歌地图" : "Google Maps"
        }
    }

    /// 本机装了的，苹果地图在最前（Telegram 同）。
    static func installed(canOpen: (URL) -> Bool) -> [TellomiMapApp] {
        Kind.allCases.map(TellomiMapApp.init(kind:)).filter { app in
            guard let scheme = app.queryScheme else { return true }
            guard let url = URL(string: "\(scheme)://") else { return false }
            return canOpen(url)
        }
    }

    // MARK: - Opening

    /// 打开这个 App 的链接；苹果地图不用链接（走 `MKMapItem`），返回 nil。
    func url(for location: TellomiLocationMessage, directions: Directions?, fallbackName: String) -> URL? {
        let lat = Self.format(location.latitude)
        let lng = Self.format(location.longitude)
        let name = location.name ?? location.address ?? fallbackName
        var components: URLComponents
        switch kind {
        case .appleMaps:
            return nil
        case .amap:
            // https://lbs.amap.com/api/amap-mobilemap/guide/ios/ios-uri-information
            if let directions {
                components = URLComponents(string: "iosamap://path")!
                components.queryItems = [
                    URLQueryItem(name: "sourceApplication", value: "Tellomi"),
                    URLQueryItem(name: "dlat", value: lat),
                    URLQueryItem(name: "dlon", value: lng),
                    URLQueryItem(name: "dname", value: name),
                    URLQueryItem(name: "dev", value: "0"),
                    URLQueryItem(name: "t", value: directions == .driving ? "0" : "2"),
                ]
            } else {
                components = URLComponents(string: "iosamap://viewMap")!
                components.queryItems = [
                    URLQueryItem(name: "sourceApplication", value: "Tellomi"),
                    URLQueryItem(name: "poiname", value: name),
                    URLQueryItem(name: "lat", value: lat),
                    URLQueryItem(name: "lon", value: lng),
                    URLQueryItem(name: "dev", value: "0"),
                ]
            }
        case .baidu:
            // https://lbsyun.baidu.com/faq/api?title=webapi/uri/ios
            if let directions {
                components = URLComponents(string: "baidumap://map/direction")!
                components.queryItems = [
                    URLQueryItem(name: "destination", value: "name:\(name)|latlng:\(lat),\(lng)"),
                    URLQueryItem(name: "coord_type", value: "gcj02"),
                    URLQueryItem(name: "mode", value: directions == .driving ? "driving" : "walking"),
                    URLQueryItem(name: "src", value: "ios.tellomi.chat"),
                ]
            } else {
                components = URLComponents(string: "baidumap://map/marker")!
                components.queryItems = [
                    URLQueryItem(name: "location", value: "\(lat),\(lng)"),
                    URLQueryItem(name: "title", value: name),
                    URLQueryItem(name: "content", value: location.address ?? name),
                    URLQueryItem(name: "coord_type", value: "gcj02"),
                    URLQueryItem(name: "src", value: "ios.tellomi.chat"),
                ]
            }
        case .tencent:
            // https://lbs.qq.com/webApi/uriV1/uriGuide/uriMobileRoute
            if let directions {
                components = URLComponents(string: "qqmap://map/routeplan")!
                components.queryItems = [
                    URLQueryItem(name: "type", value: directions == .driving ? "drive" : "walk"),
                    URLQueryItem(name: "to", value: name),
                    URLQueryItem(name: "tocoord", value: "\(lat),\(lng)"),
                    URLQueryItem(name: "referer", value: "Tellomi"),
                ]
            } else {
                components = URLComponents(string: "qqmap://map/marker")!
                components.queryItems = [
                    URLQueryItem(name: "marker", value: "coord:\(lat),\(lng);title:\(name);addr:\(location.address ?? name)"),
                    URLQueryItem(name: "referer", value: "Tellomi"),
                ]
            }
        case .google:
            // https://developers.google.com/maps/documentation/urls/ios-urlscheme
            components = URLComponents(string: "comgooglemaps://")!
            if let directions {
                components.queryItems = [
                    URLQueryItem(name: "daddr", value: "\(lat),\(lng)"),
                    URLQueryItem(name: "directionsmode", value: directions == .driving ? "driving" : "walking"),
                ]
            } else {
                components.queryItems = [
                    URLQueryItem(name: "q", value: "\(lat),\(lng)"),
                    URLQueryItem(name: "center", value: "\(lat),\(lng)"),
                ]
            }
        }
        return components.url
    }

    /// 苹果地图：有路线就从「我的位置」导航过去，没有就把这个点标在地图上。
    func appleMapsItem(for location: TellomiLocationMessage, fallbackName: String) -> MKMapItem {
        let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
        mapItem.name = location.name ?? location.address ?? fallbackName
        return mapItem
    }

    @MainActor
    func open(_ location: TellomiLocationMessage, directions: Directions?, fallbackName: String) {
        if kind == .appleMaps {
            let destination = appleMapsItem(for: location, fallbackName: fallbackName)
            if let directions {
                MKMapItem.openMaps(with: [.forCurrentLocation(), destination], launchOptions: [
                    MKLaunchOptionsDirectionsModeKey: directions == .driving ? MKLaunchOptionsDirectionsModeDriving : MKLaunchOptionsDirectionsModeWalking,
                ])
            } else {
                destination.openInMaps()
            }
            return
        }
        guard let url = url(for: location, directions: directions, fallbackName: fallbackName) else {
            owsFailDebug("No link for \(kind).")
            return
        }
        UIApplication.shared.open(url)
    }

    private static func format(_ degrees: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), degrees)
    }
}
