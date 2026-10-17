//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import MapKit
import SignalServiceKit

/// Tellomi（spec attachment-files-location L-11）：点了聊天里的位置消息。
extension ConversationViewController {

    public func tellomiDidTapLocation(_ location: TellomiLocationMessage, itemViewModel: CVItemViewModelImpl) {
        AssertIsOnMainThread()

        // 位置详情页（地图、距离、路线）接上之前，先在「地图」里打开这个点。
        let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
        mapItem.name = location.name ?? location.address
        mapItem.openInMaps()
    }
}
