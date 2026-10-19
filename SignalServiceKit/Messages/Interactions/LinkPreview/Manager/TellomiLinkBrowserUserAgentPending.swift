//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// 产品经理批准用 Safari UA 抓页面的主机（和 `mp.weixin.qq.com` 同一份精确白名单）：
/// - 2026-10-19 第一批：京东；百度「需要的话」——实测不需要，不列；
/// - 2026-10-19 第二批：豆瓣移动版、大众点评移动版、QQ 音乐、优酷播放页、快手、爱奇艺。
///
/// Safari UA 的精确白名单（`TellomiLinkFetchContract.browserUserAgentHosts`）在 `bot/link-cards-weixin-ua-r1` 上，还没合进 `tellomi`。
/// 为了不和那条分支在同一个文件里冲突，这里只先记下批准的主机；那条分支合进来以后，把它改成
/// `["mp.weixin.qq.com"].union(TellomiLinkBrowserUserAgentPending.approvedHosts)`（它的测试里写死的集合一起改）。
///
/// 每个平台都列上 Safari UA 会被跳到的那个主机：UA 按每一跳的主机选，跳到不在名单里的主机就换回 `WhatsApp/2`，
/// 页面又会把它跳回去。2026-10-19 本机两种 UA 各抓一遍：
/// - 京东：`item.jd.com` 用 Safari UA 被 302 到 `item.m.jd.com`，拿到商品标题和描述（`WhatsApp/2` 只有京东首页的通用标题）；
/// - QQ 音乐：`i.y.qq.com/v8/playsong.html` → Safari 跳到 `i2.y.qq.com`，有歌名和描述（`WhatsApp/2` 跳到 `y.qq.com`，空页）；
/// - 优酷：`m.youku.com/video/…` 用 Safari 有标题和 og:image（`WhatsApp/2` 被跳到 `v.youku.com`，空页）；
/// - 快手：`m.kuaishou.com`、`www.kuaishou.com/short-video/…` 用 Safari 有标题（`WhatsApp/2` 空页）；
/// - 爱奇艺：`www.iqiyi.com/v_…` 用 Safari 跳到 `m.iqiyi.com`，有这一集的标题（`WhatsApp/2` 是网站的通用标题）；
/// - 豆瓣：`m.douban.com/movie/subject/…` 只有 Safari 有标题、描述和 og:image；
/// - 大众点评：`m.dianping.com` 店铺页 Safari 有标题、描述和图（分享短链两种 UA 都进美团验证页）。
/// 百度（`baidu.com` / `www` / `m`）**不列**：`WhatsApp/2` 已经有标题和描述；百科、贴吧对两种 UA 都回「百度安全验证」。
///
/// 只有发送端真的会抓的主机才用得上：京东、爱奇艺是 `claimed`（2026-10-19 起抓页面）；豆瓣、大众点评、QQ 音乐、优酷、快手
/// 现在还是品牌壳（不抓），要等注册表把它们挪到 `claimed` 才起作用。
public enum TellomiLinkBrowserUserAgentPending {
    public static let approvedHosts: Set<String> = [
        // 京东
        "jd.com",
        "www.jd.com",
        "m.jd.com",
        "item.jd.com",
        "item.m.jd.com",
        // 豆瓣（移动版）
        "m.douban.com",
        // 大众点评（移动版）
        "m.dianping.com",
        // QQ 音乐
        "y.qq.com",
        "i.y.qq.com",
        "i2.y.qq.com",
        // 优酷播放页
        "v.youku.com",
        "m.youku.com",
        // 快手
        "www.kuaishou.com",
        "m.kuaishou.com",
        // 爱奇艺
        "www.iqiyi.com",
        "m.iqiyi.com",
        "iqiyi.com",
    ]
}
