import SwiftUI
import UIKit

struct ContentView: View {

    @EnvironmentObject private var model: DownloadCoordinator
    @State private var input = ""
    @State private var showSettings = false
    @FocusState private var inputFocused: Bool

    private var detected: (Platform, URL)? { LinkDetector.detect(input) }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    inputCard
                    if model.phase != .idle { statusCard }
                    platformCard
                    footerCard
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 30)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) {
            BackendSettingsView()
                .presentationDetents([.medium])
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.brandGradient)
                .frame(width: 48, height: 48)
                .overlay(
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color(hex: 0x06101F))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("GrabBox")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Theme.titleGradient)
                Text("复制的链接，打开就下")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            Button {
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 40, height: 40)
                    .background(Theme.chip)
                    .clipShape(Circle())
            }
        }
        .padding(.top, 8)
    }

    // MARK: - 输入

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                TextField("粘贴分享链接…", text: $input, axis: .vertical)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .lineLimit(1...3)
                    .focused($inputFocused)
                    .submitLabel(.done)
                    .onSubmit { submit() }
                if !input.isEmpty {
                    Button {
                        input = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(Theme.input)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            )

            // 实时识别结果
            HStack(spacing: 6) {
                Circle()
                    .fill(detected == nil ? Theme.textTertiary : Theme.ok)
                    .frame(width: 6, height: 6)
                Text(detected.map { "识别为 \($0.0.label)" } ?? "支持抖音 / 小红书 / 快手 / 微博 / X 等 \(PlatformCatalog.all.count) 个平台")
                    .font(.system(size: 11.5))
                    .foregroundStyle(detected == nil ? Theme.textTertiary : Theme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)

            HStack(spacing: 10) {
                Button {
                    pasteFromClipboard()
                } label: {
                    Label("粘贴", systemImage: "doc.on.clipboard")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(Theme.chip)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                }

                Button {
                    submit()
                } label: {
                    HStack(spacing: 6) {
                        if model.busy {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(Color(hex: 0x06101F))
                                .scaleEffect(0.85)
                        }
                        Text(model.busy ? "处理中" : "下载")
                            .font(.system(size: 15, weight: .bold))
                    }
                    .foregroundStyle(Color(hex: 0x06101F))
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(Theme.brandGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .opacity(model.busy || detected == nil ? 0.45 : 1)
                }
                .disabled(model.busy || detected == nil)
            }
        }
        .padding(14)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1)
        )
    }

    // MARK: - 状态

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(statusColor)
                Text(model.detail.isEmpty ? "状态" : model.detail)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Text("\(Int(model.progress * 100))%")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
            }

            Text(model.status)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            ProgressView(value: min(max(model.progress, 0), 1))
                .progressViewStyle(.linear)
                .tint(model.phase == .failed ? Theme.error : Theme.brandB)
        }
        .padding(14)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1)
        )
    }

    private var statusIcon: String {
        switch model.phase {
        case .idle: return "circle"
        case .parsing: return "magnifyingglass"
        case .downloading: return "arrow.down.circle"
        case .saving: return "square.and.arrow.down"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch model.phase {
        case .done: return Theme.ok
        case .failed: return Theme.error
        default: return Theme.brandB
        }
    }

    // MARK: - 平台

    private var platformCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("支持的平台")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .textCase(.uppercase)
                .kerning(0.6)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(PlatformCatalog.all) { p in
                    Text(p.label)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Theme.chip)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
            }
        }
        .padding(14)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1)
        )
    }

    // MARK: - 说明

    private var footerCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("怎么用")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .textCase(.uppercase)
                .kerning(0.6)
            bullet("在原 App 里「分享 → 复制链接」")
            bullet("回到 GrabBox，链接会自动识别并开始下载")
            bullet("视频和图片存进相册，音频存进「文件 → GrabBox」")
            bullet("YouTube / Instagram 需要在设置里填自建后端地址")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(Theme.brandB.opacity(0.6))
                .frame(width: 4, height: 4)
                .padding(.top, 6)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 动作

    private func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        input = text
    }

    private func submit() {
        guard let hit = detected else { return }
        inputFocused = false
        model.start(url: hit.1, platform: hit.0)
    }
}

// MARK: - 后端设置

struct BackendSettingsView: View {

    @AppStorage("backendBase") private var backendBase = ""
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 14) {
                    Text("YouTube / Instagram 需要服务端解析")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("iOS 不允许 App 内运行外部脚本，所以 yt-dlp 只能跑在你自己的服务器上。填上地址后，这两个平台会走服务端解析，其余平台仍然直连。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    TextField("http://10.1.1.6:8421", text: $draft)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .padding(13)
                        .background(Theme.input)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Theme.stroke, lineWidth: 1)
                        )

                    Spacer(minLength: 0)
                }
                .padding(18)
            }
            .navigationTitle("自建后端")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        backendBase = draft
                        dismiss()
                    }
                    .foregroundStyle(Theme.brandB)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .onAppear { draft = backendBase }
        }
    }
}
