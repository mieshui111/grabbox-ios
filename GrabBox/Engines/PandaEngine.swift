import Foundation

/// 解析阶段的错误。`LocalizedError` 让 `error.localizedDescription` 直接给人看。
enum PandaError: LocalizedError {
    case network(String)
    case badPage(String)
    case serviceState(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .network(let m): return "连接解析服务失败：\(m)"
        case .badPage(let m): return m
        case .serviceState(let m): return m
        case .empty: return "没解析出下载地址，可能是链接非公开或服务暂时不可用"
        }
    }
}

/// Panda 引擎：调用 dlpanda.com 的解析服务。
///
/// 协议与 Android 版完全一致（同一套逆向结论，2026-10-29 用真实结果页确认）：
///   1. `GET  {BASE}{path}`          → 页面里带 `_token`（CSRF）/ `t0ken` / Set-Cookie
///   2. `POST {BASE}{path}`          → 表单 `_token` + `t0ken` + `url`
///                                     必须 `Accept: text/html` + `X-Requested-With: XMLHttpRequest`
///   3. 返回 HTML 里 `<div data-download-state data-state="success|unsupported|...">`
///      媒体地址写在 `data-download-url`（协议相对、常常没有扩展名）、`<video>`/`<source>`、图集 `<img>`
///   4. 下载时**绝不能带 Referer**（抖音 CDN 见到 Referer 直接掐连接）
///
/// iOS 版没有任何 Python 运行时依赖 —— 解析全在服务端，App 只做 HTTP + 正则，包体反而比 Android 小。
final class PandaEngine {

    static let shared = PandaEngine()

    private let base = "https://dlpanda.com"
    private let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private let session: URLSession

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.httpCookieStorage = .shared
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg)
    }

    // MARK: - 状态码 → 人话

    private static let stateHints: [String: String] = [
        "unsupported": "链接格式不支持，请从原帖「分享 → 复制链接」重新复制",
        "private": "该作品是私密 / 已删除 / 所在地区不可见",
        "rate_limited": "解析服务限流了，等几分钟再试",
        "timeout": "解析超时，重新复制一条新链接再试",
        "network_error": "解析服务连不上平台，检查网络后重试",
        "server_error": "解析服务暂时出错，稍后重试",
        "session_expired": "会话过期，请重试",
        "security_check": "该平台要求人机验证（小红书常见），第三方解析服务过不去",
        "idle": "解析服务没有返回结果"
    ]

    // MARK: - 主流程

    func resolve(path: String, shareURL: String) async throws -> [MediaItem] {
        let pageURL = try url(base + path)

        let pageReq = request(pageURL, accept: "text/html,application/xhtml+xml")
        let (pageData, _) = try await load(pageReq)
        let page = String(decoding: pageData, as: UTF8.self)

        guard var token = firstGroup(#"name="_token"[^>]*value="([^"]+)""#, in: page) else {
            throw PandaError.badPage("解析服务页面异常（未取到 CSRF 令牌）")
        }
        let t0ken = firstGroup(#"name="t0ken"[^>]*value="([^"]*)""#, in: page) ?? ""

        let action = firstGroup(#"<form[^>]*id="dlpanda-download-form"[^>]*action="([^"]*)""#, in: page) ?? ""
        let endpoint: URL
        if action.isEmpty {
            endpoint = pageURL
        } else if action.hasPrefix("http") {
            endpoint = (try? url(action)) ?? pageURL
        } else if action.hasPrefix("/") {
            endpoint = (try? url(base + action)) ?? pageURL
        } else {
            endpoint = pageURL
        }

        var html = try await post(endpoint, refererPath: path, token: token, t0ken: t0ken, shareURL: shareURL)

        // 会话过期 → 换新令牌重试一次
        if extractState(from: html) == "session_expired",
           let fresh = try? await refreshToken() {
            token = fresh
            html = try await post(endpoint, refererPath: path, token: token, t0ken: t0ken, shareURL: shareURL)
        }

        let state = extractState(from: html)
        if let state, state != "success" {
            throw PandaError.serviceState(Self.stateHints[state] ?? "解析失败（\(state)）")
        }

        let media = extractMedia(from: html)
        guard !media.isEmpty else {
            if state == "success" {
                throw PandaError.badPage("解析成功但没找到媒体地址（站点可能改版了）")
            }
            throw PandaError.empty
        }
        return media
    }

    // MARK: - HTTP

    private func request(_ url: URL, accept: String) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue(accept, forHTTPHeaderField: "Accept")
        r.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        return r
    }

    private func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, resp) = try await session.data(for: request)
            guard let http = resp as? HTTPURLResponse else {
                throw PandaError.network("无有效响应")
            }
            return (data, http)
        } catch let e as PandaError {
            throw e
        } catch {
            throw PandaError.network(error.localizedDescription)
        }
    }

    private func post(
        _ endpoint: URL,
        refererPath: String,
        token: String,
        t0ken: String,
        shareURL: String
    ) async throws -> String {
        var r = URLRequest(url: endpoint)
        r.httpMethod = "POST"
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("text/html", forHTTPHeaderField: "Accept")
        r.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        r.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.setValue(base + refererPath, forHTTPHeaderField: "Referer")
        r.setValue(base, forHTTPHeaderField: "Origin")
        r.timeoutInterval = 45

        let form = "_token=\(enc(token))&t0ken=\(enc(t0ken))&url=\(enc(shareURL))"
        r.httpBody = Data(form.utf8)

        let (data, http) = try await load(r)
        let text = String(decoding: data, as: UTF8.self)

        switch http.statusCode {
        case 419: return #"<div data-download-state data-state="session_expired"></div>"#
        case 429: return #"<div data-download-state data-state="rate_limited"></div>"#
        default: break
        }
        guard !text.isEmpty else {
            throw PandaError.network("解析服务无响应（HTTP \(http.statusCode)）")
        }
        return text
    }

    /// `GET /session/csrf` 换新令牌，服务端回 `{"token":"..."}`
    private func refreshToken() async throws -> String? {
        var r = request(try url(base + "/session/csrf"), accept: "application/json")
        r.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        let (data, _) = try await load(r)
        let text = String(decoding: data, as: UTF8.self)
        return firstGroup(#""token"\s*:\s*"([^"]+)""#, in: text)
    }

    // MARK: - 状态

    /// 只读结果元素自身的 `data-state`，避免误把页面里那份「状态说明 JSON」当成结果
    private func extractState(from html: String) -> String? {
        // 模式整体加捕获组：groups() 只收 group1+，没有组会拿到空串
        guard let tag = firstGroup(#"(<[a-zA-Z]+[^>]*data-download-state\b[^>]*>)"#, in: html) else { return nil }
        return firstGroup(#"data-state="([a-z_]+)""#, in: tag)
    }

    // MARK: - 媒体抽取

    /// 从结果 HTML 抽媒体地址。
    ///
    /// 两个实机坑（Android 版 v2.2.2 踩过，这里直接规避）：
    ///  1. 扫 `<img>` 的条件必须是「**没有视频轨**」，不能是「没有任何非图片媒体」——
    ///     抖音图文帖必然带一条 BGM 音轨，用后者会永远扫不到图。
    ///  2. 类型判断要走在 fallback 之前：抖音 BGM 直链（`sf16-ies-music-va.ibytedtos.com/obj/...`）
    ///     没有扩展名也没有 `mime_type`，判不出来就会被当成视频，于是「下个视频还多一个音频」。
    private func extractMedia(from html: String) -> [MediaItem] {
        let scope: String
        if let r = html.range(of: "data-download-shell") {
            scope = String(html[r.lowerBound...])
        } else {
            scope = html
        }

        var ordered: [MediaItem] = []
        var seen = Set<String>()

        func add(_ raw: String?, fallback: MediaKind) {
            guard let url = normalize(raw) else { return }
            if isSiteAsset(url) { return }
            let key = url.absoluteString
            guard !seen.contains(key) else { return }
            seen.insert(key)
            ordered.append(MediaItem(url: url, kind: kindOf(url, fallback: fallback)))
        }

        // 1) 官方保存链接（最可靠）：视频、图文原图、BGM 都在这儿，类型交给 kindOf
        for g in groups(#"data-download-url="([^"]+)""#, in: scope) { add(g[0], fallback: .video) }

        // 2) <source type="video/mp4"|"audio/mp4">
        for g in groups(#"<source[^>]*src="([^"]+)"[^>]*type="(video|audio)/[^"]*""#, in: scope) {
            add(g[0], fallback: g.count > 1 && g[1] == "audio" ? .audio : .video)
        }

        // 3) <video src> / <audio src>
        for g in groups(#"<(video|audio)[^>]*src="([^"]+)""#, in: scope) {
            add(g.count > 1 ? g[1] : nil, fallback: g[0] == "audio" ? .audio : .video)
        }

        // 4) 图集：只在「没有视频轨」时扫图，否则视频页的头像/封面会混进来
        if !ordered.contains(where: { $0.kind == .video }) {
            for g in groups(#"<img\b[^>]*>"#, in: scope) {
                guard let tag = g.first else { continue }
                let raw = firstGroup(#"\sdata-(?:src|original|lazy-src|actualsrc)="([^"]+)""#, in: tag)
                    ?? firstGroup(#"\ssrc="([^"]+)""#, in: tag)
                    ?? firstGroup(#"\ssrcset="\s*([^"\s,]+)"#, in: tag)
                guard let raw else { continue }
                let lower = raw.lowercased()
                if lower.hasPrefix("data:") { continue }
                if Self.junkImageMarkers.contains(where: { lower.contains($0) }) { continue }
                add(raw, fallback: .image)
            }
        }

        // 归一：一个作品只给一种东西（视频 > 图片 > 音频），抖音「视频+原声」不会下两份
        let capped = Array(ordered.prefix(40))
        let videos = capped.filter { $0.kind == .video }
        if !videos.isEmpty { return videos }
        let images = capped.filter { $0.kind == .image }
        if !images.isEmpty { return images }
        return capped.filter { $0.kind == .audio }
    }

    // MARK: - 类型判定

    /// 三层兜底，顺序不能乱：
    ///  1. `mime_type=` / `mime=` 查询参数（CDN 自己标的，最权威）
    ///  2. 域名 / 路径特征（抖音图床、音频站都不带扩展名）
    ///  3. 扩展名
    private func kindOf(_ url: URL, fallback: MediaKind) -> MediaKind {
        let s = url.absoluteString.lowercased()

        if let t = firstGroup(#"mime(?:_type)?=(video|audio|image)(?:%2f|/|_)"#, in: s) {
            switch t {
            case "image": return .image
            case "audio": return .audio
            default: return .video
            }
        }
        if Self.imageHosts.contains(where: { s.contains($0) }) { return .image }
        if Self.audioHosts.contains(where: { s.contains($0) }) { return .audio }
        if test(#"\.(jpe?g|png|webp|gif|heic|heif|bmp|avif|tiff)([?#&]|$)"#, s) { return .image }
        if test(#"\.(mp3|m4a|aac|wav|ogg|oga|flac|opus|amr)([?#&]|$)"#, s) { return .audio }
        if test(#"\.(mp4|m4v|mov|webm|flv|mkv|3gp|ts)([?#&]|$)"#, s) { return .video }
        return fallback
    }

    private static let imageHosts = ["douyinpic.com", "aweme_images", "~tplv-", "sinaimg.cn", "xhscdn.com"]
    private static let audioHosts = ["ies-music", "music-va", "douyinmusic"]
    private static let junkImageMarkers = [
        "favicon", "qrcode", "icon", "avatar", "emoji", "logo",
        "placeholder", "blank.gif", "spacer", "loading", "/static/", "/images/", "/assets/"
    ]

    // MARK: - 小工具

    private func url(_ s: String) throws -> URL {
        guard let u = URL(string: s) else { throw PandaError.network("URL 非法：\(s)") }
        return u
    }

    /// 协议相对（//host/...）补 https，反转义 HTML 实体
    private func normalize(_ raw: String?) -> URL? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        s = s.replacingOccurrences(of: "&amp;", with: "&")
             .replacingOccurrences(of: "&#38;", with: "&")
             .replacingOccurrences(of: "\\/", with: "/")
        if s.hasPrefix("//") { s = "https:" + s }
        guard s.hasPrefix("http") else { return nil }
        return URL(string: s)
    }

    /// 站点自身的图片 / 脚本资源，不是用户要的媒体
    private func isSiteAsset(_ url: URL) -> Bool {
        let s = url.absoluteString.lowercased()
        return s.contains("dlpanda.com/images/") || s.contains("dlpanda.com/static/")
            || s.hasSuffix(".css") || s.hasSuffix(".js")
            || s.contains("googlesyndication") || s.contains("doubleclick")
    }

    /// percent-encode（等价 Android 的 URLEncoder，只是空格用 %20）
    private func enc(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private func groups(_ pattern: String, in text: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        return re.matches(in: text, options: [], range: full).map { m in
            (1..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }

    private func firstGroup(_ pattern: String, in text: String) -> String? {
        groups(pattern, in: text).first?.first
    }

    private func test(_ pattern: String, _ text: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        let full = NSRange(location: 0, length: (text as NSString).length)
        return re.firstMatch(in: text, options: [], range: full) != nil
    }
}
