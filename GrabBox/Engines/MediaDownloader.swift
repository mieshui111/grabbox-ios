import Foundation

struct DownloadedFile {
    let fileURL: URL
    let kind: MediaKind
    let mime: String
    let ext: String

    var isImage: Bool { mime.hasPrefix("image/") }
}

enum DownloadError: LocalizedError {
    case network(String)
    case http(Int)
    case notMedia(String)
    case sizeMismatch(Int64, Int64)
    case disk(String)

    var errorDescription: String? {
        switch self {
        case .network(let m): return "连接失败：\(m)"
        case .http(let code):
            if code == 403 { return "HTTP 403（CDN 拒绝直链，可能已过期或需要登录）" }
            return "HTTP \(code)（链接可能已过期）"
        case .notMedia(let t): return "返回的不是媒体文件（\(t)）"
        case .sizeMismatch(let got, let want): return "下载不完整（\(got)/\(want) 字节），重试一次"
        case .disk(let m): return "写文件失败：\(m)"
        }
    }
}

/// 下载器。全部用静态方法：避免跨并发域的 `self` 捕获，多段并发时也不用担心状态共享。
///
/// 三条硬规则（Android 版实测得出，这里照搬）：
///  1. **Referer 按平台给**：抖音系绝对不能带，B站/微博/小红书必须带
///  2. **必须用 Range 分段**：B站 PCDN 一次拉整个文件返回 403，分块请求才是 206
///  3. **必须校验文件头**：直链没有扩展名，服务异常时会返回 HTML 页面，只有嗅探才能确认真是媒体
enum MediaDownloader {

    static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// 与 BiliEngine 一致的 UA（B 站对 UA 有偏好）
    static let biliUA =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) " +
        "Chrome/131.0.0.0 Safari/537.36"

    static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 900
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.allowsExpensiveNetworkAccess = true
        return URLSession(configuration: cfg)
    }()

    /// 多段并发完成回调来自不同线程，计数必须加锁，否则进度会丢
    private final class ProgressBox {
        private let lock = NSLock()
        private var done: Int64
        private let total: Int64
        private let sink: (Double) -> Void

        init(start: Int64, total: Int64, sink: @escaping (Double) -> Void) {
            self.done = start
            self.total = total
            self.sink = sink
        }

        func add(_ n: Int64) {
            lock.lock()
            done += n
            let current = done
            lock.unlock()
            let p = total > 0 ? Double(current) / Double(total) : 0
            sink(min(max(p, 0), 1))
        }

        func report(_ value: Double) {
            sink(min(max(value, 0), 1))
        }
    }

    private static let headSize: Int64 = 64 * 1024
    private static let minPartSize: Int64 = 4 * 1024 * 1024
    private static let maxParts = 12
    private static let concurrency = 4

    // MARK: - 主流程

    /// 下载到 `workDir`，返回落盘文件。失败抛 `DownloadError`。
    static func download(
        _ item: MediaItem,
        workDir: URL,
        onProgress: @escaping (Double) -> Void
    ) async throws -> DownloadedFile {

        let referer = refererFor(item.url)
        let probe = try await probe(item, referer: referer)

        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let dest = workDir.appendingPathComponent("grab_\(stamp).part")
        try? FileManager.default.removeItem(at: dest)
        guard FileManager.default.createFile(atPath: dest.path, contents: nil) else {
            throw DownloadError.disk("无法创建临时文件")
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: dest)
        } catch {
            throw DownloadError.disk(error.localizedDescription)
        }
        // 中途抛错也要把句柄还回去；正常路径先 close，这里的第二次 close 被 try? 吞掉
        defer { try? handle.close() }
        try handle.write(contentsOf: probe.head)

        let total = probe.total
        let box = ProgressBox(start: Int64(probe.head.count), total: total, sink: onProgress)
        box.report(total > 0 ? min(Double(probe.head.count) / Double(total), 1) : 0.05)

        if total > Int64(probe.head.count) {
            let ranges = planRanges(from: Int64(probe.head.count), to: total)
            let parts = ranges.map { dest.appendingPathExtension("p\($0.0)") }

            // 各段写各自的临时文件，最后按序拼接 —— 避免多个 FileHandle 抢同一个写入指针
            try await fetchParts(item.url, ranges: ranges, referer: referer, into: parts) { bytes in
                box.add(bytes)
            }

            for p in parts {
                do {
                    let data = try Data(contentsOf: p, options: .mappedIfSafe)
                    try handle.write(contentsOf: data)
                } catch {
                    try? FileManager.default.removeItem(at: p)
                    try? handle.close()
                    throw DownloadError.disk(error.localizedDescription)
                }
                try? FileManager.default.removeItem(at: p)
            }
        }

        try? handle.close()

        if let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
           let size = (attrs[.size] as? NSNumber)?.int64Value,
           total > 0, size != total {
            throw DownloadError.sizeMismatch(size, total)
        }

        box.report(1)
        let ext = fileExtension(for: probe.mime)
        let named = workDir.appendingPathComponent("grab_\(stamp).\(ext)")
        try? FileManager.default.removeItem(at: named)
        do {
            try FileManager.default.moveItem(at: dest, to: named)
        } catch {
            throw DownloadError.disk(error.localizedDescription)
        }
        return DownloadedFile(fileURL: named, kind: item.kind, mime: probe.mime, ext: ext)
    }

    // MARK: - 首段探测（类型 + 总大小）

    private struct Probe {
        let total: Int64
        let contentType: String
        let mime: String
        let head: Data
    }

    private static func probe(_ item: MediaItem, referer: String?) async throws -> Probe {
        var req = baseRequest(item.url, referer: referer)
        req.setValue("bytes=0-\(headSize - 1)", forHTTPHeaderField: "Range")
        req.timeoutInterval = 30

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw DownloadError.network(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw DownloadError.network("无有效响应") }
        guard (200...299).contains(http.statusCode) else { throw DownloadError.http(http.statusCode) }

        var total: Int64 = -1
        if http.statusCode == 206,
           let range = http.value(forHTTPHeaderField: "Content-Range"),
           let tail = range.split(separator: "/").last,
           let n = Int64(tail) {
            total = n
        } else if http.expectedContentLength > 0 {
            // 服务端忽略了 Range，这段就是整个文件
            total = http.expectedContentLength
        }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        guard let mime = sniffHead(data, contentType: contentType, declared: item.kind) else {
            throw DownloadError.notMedia(contentType.isEmpty ? "未知类型" : contentType)
        }
        if total < 0 { total = Int64(data.count) }
        return Probe(total: total, contentType: contentType, mime: mime, head: data)
    }

    // MARK: - 分段

    private static func planRanges(from start: Int64, to total: Int64) -> [(Int64, Int64)] {
        let remaining = total - start
        guard remaining > 0 else { return [] }
        let partSize = max(minPartSize, remaining / Int64(maxParts))
        var ranges: [(Int64, Int64)] = []
        var s = start
        while s < total && ranges.count < maxParts * 2 {
            let e = Swift.min(s + partSize, total) - 1
            ranges.append((s, e))
            s = e + 1
        }
        return ranges
    }

    /// 限并发拉多个区间，每段落一个文件。`onBytes` 收到的是该段完成后的一次性字节数。
    private static func fetchParts(
        _ url: URL,
        ranges: [(Int64, Int64)],
        referer: String?,
        into parts: [URL],
        onBytes: @escaping (Int64) -> Void
    ) async throws {

        try await withThrowingTaskGroup(of: Int.self) { group in
            var next = 0
            var active = 0

            // 条件是「还有没派的」或「还有没收的」—— 只看 next 会让收尾几段的进度丢失
            while next < ranges.count || active > 0 {
                while active < concurrency && next < ranges.count {
                    let index = next
                    let (from, to) = ranges[index]
                    let target = parts[index]
                    group.addTask {
                        try await fetchRange(url, from: from, to: to, referer: referer, toFile: target)
                        return index
                    }
                    next += 1
                    active += 1
                }
                guard active > 0 else { break }
                if let finished = try await group.next() {
                    active -= 1
                    let r = ranges[finished]
                    onBytes(r.1 - r.0 + 1)
                }
            }
        }
    }

    private static func fetchRange(
        _ url: URL,
        from: Int64,
        to: Int64,
        referer: String?,
        toFile dest: URL
    ) async throws {
        var req = baseRequest(url, referer: referer)
        req.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
        req.timeoutInterval = 120

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw DownloadError.network(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw DownloadError.network("无有效响应") }
        guard (200...299).contains(http.statusCode) else { throw DownloadError.http(http.statusCode) }
        do {
            try data.write(to: dest)
        } catch {
            throw DownloadError.disk(error.localizedDescription)
        }
    }

    private static func baseRequest(_ url: URL, referer: String?) -> URLRequest {
        var r = URLRequest(url: url)
        let useBiliUA = referer == "https://www.bilibili.com/"
        r.setValue(useBiliUA ? biliUA : userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("*/*", forHTTPHeaderField: "Accept")
        if let referer {
            r.setValue(referer, forHTTPHeaderField: "Referer")
        }
        return r
    }

    // MARK: - Referer 策略

    /// 各平台 CDN 对 Referer 的偏好完全相反：
    ///  - 抖音系：**绝对不能带**（带了直接掐连接）
    ///  - B站 / 微博 / 小红书：**必须带**
    ///  - 其余签名直链：不校验，一律不带
    static func refererFor(_ url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        if host.contains("douyin") || host.contains("zjcdn") || host.contains("douyinstatic")
            || host.contains("byteimg") || host.contains("snssdk") || host.contains("amemv") {
            return nil
        }
        if host.contains("bilibili") || host.contains("hdslb") || host.contains("bilivideo")
            || host.contains("mountaintoys") || host.contains("akamaized") {
            return "https://www.bilibili.com/"
        }
        if host.contains("weibo") || host.contains("sinaimg") || host.contains("sinajs")
            || host.contains("weibocdn") {
            return "https://weibo.com/"
        }
        if host.contains("xhscdn") || host.contains("xiaohongshu") {
            return "https://www.xiaohongshu.com/"
        }
        return nil
    }

    // MARK: - 文件头嗅探

    /// 判不出来但服务端给了明确的媒体 Content-Type 才采信 —— 否则 HTML 错误页会被存成 .mp4
    private static func sniffHead(_ data: Data, contentType: String, declared: MediaKind) -> String? {
        if data.count >= 12 {
            let b = [UInt8](data.prefix(12))
            let box = String(bytes: b[4..<8], encoding: .ascii) ?? ""
            if box == "ftyp" {
                // HEIF 的 ftyp 和 MP4 一样，看 brand 才知道是图
                let brand = (String(bytes: b[8..<12], encoding: .ascii) ?? "")
                    .trimmingCharacters(in: .whitespaces)
                if ["heic", "heix", "hevc", "mif1", "msf1"].contains(brand) {
                    return "image/heic"
                }
                return (contentType.hasPrefix("audio/") || declared == .audio) ? "audio/mp4" : "video/mp4"
            }
            if b[0] == 0xFF && b[1] == 0xD8 { return "image/jpeg" }
            if b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 { return "image/png" }
            if String(bytes: b[0..<4], encoding: .ascii) == "RIFF",
               String(bytes: b[8..<12], encoding: .ascii) == "WEBP" {
                return "image/webp"
            }
            if String(bytes: b[0..<3], encoding: .ascii) == "GIF" { return "image/gif" }
            if String(bytes: b[0..<3], encoding: .ascii) == "ID3" { return "audio/mpeg" }
            if b[0] == 0x1A && b[1] == 0x45 && b[2] == 0xDF && b[3] == 0xA3 { return "video/webm" }
        }
        let ct = contentType.split(separator: ";").first
            .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        if ct.hasPrefix("video/") || ct.hasPrefix("audio/") || ct.hasPrefix("image/") { return ct }
        return nil
    }

    private static func fileExtension(for mime: String) -> String {
        if mime.contains("mp4") && mime.hasPrefix("audio/") { return "m4a" }
        if mime.contains("mp4") { return "mp4" }
        if mime.contains("webm") { return "webm" }
        if mime.contains("mpeg") { return "mp3" }
        if mime.contains("jpeg") { return "jpg" }
        if mime.contains("png") { return "png" }
        if mime.contains("webp") { return "webp" }
        if mime.contains("gif") { return "gif" }
        if mime.contains("heic") || mime.contains("heif") { return "heic" }
        if mime.contains("aac") { return "aac" }
        if mime.contains("wav") { return "wav" }
        return "bin"
    }
}
