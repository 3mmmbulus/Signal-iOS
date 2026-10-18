//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// 举报页要画什么（纯逻辑，没有界面）：由 `FeedReportState`（`FeedReportStore.state`）算出来，界面只照着画。
/// 两步：先选原因（`reasons`，四组），再填说明 / 关系 / 截图并提交（`form`）。
struct FeedReportPresentation: Equatable {
    enum Phase: Equatable {
        case reasons
        case form
    }

    var phase: Phase
    /// 选原因这一步要画的四组（`FeedReportReasons.groups`）。
    var groups: [FeedReportGroup]
    /// 选中的原因；nil = 还在选。
    var reason: FeedReportReason?
    /// 人身安全相关的原因：先提示「有人处在危险中先报警」（第三节第 32 条）。
    var showsEmergencyNotice: Bool
    /// 「我的权益」下的原因要写和被侵权人的关系。
    var showsRelationship: Bool
    /// 诈骗和「我的权益」下的原因要截图；其它原因不传截图（引擎只认这几类的证据）。
    var showsEvidence: Bool
    var evidenceCount: Int
    var canAddEvidence: Bool
    /// 说明还能再写多少个码点（引擎按码点数限制 500）；组字中可以是负的。
    var detailRemaining: Int
    /// 说明框的高度：最矮 / 最高（再长框里滚动，计数和 12377 提示不会被挤出屏幕）。
    static let detailMinHeight: CGFloat = 120
    static let detailMaxHeight: CGFloat = 160
    /// 大陆区附 12377 举报入口。
    var showsMainlandHotline: Bool
    var canSubmit: Bool
    var isSending: Bool
    /// 提交中、已经提交成功后都不能再改。
    var isEditable: Bool
    var isSent: Bool
    var error: FeedReportState.ReportError?

    init(state: FeedReportState) {
        let reason = state.reason
        phase = reason == nil ? .reasons : .form
        groups = state.groups
        self.reason = reason
        showsEmergencyNotice = reason?.isEmergency ?? false
        showsRelationship = reason?.needsRelationship ?? false
        showsEvidence = reason?.needsEvidence ?? false
        evidenceCount = state.evidence.count
        canAddEvidence = state.evidence.count < FeedReportReason.maxEvidence && !state.sending && !state.sent
        detailRemaining = FeedInputLimit.remaining(state.detail, limit: FeedReportReason.maxDetailChars)
        showsMainlandHotline = state.showMainlandHotline
        canSubmit = state.canSubmit && !state.sent
        isSending = state.sending
        isEditable = !state.sending && !state.sent
        isSent = state.sent
        error = state.error
    }

    /// 说明框该多高、要不要在里面滚：内容高度夹在最矮和最高之间，超过最高才滚。
    static func detailBoxHeight(fitting: CGFloat) -> (height: CGFloat, scrolls: Bool) {
        return (min(max(fitting, detailMinHeight), detailMaxHeight), fitting > detailMaxHeight)
    }

    /// 计数变红：剩 0 个以下（和评论输入框一致：写满了就红；组字中可以是负的）。
    var counterIsRed: Bool { detailRemaining <= 0 }
}
