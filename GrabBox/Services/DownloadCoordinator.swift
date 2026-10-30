import Foundation
import SwiftUI

/// 一次下载的全部状态机。视图只读它，不写业务逻辑。
@MainActor
final class DownloadCoordinator: ObservableObject {

    enum Phase: Equatable {
        case idle
        case parsing
        case downloading
        case saving
        case done
        case failed
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var status: String = "就绪"
    @Published private(set) var detail: String = ""
    @Published private(set) var busy = false

    /// 自建后端地址（YouTube / Instagram 需要）。留空时这两个平台会给出明确提示
    @AppStorage("backendBase") var backendBase: String = ""

    private let watcher = ClipboardWatcher()

    // MARK: - 入口

    func start(url: URL, platform: Platform) {
        guard !busy else { return }
        busy = true
        phase = .parsing
        progress = 0
        detail = platform.label
        status = "正在解析 \(platform.label) 链接…"

        Task { await run(url: url, platform: platform) }
    }

    /// 回到前台时调用：剪贴板里若有新链接，自动开下（Seal 同款体验）
    func autoDetectClipboard() {
        guard !busy else { return }
        Task {
            guard let hit = await watcher.detectLink() else { return }
            start(url: hit.1, platform: hit.0)
        }
    }

    // MARK: - 主流程

    private func run(url: URL, platform: Platform) async {
        do {
            let resolved = try await resolve(url: url, platform: platform)
            let items = resolved.media
            let title = resolved.title

            phase = .downloading
            let workDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("grabbox", isDirectory: true)
            try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

            var savedCount = 0
            var lastError: String?
            var savedTo = "相册"
            var denied = false

            for (index, item) in items.enumerated() {
                guard !denied else { break }

                if items.count > 1 {
                    detail = "\(index + 1)/\(items.count)"
                    status = "正在下载第 \(index + 1) 个，共 \(items.count) 个…"
                } else {
                    detail = platform.label
                    status = item.kind == .image ? "正在下载图片…" : "正在下载视频…"
                }

                do {
                    let file = try await MediaDownloader.download(item, workDir: workDir) { [weak self] value in
                        let overall = items.count > 1
                            ? (Double(index) + value) / Double(items.count)
                            : value
                        Task { @MainActor in self?.progress = overall }
                    }

                    phase = .saving
                    status = "正在保存到相册…"
                    let name = GallerySaver.displayName(
                        base: title, ext: file.ext, index: index, total: items.count
                    )
                    let outcome = await GallerySaver.save(
                        file: file,
                        displayName: name,
                        documentsDir: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    )
                    try? FileManager.default.removeItem(at: file.fileURL)

                    switch outcome {
                    case .saved(let location):
                        savedCount += 1
                        savedTo = location
                    case .denied:
                        denied = true
                        lastError = "没有相册写入权限，去「设置 → GrabBox → 照片」里打开"
                    case .failed(let message):
                        lastError = message
                    }
                    phase = .downloading
                } catch {
                    lastError = error.localizedDescription
                }
            }

            finish(savedCount: savedCount, total: items.count, lastError: lastError, savedTo: savedTo)
        } catch {
            phase = .failed
            status = error.localizedDescription
            detail = ""
            busy = false
        }
    }

    private func resolve(url: URL, platform: Platform) async throws -> (title: String?, media: [MediaItem]) {
        switch platform.engine {
        case .panda:
            guard let path = platform.path else {
                throw PandaError.badPage("该平台暂不支持解析")
            }
            let items = try await PandaEngine.shared.resolve(path: path, shareURL: url.absoluteString)
            return (nil, items)
        case .remote:
            return try await Web2ApiEngine.resolve(url: url, base: backendBase)
        }
    }

    private func finish(savedCount: Int, total: Int, lastError: String?, savedTo: String) {
        busy = false
        detail = ""
        if savedCount > 0 {
            phase = .done
            progress = 1
            if savedCount == 1 {
                status = "已保存到\(savedTo)"
            } else {
                status = "已保存 \(savedCount) 项到\(savedTo)"
            }
            if let lastError, savedCount < total {
                status += "，\(total - savedCount) 项失败：\(lastError)"
            }
        } else {
            phase = .failed
            status = lastError ?? "下载失败，链接可能已过期，重试一次"
        }
    }

    func reset() {
        guard !busy else { return }
        phase = .idle
        progress = 0
        status = "就绪"
        detail = ""
    }
}
