import UIKit

/// 剪贴板守门员。
///
/// iOS 的隐私规则：随便读剪贴板会弹「允许粘贴」——用户体验极差。
/// iOS 16 起有 `detectPatterns`，先问系统「这里面有没有链接」，**只有命中才真正读文本**，
/// 这样绝大多数回到前台的情况都不会弹窗。
@MainActor
final class ClipboardWatcher {

    private var lastHandled = ""

    func detectLink() async -> (Platform, URL)? {
        let pasteboard = UIPasteboard.general
        guard pasteboard.hasStrings else { return nil }

        if #available(iOS 16.0, *) {
            let hasURL = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                pasteboard.detectPatterns(for: [.probableWebURL]) { result in
                    if case .success(let patterns) = result, patterns.contains(.probableWebURL) {
                        cont.resume(returning: true)
                    } else {
                        cont.resume(returning: false)
                    }
                }
            }
            guard hasURL else { return nil }
        }

        guard let text = pasteboard.string, !text.isEmpty, text != lastHandled else { return nil }
        lastHandled = text
        return LinkDetector.detect(text)
    }

    func markHandled(_ text: String) {
        lastHandled = text
    }
}
