//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/src/ViewControllers/HomeView/Feed/FeedReport.swift (new file)
// Report flow without UI (I-10): request, reason table, state + submit logic. Mirror of Android `report/*`
// (`FeedReportReasons.kt`, `FeedReportTarget.kt`, `FeedReportViewModel.kt`) and `FeedApi.report`.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

/// `POST /v1/feed/reports`（第三节第 32 条）。`targetType` 是 `content` 或 `author`。
struct FeedReportRequest: Encodable, Equatable {
    var targetType: String
    var targetId: String
    var group: String
    var reason: String
    var detail: String?
    var evidenceKeys: [String]?
    var relationship: String?

    static let targetContent = "content"
    static let targetAuthor = "author"

    private enum CodingKeys: String, CodingKey {
        case group, reason, detail, relationship
        case targetType = "target_type"
        case targetId = "target_id"
        case evidenceKeys = "evidence_keys"
    }
}

extension FeedAPI {
    /// 举报一条内容或一个作者。看不到的内容 404（不区分原因）。
    func report(_ request: FeedReportRequest) async throws {
        let body = try Self.encoder.encode(request)
        try await sendNoContent(self.request(path: ["v1", "feed", "reports"], method: "POST", body: body))
    }
}

/// 举报的对象：一条内容，或一个作者（公开主页 id）。
struct FeedReportTarget: Equatable {
    var type: String
    var id: String

    static func content(_ id: String) -> FeedReportTarget { FeedReportTarget(type: FeedReportRequest.targetContent, id: id) }
    static func author(_ profileId: String) -> FeedReportTarget { FeedReportTarget(type: FeedReportRequest.targetAuthor, id: profileId) }
}

/// 举报的一项原因：标题和一句说明（第三节第 32 条「每项一句说明」）。`labelKey` / `descriptionKey` 是本地化键（I-17 加文案）。
struct FeedReportReason: Equatable {
    var group: String
    var code: String
    var labelKey: String
    var descriptionKey: String

    static let groupHarmOthers = "harm_others"
    static let groupIllegal = "illegal"
    static let groupFalse = "false_or_impersonation"
    static let groupMyRights = "my_rights"

    /// 引擎按 Unicode 码点数限制（`utf8.RuneCountInString`：`detail` ≤ 500、`relationship` ≤ 40），不是按「用户看到的字符」；
    /// 国旗 emoji 是 2 个码点、ZWJ 家庭 emoji 最多 7 个。`FeedReportReason.cap(_:codePoints:)` 按码点数截断。
    static let maxDetailChars = FeedInputLimit.reportDetail
    static let maxRelationshipChars = FeedInputLimit.reportRelationship
    static let maxEvidence = 9

    private static let emergency: Set<String> = ["violence_threat", "self_harm", "minor_safety"]

    /// 最多 `codePoints` 个 Unicode 码点，只在字符边界上截（一个字符 = 一串码点，不拆开）。
    static func cap(_ text: String, codePoints: Int) -> String {
        return FeedTextCap.cap(text, codePoints: codePoints)   // 共用实现（I-20）
    }

    /// 诈骗和「我的权益」下的每一项要截图（和引擎 `needsEvidence` 一致）。
    var needsEvidence: Bool { code == "fraud" || group == Self.groupMyRights }
    /// 「我的权益」要写和被侵权人的关系。
    var needsRelationship: Bool { group == Self.groupMyRights }
    /// 人身安全相关：先提示报警（第 32 条「紧急类先提示报警」）。
    var isEmergency: Bool { Self.emergency.contains(code) }
}

/// 一组原因（四组：伤害他人 / 违法违规 / 不实或冒充 / 我的权益）。
struct FeedReportGroup: Equatable {
    var code: String
    var labelKey: String
    var reasons: [FeedReportReason]
}

enum FeedReportReasons {
    private static let groupLabels: [(String, String)] = [
        (FeedReportReason.groupHarmOthers, "TELLOMI_FEED_REPORT_GROUP_HARM_OTHERS"),
        (FeedReportReason.groupIllegal, "TELLOMI_FEED_REPORT_GROUP_ILLEGAL"),
        (FeedReportReason.groupFalse, "TELLOMI_FEED_REPORT_GROUP_FALSE"),
        (FeedReportReason.groupMyRights, "TELLOMI_FEED_REPORT_GROUP_MY_RIGHTS"),
    ]

    /// 客户端认识的原因（有文案的）；引擎的原因表（`config.report_reasons`）决定实际显示哪些。
    static let known: Set<String> = [
        "harassment", "hate", "violence_threat", "self_harm", "minor_safety",
        "fraud", "gambling", "drugs", "pornography", "other_illegal",
        "misinformation", "impersonation", "spam",
        "copyright", "portrait", "privacy", "defamation",
    ]

    /// 引擎没给原因表（老版本、本机样例）时用的，和引擎 `ReportReasons` 一致。组的顺序固定，所以用数组。
    static let defaultTable: [(String, [String])] = [
        (FeedReportReason.groupHarmOthers, ["harassment", "hate", "violence_threat", "self_harm", "minor_safety"]),
        (FeedReportReason.groupIllegal, ["fraud", "gambling", "drugs", "pornography", "other_illegal"]),
        (FeedReportReason.groupFalse, ["misinformation", "impersonation", "spam"]),
        (FeedReportReason.groupMyRights, ["copyright", "portrait", "privacy", "defamation"]),
    ]

    /// 按引擎给的表排出来：组按固定顺序，组内按引擎的顺序；客户端没有文案的原因（引擎新加的）先不显示，免得给用户看代码。
    /// 引擎表是空的就用内置的；一组里一个认识的都没有就整组不显示。
    static func groups(fromConfig config: [String: [String]]) -> [FeedReportGroup] {
        let table: (String) -> [String] = { group in
            if config.isEmpty {
                return defaultTable.first { $0.0 == group }?.1 ?? []
            }
            return config[group] ?? []
        }
        return groupLabels.compactMap { group, labelKey in
            let reasons = table(group).filter { known.contains($0) }.map { code in
                FeedReportReason(
                    group: group,
                    code: code,
                    labelKey: "TELLOMI_FEED_REPORT_\(code.uppercased())",
                    descriptionKey: "TELLOMI_FEED_REPORT_\(code.uppercased())_DESC",
                )
            }
            return reasons.isEmpty ? nil : FeedReportGroup(code: group, labelKey: labelKey, reasons: reasons)
        }
    }
}

struct FeedReportState {
    enum ReportError: Equatable {
        /// 内容已经看不到了。
        case gone
        case failed
    }

    var groups: [FeedReportGroup]
    /// `cn` 时附 12377 入口（第 32 条）。
    var region: String?
    /// nil = 还在选原因。
    var reason: FeedReportReason?
    var detail = ""
    var relationship = ""
    var evidence = [FeedDraftImage]()
    var sending = false
    var sent = false
    var error: ReportError?

    var canSubmit: Bool {
        guard let reason else { return false }
        return !sending
            && (!reason.needsEvidence || !evidence.isEmpty)
            && (!reason.needsRelationship || !relationship.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var showMainlandHotline: Bool { region == "cn" }
}

/// 举报（第三节第 32 条）：先选原因（最上面先分流「只是不想看到」），再补充说明 / 截图 / 关系，最后提交。
/// 截图在提交时才上传：交了就不能撤（引擎把它们标成 attached）。
@MainActor
final class FeedReportStore {
    private let target: FeedReportTarget
    private let source: FeedSource
    private var tasks = [Task<Void, Never>]()

    private(set) var state: FeedReportState {
        didSet { onChange?(state) }
    }
    var onChange: ((FeedReportState) -> Void)?

    init(target: FeedReportTarget, source: FeedSource) {
        self.target = target
        self.source = source
        self.state = FeedReportState(groups: FeedReportReasons.groups(fromConfig: [:]))
    }

    func waitForTasks() async {
        while let task = tasks.first {
            await task.value
            tasks.removeFirst()
        }
    }

    /// 取引擎的原因表和区域（`cn` 要附 12377）；取不到就留着内置的。
    func start() {
        tasks.append(Task { [weak self, source] in
            do {
                let config = try await source.config()
                self?.state.groups = FeedReportReasons.groups(fromConfig: config.reportReasons)
                self?.state.region = config.region
            } catch {
                Logger.warn("feed report config failed, using the built-in reasons: \(error)")
            }
        })
    }

    func pick(_ reason: FeedReportReason) {
        state.reason = reason
        state.error = nil
    }

    /// 回到原因列表；已经填的说明留着。
    func backToReasons() {
        state.reason = nil
    }

    /// 截断按 Unicode 码点数（和引擎一致，2026-10-16 对账 D-2：以前按 Character，国旗 / ZWJ emoji 多的文本会超过引擎的上限被 400）；
    /// 不劈开一个字符（一个 emoji 要么整个留下要么整个去掉）。Android 按 UTF-16 单元 `take`，会劈开 emoji，但不会超过引擎的上限。
    func onDetailChanged(_ text: String) {
        state.detail = FeedReportReason.cap(text, codePoints: FeedReportReason.maxDetailChars)
    }

    func onRelationshipChanged(_ text: String) {
        state.relationship = FeedReportReason.cap(text, codePoints: FeedReportReason.maxRelationshipChars)
    }

    func addEvidence(_ images: [FeedDraftImage]) {
        var next = state.evidence
        for image in images where next.count < FeedReportReason.maxEvidence && !next.contains(image) {
            next.append(image)
        }
        state.evidence = next
    }

    func removeEvidence(_ image: FeedDraftImage) {
        state.evidence.removeAll { $0 == image }
    }

    func submit() {
        let snapshot = state
        guard let reason = snapshot.reason, snapshot.canSubmit else { return }
        state.sending = true
        state.error = nil
        tasks.append(Task { [weak self, source, target] in
            do {
                var keys = [String]()
                if reason.needsEvidence {
                    for image in snapshot.evidence {
                        keys.append(try await source.uploadImage(image.image))
                    }
                }
                let detail = snapshot.detail.trimmingCharacters(in: .whitespacesAndNewlines)
                let request = FeedReportRequest(
                    targetType: target.type,
                    targetId: target.id,
                    group: reason.group,
                    reason: reason.code,
                    detail: detail.isEmpty ? nil : detail,
                    evidenceKeys: keys.isEmpty ? nil : keys,
                    relationship: reason.needsRelationship ? snapshot.relationship.trimmingCharacters(in: .whitespacesAndNewlines) : nil
                )
                try await source.report(request)
                self?.state.sending = false
                self?.state.sent = true
            } catch {
                Logger.warn("feed report failed: \(error)")
                self?.state.sending = false
                self?.state.error = (error as? FeedAPIError)?.status == 404 ? .gone : .failed
            }
        })
    }

    func onErrorShown() {
        state.error = nil
    }
}
