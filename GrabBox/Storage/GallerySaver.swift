import Foundation
import ImageIO
import Photos
import UIKit

/// 落盘结果：
///  - `saved`   已进相册 / 文件 App
///  - `denied`  用户拒绝了相册权限
///  - `failed`  其它失败（原因已本地化）
enum SaveOutcome {
    case saved(location: String)
    case denied
    case failed(String)
}

/// 相册 / 文件写入。
///
/// iOS 与 Android 的关键差异：没有「公共目录随便写」这回事，只能用 PhotoKit 交给系统托管。
///  - 视频 → `PHAssetCreationRequest(.video)`
///  - 图片 → `(.photo)`。**webp 例外**：系统相册不接受 webp 作为照片资源，必须先转 JPEG
///  - 音频 → 相册管不了，落到 App 的 Documents/音频，用户可在「文件」App 里看到
enum GallerySaver {

    static func ensurePermission() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                    cont.resume(returning: newStatus == .authorized || newStatus == .limited)
                }
            }
            return granted
        default:
            return false
        }
    }

    static func save(
        file: DownloadedFile,
        displayName: String,
        documentsDir: URL
    ) async -> SaveOutcome {

        if file.kind == .audio {
            return saveToDocuments(file: file, displayName: displayName, documentsDir: documentsDir)
        }

        guard await ensurePermission() else { return .denied }

        var payload = file.fileURL
        var name = displayName
        var temporary: URL?
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }

        // webp / bin 转成 JPEG 再进相册，否则 performChanges 会直接抛错
        if file.kind == .image && !["jpg", "jpeg", "png", "heic", "heif", "gif"].contains(file.ext) {
            guard let converted = transcodeToJPEG(file.fileURL) else {
                return .failed("图片转码失败（\(file.ext) 格式不受相册支持）")
            }
            payload = converted
            temporary = converted
            name = (displayName as NSString).deletingPathExtension + ".jpg"
        }

        do {
            // 用回调版包一层 continuation：PHPhotoLibrary 的 async 包装在部分 SDK 版本里签名不一致
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = name
                    let type: PHAssetResourceType = file.kind == .video ? .video : .photo
                    request.addResource(with: type, fileURL: payload, options: options)
                } completionHandler: { success, error in
                    if success {
                        cont.resume()
                    } else {
                        cont.resume(throwing: error ?? NSError(
                            domain: "GallerySaver", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "相册写入失败"]
                        ))
                    }
                }
            }
            return .saved(location: "相册")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - 音频走「文件」

    private static func saveToDocuments(
        file: DownloadedFile,
        displayName: String,
        documentsDir: URL
    ) -> SaveOutcome {
        let folder = documentsDir.appendingPathComponent("GrabBox", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var target = folder.appendingPathComponent(displayName)
            if FileManager.default.fileExists(atPath: target.path) {
                let base = (displayName as NSString).deletingPathExtension
                let ext = (displayName as NSString).pathExtension
                target = folder.appendingPathComponent("\(base)_\(Int(Date().timeIntervalSince1970)).\(ext)")
            }
            try FileManager.default.moveItem(at: file.fileURL, to: target)
            return .saved(location: "文件 App/GrabBox")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - 转码

    /// ImageIO 解码（支持 webp，iOS 14+）→ 重新编码 JPEG
    private static func transcodeToJPEG(_ url: URL) -> URL? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let dest = url.deletingPathExtension().appendingPathExtension("jpg")
        guard let out = CGImageDestinationCreateWithURL(dest as CFURL, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
        CGImageDestinationAddImage(out, image, options as CFDictionary)
        guard CGImageDestinationFinalize(out) else { return nil }
        return dest
    }

    // MARK: - 文件名

    /// 相册里显示的名字。图集多张时带序号，否则同名会互相覆盖
    static func displayName(base: String?, ext: String, index: Int, total: Int) -> String {
        let safeExt = ext.isEmpty ? "mp4" : ext
        let stamp = Int(Date().timeIntervalSince1970)
        var stem: String
        if let base, !base.trimmingCharacters(in: .whitespaces).isEmpty {
            stem = base
                .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\r\n\t"))
                .joined(separator: "_")
                .trimmingCharacters(in: .whitespaces)
            if stem.count > 60 { stem = String(stem.prefix(60)) }
        } else {
            stem = "GrabBox_\(stamp)"
        }
        if total > 1 {
            stem += "_\(index + 1)"
        }
        return "\(stem).\(safeExt)"
    }
}
