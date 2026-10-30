import Foundation

/// 媒体类型。跟 Android 版 `PandaEngine.Kind` 一一对应。
enum MediaKind: String {
    case video
    case image
    case audio

    /// 相册 / 文件分别用哪套 API 落盘
    var isPhotoLibraryKind: Bool { self == .video || self == .image }
}

/// 一件待下载的媒体。
struct MediaItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let kind: MediaKind

    func hash(into hasher: inout Hasher) { hasher.combine(url.absoluteString) }
    static func == (lhs: MediaItem, rhs: MediaItem) -> Bool { lhs.url == rhs.url }
}
