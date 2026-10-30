import SwiftUI

@main
struct GrabBoxApp: App {

    @StateObject private var model = DownloadCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onOpenURL { handle($0) }
                .onChange(of: scenePhase) { phase in
                    // 回到前台就检一次剪贴板 —— Seal 同款体验。
                    // 不用 onAppear：视图只构建一次，切出去再回来不会重新触发。
                    if phase == .active {
                        model.autoDetectClipboard()
                    }
                }
        }
    }

    /// grabbox://grab?url=<percent-encoded 分享链接>
    /// 给「快捷指令」用：没法做分享扩展时，用一条快捷指令接住系统分享菜单
    private func handle(_ url: URL) {
        guard url.scheme == "grabbox" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let raw = components?.queryItems?.first(where: { $0.name == "url" })?.value,
              let hit = LinkDetector.detect(raw) else { return }
        model.start(url: hit.1, platform: hit.0)
    }
}
