//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Tellomi（tellomi/tellomi#1714，ADR-0079）：照片 / 视频的计时——一次性查看打开后只看 N 秒（3 / 10 / 30）。
///
/// 线上是 `DataMessage.tellomi.viewOnceSeconds`，只和 `isViewOnce = true` 一起有意义；不提协议版本，认不得的老版本照普通一次性查看显示
/// （看一次、不限时）。本机按消息的 `uniqueId` 记在一个 KeyValueStore 里（有计时才有这一项），不给消息表加列、不进备份（§4.5）。
/// 打开照 Signal 一次性查看的流程走（完成、同步 `ViewOnceOpen`、回执），查看器只留 [viewerDuration] 这么久。
public enum TellomiViewOnceTimer {

    /// 只认这几档（ADR-0079 §4.1）；别的值当没有（普通一次性查看）。
    public static let allowedSeconds: [UInt32] = [3, 10, 30]

    private static let store = KeyValueStore(collection: "TellomiViewOnceSeconds")

    public static func isAllowed(_ seconds: UInt32) -> Bool {
        allowedSeconds.contains(seconds)
    }

    /// 收到的 DataMessage 上的计时：一次性查看、而且是认得的那几档才算。
    public static func seconds(from dataMessage: SSKProtoDataMessage) -> UInt32? {
        guard
            dataMessage.hasIsViewOnce, dataMessage.isViewOnce,
            let tellomi = dataMessage.tellomi, tellomi.hasViewOnceSeconds,
            isAllowed(tellomi.viewOnceSeconds)
        else {
            return nil
        }
        return tellomi.viewOnceSeconds
    }

    public static func seconds(messageUniqueId: String, tx: DBReadTransaction) -> UInt32? {
        guard let value = store.getUInt32(messageUniqueId, transaction: tx), isAllowed(value) else { return nil }
        return value
    }

    static func setSeconds(_ seconds: UInt32, messageUniqueId: String, tx: DBWriteTransaction) {
        guard isAllowed(seconds) else { return }
        store.setUInt32(seconds, key: messageUniqueId, transaction: tx)
    }

    /// 收到的一次性查看落库时调（`MessageReceiver`）：有计时就记下来。
    static func markReceived(_ dataMessage: SSKProtoDataMessage, messageUniqueId: String, tx: DBWriteTransaction) {
        guard let seconds = seconds(from: dataMessage) else { return }
        setSeconds(seconds, messageUniqueId: messageUniqueId, tx: tx)
    }

    /// 查看器开多久：照片 N 秒；视频取 max(时长, N)（ADR-0079 §4.3，照 Telegram iOS `MarkMessageContentAsConsumedInteractively`）。
    public static func viewerDuration(seconds: UInt32, videoDuration: TimeInterval?) -> TimeInterval {
        max(TimeInterval(seconds), videoDuration ?? 0)
    }
}
