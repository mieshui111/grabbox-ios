# GrabBox for iOS

Android 版 GrabBox 的 iOS 移植。深色克制 UI、剪贴板自动识别、多平台无水印下载。

## 与 Android 版的关键差异

| | Android | iOS |
|---|---|---|
| 解析引擎 | 内嵌 libpython + yt-dlp（YouTube/IG）；Panda 协议直连 | **全部走 HTTP**。iOS 禁止 App 运行外部可执行代码，Python 运行时这条路是死的 |
| YouTube / Instagram | 端上 yt-dlp | **自建后端**（`backend/`）：yt-dlp + ffmpeg 在服务器跑，回一个合并好的 mp4 直链 |
| 分发 | APK 自由安装 | 需要 Apple 生态的签名体系（见下文三条路径） |
| 音视频合并 | MediaMuxer | 不需要 —— 合并发生在后端；单文件直接存 |
| 保存 | MediaStore 分区 | PhotoKit（webp 自动转 JPEG，音频进「文件」App） |

## 平台支持

抖音 / TikTok / 快手 / 小红书* / 微博 / X / 西瓜 / Threads / Facebook / Vimeo / Reddit / Pinterest / Snapchat —— **零依赖，装完即用**。
YouTube / Instagram —— 需要先在设置里填后端地址。

\* 小红书：解析站偶尔要人机验证，与 Android 版一致的已知限制。

## 三条安装路径

| 路径 | 成本 | 适合 |
|---|---|---|
| **自用侧载** | 免费 Apple ID | 最快上手。手机连电脑，用 [AltStore](https://altstore.io) / Sideloadly 装 `GrabBox.ipa`。免费号 7 天续签一次 |
| **TestFlight** | ¥688/年 Developer 账号 | 长期方案。`./scripts/build.sh testflight` 归档上传，90 天一轮可续，手机装 TestFlight 即可 |
| **App Store 上架** | 账号 + ICP 备案 | 不建议。下载器类别过审率低，ATS 全放开也过不了静态检查 |

## 构建

### Mac 本地

```bash
brew install xcodegen
./scripts/build.sh sim        # 模拟器编译验证（不需要任何证书）
./scripts/build.sh device     # 真机包
./scripts/build.sh testflight # 归档（TestFlight）
```

### 没有 Mac？用 GitHub Actions

把 `GrabBox-iOS/` 推到 GitHub，`.github/workflows/ios-build.yml` 会自动在云 Mac 上编译验证
（Actions 免费额度对私有仓库每月 2000 分钟，这种小项目每次约 5 分钟）。

## 可选后端（YouTube / Instagram）

群晖 NAS 一条命令：

```bash
cd GrabBox-iOS/backend
docker build -t grabbox-backend .
docker run -d --name grabbox-backend --restart unless-stopped -p 8421:8421 grabbox-backend
```

App 内「设置 → 自建后端」填 `http://<NAS_IP>:8421`。`GET /health` 可用来确认通了。

注意：**手机和 NAS 必须同一局域网**；iOS 对 http 明文请求放行了全局允许（`NSAppTransportSecurity`），真上架时这条要改成域名白名单。

## 快捷指令（替代分享扩展）

系统分享菜单扩展没做（第二版可以考虑）。目前的等价体验是建一条快捷指令：

1. 快捷指令 → 新建 → 接收「Safari 网页 / App 链接」
2. 动作：「获取 URL」→「打开 URL」，填 `grabbox://grab?url=[快捷指令的链接变量]`

然后在任意 App 的分享菜单里选这条快捷指令，就会拉起 GrabBox 开下。

## 目录

```
GrabBox-iOS/
├── project.yml              # XcodeGen 工程定义（xcodegen generate 出 .xcodeproj）
├── GrabBox/
│   ├── Core/                # 平台表、链接识别、设计令牌
│   ├── Engines/             # PandaEngine（dlpanda 协议）/ MediaDownloader（分段并发）/ Web2ApiEngine（后端）
│   ├── Storage/             # PhotoKit 保存 + 转码
│   ├── Services/            # 剪贴板守门员、下载状态机
│   └── Views/               # SwiftUI 单页 + 后端设置
├── backend/                 # 可选 yt-dlp 后端（Node 零依赖 + Dockerfile）
├── scripts/build.sh         # Mac 一键构建
└── .github/workflows/       # 云 Mac 编译验证
```

## 已知限制

- 后台下载：iOS 对第三方 App 的后台限制严，切后台太久会中断，进度在 `beginBackgroundTask` 宽限内尽力而为（当前版本切后台请先等它跑完）
- 老链接 / 已删作品 / 私密作品：解析站那边就过不去，提示语会给出具体原因
- 音频不进相册：PhotoKit 管不了音乐文件，落在「文件 → GrabBox」里
- 第三方解析站改版会失效：Android 版的工具链（`tools/probe-http.mjs`）同样适用于排查，协议本身两端共享
