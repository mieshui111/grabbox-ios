import Foundation

/// 自建后端客户端。
///
/// 为什么需要它：iOS 禁止 App 下载并执行外部代码，Android 版那套「打包 libpython + yt-dlp 脚本」
/// 在 iOS 上根本没有对应做法。所以 YouTube / Instagram 这类必须靠服务端 yt-dlp 出结果的平台，
/// 改成「手机只做 HTTP 客户端」——服务端把视频下好、合并好（服务端有 ffmpeg），
/// 回一个可直接下载的 mp4 直链，手机零合并逻辑。
///
/// 服务端协议（`backend/server.mjs` 已实现）：
///   POST {base}/resolve
///   body: {"url": "https://www.youtube.com/watch?v=..."}
///   resp: {"title":"…", "media":[{"url":"http://…/dl/x.mp4","kind":"video","ext":"mp4"}], "error":null}
enum Web2ApiEngine {

    struct RemoteMedia: Decodable {
        let url: String
        let kind: String?
        let ext: String?
    }

    struct RemoteResponse: Decodable {
        let title: String?
        let url: String?
        let kind: String?
        let ext: String?
        let media: [RemoteMedia]?
        let error: String?
    }

    enum RemoteError: LocalizedError {
        case notConfigured
        case badResponse(String)
        case server(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "这个平台需要自建后端：在设置里填上后端地址（例如 http://10.1.1.6:8421），或换成抖音 / 小红书等直连平台"
            case .badResponse(let m): return "后端返回异常：\(m)"
            case .server(let m): return m
            }
        }
    }

    static func resolve(url: URL, base: String) async throws -> (title: String?, media: [MediaItem]) {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let endpoint = URL(string: trimmed.hasSuffix("/") ? trimmed + "resolve" : trimmed + "/resolve") else {
            throw RemoteError.notConfigured
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 120   // 服务端可能要现下现合并，给足时间
        let body: [String: String] = ["url": url.absoluteString]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw RemoteError.server("连不上后端（\(error.localizedDescription)）")
        }
        guard let http = resp as? HTTPURLResponse else { throw RemoteError.badResponse("无有效响应") }
        guard (200...299).contains(http.statusCode) else {
            throw RemoteError.server("后端返回 HTTP \(http.statusCode)")
        }

        let decoded: RemoteResponse
        do {
            decoded = try JSONDecoder().decode(RemoteResponse.self, from: data)
        } catch {
            throw RemoteError.badResponse("返回不是合法 JSON")
        }
        if let err = decoded.error, !err.isEmpty { throw RemoteError.server(err) }

        var items: [MediaItem] = []
        if let list = decoded.media {
            for m in list {
                guard let u = URL(string: m.url) else { continue }
                items.append(MediaItem(url: u, kind: kindOf(m.kind, ext: m.ext)))
            }
        }
        if items.isEmpty, let single = decoded.url, let u = URL(string: single) {
            items.append(MediaItem(url: u, kind: kindOf(decoded.kind, ext: decoded.ext)))
        }
        guard !items.isEmpty else { throw RemoteError.server("后端没返回可下载地址") }
        return (decoded.title, items)
    }

    private static func kindOf(_ kind: String?, ext: String?) -> MediaKind {
        switch kind?.lowercased() {
        case "image": return .image
        case "audio": return .audio
        case "video": return .video
        default: break
        }
        switch ext?.lowercased() {
        case "jpg", "jpeg", "png", "webp", "heic": return .image
        case "mp3", "m4a", "aac", "wav": return .audio
        default: return .video
        }
    }
}
