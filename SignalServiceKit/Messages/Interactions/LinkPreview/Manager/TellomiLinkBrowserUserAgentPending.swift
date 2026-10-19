//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// 产品经理 2026-10-19 批准：京东、百度「需要的话」可以和 `mp.weixin.qq.com` 一样用 Safari UA 抓页面。
///
/// Safari UA 的精确白名单（`TellomiLinkFetchContract.browserUserAgentHosts`）在 `bot/link-cards-weixin-ua-r1` 上，还没合进 `tellomi`。
/// 为了不和那条分支在同一个文件里冲突，这里只先记下批准的主机；那条分支合进来以后，把它改成
/// `["mp.weixin.qq.com"].union(TellomiLinkBrowserUserAgentPending.approvedHosts)`（它的测试里写死的集合一起改）。
///
/// 只列实测用得上的（2026-10-19 从本机用 `WhatsApp/2` 和 iPhone Safari UA 各抓一遍）：
/// - `item.jd.com`：`WhatsApp/2` 只拿到京东首页的通用标题；Safari UA 被 302 到 `item.m.jd.com`，拿到商品标题和描述；
/// - `jd.com` / `www.jd.com` / `m.jd.com` / `item.m.jd.com`：两种 UA 结果一样，列上是为了京东的页面行为一致；
/// - 百度（`baidu.com` / `www.baidu.com` / `m.baidu.com`）**不列**：`WhatsApp/2` 已经拿到标题和描述，Safari UA 没有多给什么；
///   百科、贴吧对两种 UA 都回「百度安全验证」，换 UA 也没用。
/// 京东现在还是品牌壳（注册表 `links/providers/brand/jd.toml`，不抓），这份名单要等注册表把京东拿出品牌壳以后才起作用。
public enum TellomiLinkBrowserUserAgentPending {
    public static let approvedHosts: Set<String> = [
        "jd.com",
        "www.jd.com",
        "m.jd.com",
        "item.jd.com",
        "item.m.jd.com",
    ]
}
