import Foundation

/// 解析引擎：
///  - `panda`  直连第三方解析站（dlpanda），纯 HTTP，零后端，覆盖抖音 / 小红书 / 快手 / 微博 …
///  - `remote` 转发到自建后端。YouTube / Instagram 那种必须在服务端跑 yt-dlp 的走这里
///             （iOS 禁止 App 内下载可执行代码，Python 运行时这条路走不通）
enum EngineKind: String {
    case panda
    case remote
}

struct Platform: Identifiable, Hashable {
    let id: String
    let label: String
    /// 域名后缀。匹配规则：host == entry 或 host 以 ".entry" 结尾
    let hosts: [String]
    let engine: EngineKind
    /// panda 引擎的站点路由，如 "/douyin"
    let path: String?

    static func == (lhs: Platform, rhs: Platform) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum PlatformCatalog {

    // MARK: - 平台表（与 Android 版 MainActivity.platforms 保持一致）

    static let all: [Platform] = [
        Platform(id: "douyin", label: "抖音",
                 hosts: ["douyin.com", "iesdouyin.com"], engine: .panda, path: "/douyin"),
        Platform(id: "tiktok", label: "TikTok",
                 hosts: ["tiktok.com"], engine: .panda, path: "/"),
        Platform(id: "kuaishou", label: "快手",
                 hosts: ["kuaishou.com", "kwai.com", "kw.ai"], engine: .panda, path: "/kwai"),
        Platform(id: "xiaohongshu", label: "小红书*",
                 hosts: ["xiaohongshu.com", "xhslink.com", "xhslink.cn", "rednote.com"],
                 engine: .panda, path: "/rednote"),
        Platform(id: "weibo", label: "微博",
                 hosts: ["weibo.com", "weibo.cn", "t.cn"], engine: .panda, path: "/weibo"),
        Platform(id: "x", label: "X",
                 hosts: ["x.com", "twitter.com", "t.co"], engine: .panda, path: "/twitter"),
        Platform(id: "xigua", label: "西瓜",
                 hosts: ["ixigua.com"], engine: .panda, path: "/xigua"),
        Platform(id: "threads", label: "Threads",
                 hosts: ["threads.net", "threads.com"], engine: .panda, path: "/threads"),
        Platform(id: "facebook", label: "Facebook",
                 hosts: ["facebook.com", "fb.watch", "fb.me"], engine: .panda, path: "/facebook"),
        Platform(id: "vimeo", label: "Vimeo",
                 hosts: ["vimeo.com"], engine: .panda, path: "/vimeo"),
        Platform(id: "reddit", label: "Reddit",
                 hosts: ["reddit.com", "redd.it"], engine: .panda, path: "/reddit"),
        Platform(id: "pinterest", label: "Pinterest",
                 hosts: ["pinterest.com", "pin.it"], engine: .panda, path: "/pinterest"),
        Platform(id: "snapchat", label: "Snapchat",
                 hosts: ["snapchat.com"], engine: .panda, path: "/snapchat"),
        // 需要在自建后端跑 yt-dlp 的两个
        Platform(id: "youtube", label: "YouTube",
                 hosts: ["youtube.com", "youtu.be"], engine: .remote, path: nil),
        Platform(id: "instagram", label: "Instagram",
                 hosts: ["instagram.com", "instagr.am", "ig.me"], engine: .remote, path: nil)
    ]

    static func platform(for host: String) -> Platform? {
        let h = host.lowercased()
        return all.first { p in
            p.hosts.contains { entry in h == entry || h.hasSuffix("." + entry) }
        }
    }
}

// MARK: - 从任意文本里抽链接

enum LinkDetector {

    /// 分享文案里的零宽字符 / 双向控制符，会干扰匹配
    private static let invisible = CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2060}\u{FEFF}")

    private static let urlPattern =
        #"(?:https?://)?[A-Za-z0-9][A-Za-z0-9.\-]*\.[A-Za-z]{2,6}(?:/[^\s\x{4e00}-\x{9fa5}]*)?"#

    /// NSDataDetector 初始化不便宜，而输入框每敲一个字都会调 detect，所以只建一次
    private static let systemDetector =
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// 找到第一个能识别出平台的链接。返回 (平台, 完整 URL)
    static func detect(_ text: String) -> (Platform, URL)? {
        let cleaned = text.unicodeScalars
            .map { invisible.contains($0) ? " " : String($0) }
            .joined()

        // 先试系统检测器（对 "v.douyin.com/xxx" 这类无 scheme 文本命中率高）
        if let detector = systemDetector {
            let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            for m in detector.matches(in: cleaned, options: [], range: range) {
                guard let raw = m.url else { continue }
                if let hit = match(url: raw) { return hit }
            }
        }

        // 再用正则兜底（NSDataDetector 偶尔会把中文标点一起吃进去）
        guard let re = try? NSRegularExpression(pattern: urlPattern) else { return nil }
        let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
        for m in re.matches(in: cleaned, options: [], range: range) {
            guard let r = Range(m.range, in: cleaned) else { continue }
            var s = String(cleaned[r])
            s = s.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n)]}>，。；,.;!?！？、\"'“”’"))
            if !s.lowercased().hasPrefix("http") { s = "https://" + s }
            if let u = URL(string: s), let hit = match(url: u) { return hit }
        }
        return nil
    }

    private static func match(url: URL) -> (Platform, URL)? {
        guard let host = url.host, let p = PlatformCatalog.platform(for: host) else { return nil }
        return (p, url)
    }
}
