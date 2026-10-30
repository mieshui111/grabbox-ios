# 怎么把 GrabBox 装进 iPhone

本机是 Windows，没有 Xcode，所以 iPhone 上的安装分两步走：**先在云端 Mac 编译出 ipa，再在 Windows 上用你的 Apple ID 签名安装**。

先看三条路，选一条：

| 方式 | 花钱 | 能用多久 | 需要什么 | 折腾程度 |
|---|---|---|---|---|
| **A. Sideloadly + 免费 Apple ID** | 0 元 | **7 天**，到期重签一次 | Windows 电脑 + 数据线 | 中 |
| **B. TestFlight + 付费开发者账号** | 688 元/年 | 90 天一轮，可续 | 一次配置 | 中（前期贵） |
| **C. 有 Mac，Xcode 直接装** | 0 元 | 7 天（同免费号） | 一台 Mac | 低 |

大多数人先走 A 试水——能用就留着，觉得天天续签烦再上 B。

---

## 第 0 步：把代码传到 GitHub（A / B 都要做）

GitHub 的 macOS 机器免费跑编译，这是唯一不用 Mac 就能出 ipa 的办法。

### 0.1 有没有 GitHub 账号
没有就去 https://github.com/signup 注册，邮箱验证一下就行。

### 0.2 建一个空仓库
点右上角 `+` → New repository → 名字填 `grabbox-ios` → **Private 或 Public 都行**（Private 每月也有 2000 分钟免费额度，一次构建约 6 分钟）→ 不要勾任何 README / .gitignore → Create。

### 0.3 上传代码
本机项目已经初始化好 git 仓库了，直接在终端里推：

```bash
cd "C:\Users\miesh\WorkBuddy\2026-10-29-10-39-25\GrabBox-iOS"
git remote add origin https://github.com/<你的用户名>/grabbox-ios.git
git push -u origin main
```

推送时会要账号密码，**密码处填 Personal Access Token**（不是登录密码）：
GitHub → 右上头像 → Settings → Developer settings → Personal access tokens → Tokens (classic) → Generate new token → 勾 `repo` → 生成后复制那串 `ghp_...`，粘贴到密码位置。

> 不想用命令行？装个 [GitHub Desktop](https://desktop.github.com/)，Add local repository 指向这个文件夹，然后 Publish。**别用网页拖拽上传** —— `.github` 是隐藏目录，Windows 资源管理器里看不见，拖拽会漏掉，那样 Actions 根本不会跑。

### 0.4 等编译跑完
打开仓库页面 → 顶部 **Actions** 标签 → 左边 `ios-build` → 点最新那条正在转圈的任务。

- 绿勾 ✅ → 拉到底部 **Artifacts**，下载 `GrabBox-unsigned-ipa`（一个 zip，解压出 `GrabBox-unsigned.ipa`）
- 红叉 ❌ → 下载 `build-log`，把里面最后 50 行贴给我，我来改代码

> **说实话**：这份 Swift 代码我这边没有编译器，只能做语法结构检查，**第一次云编译大概率会有几个编译错误**。这很正常，贴日志给我，改完再推一次就行。

---

## 第 1 步（路线 A）：Windows 上签名安装

### 1.1 装 Apple 驱动
Sideloadly 要靠苹果的驱动跟手机通信。

去 https://support.apple.com/downloads/itunes 下载 **iTunes 安装包（.exe 那种）** 装上。

> **关键坑**：不要用 Microsoft Store 里的 iTunes，沙盒版不给 Sideloadly 权限，会连不上手机。必须是 Apple 官网的 exe 版。
> 如果系统提示「Apple Mobile Device 服务」相关问题，装完 iTunes 重启一次电脑。

### 1.2 装 Sideloadly
https://sideloadly.io → 下载 Windows 版 → 安装。

### 1.3 iPhone 上开开发者模式（iOS 16 及以上必须）
设置 → 隐私与安全性 → 拉到底 → **开发者模式** → 打开 → 重启手机 → 重启后弹窗点「打开」。

> 这个开关在没装过任何开发版 App 之前可能是**隐藏的**。如果找不到，先用数据线把手机连电脑、在 iTunes 里点一下「信任此电脑」，再回来看就会出现。

### 1.4 信任电脑
数据线连电脑 → 手机上弹「要信任此电脑吗」→ 信任 → 输入锁屏密码。

### 1.5 签名安装
1. 打开 Sideloadly
2. **IPA** 处选刚解压的 `GrabBox-unsigned.ipa`
3. **Apple ID** 处填你的 Apple ID（用哪个都行，就是平时登录 App Store 的那个）
4. 插着线的 iPhone 会自动出现在 **iDevice** 下拉框里
5. 点 **Start**
6. 会弹窗要 Apple ID 密码 → 输入。如果开了双重认证，会要一次 6 位验证码（或者让你去 appleid.apple.com 生成一个 App 专用密码填进去）
7. 等进度条走完，日志出现 `✅ Done` 就成了

### 1.6 手机上信任描述文件（不做这步点开就闪退）
设置 → 通用 → VPN与设备管理 → 开发者 App → 点你的 Apple ID → 信任。

### 1.7 开权限
第一次打开 GrabBox，复制一条抖音链接再切回 App，它会自动识别。**首次保存时会问相册权限，必须选「允许」**，否则下完了存不进相册。

---

## 第 2 步：7 天到期怎么办

免费 Apple ID 签的 App **7 天后打不开**（点图标闪一下退出来），不用慌：

- 重新插线 → Sideloadly 里再点一次 Start → 会覆盖安装，**数据不丢**（App 内的登录态、设置都在）
- 嫌烦的话有两个升级方向：
  - 装 **SideStore**（可以在手机上自动续签，不用每次插电脑，但初始配置要生成配对文件 + 装一个 VPN 描述文件，步骤较长）
  - 买 **Apple Developer Program**（688 元/年），签名有效期变 1 年，还能走 **TestFlight**：上传一次，手机装 TestFlight 后从云端安装，90 天续一轮，换手机也方便

---

## 路线 C：你有 Mac 的话（最省事）

```bash
brew install xcodegen
cd GrabBox-iOS
./scripts/build.sh ipa        # 出未签名 ipa
./scripts/build.sh device     # 或者直接装真机（Xcode 里先登录 Apple ID）
```

Xcode 里 `Settings → Accounts` 登录 Apple ID，`Signing & Capabilities` 里 Team 选自己的个人团队，选好设备直接 ⌘R 就装上了，比走 Sideloadly 少一半步骤。

---

## 常见报错对照

| 现象 | 原因 / 解法 |
|---|---|
| Sideloadly 里看不到手机 | iTunes 是 Microsoft Store 版 → 换官网 exe 版；或没点「信任此电脑」；或数据线是纯充电线 |
| 装完点开闪退 | 没做 1.6 的信任描述文件；或者已过 7 天 |
| `Unable to install ... maximum number of apps` | 免费账号同时最多 3 个自签 App，删掉一个旧的 |
| `bundle identifier is not available` | 这个 ID 被占用了，Sideloadly 里把 Bundle ID 改成 `com.你的名字.grabbox` |
| 提示需要开发者模式 | 回 1.3 打开，且要重启手机 |
| 下载能成功但相册里没有 | 相册权限没给，设置 → GrabBox → 照片 → 允许 |
| Actions 编译红叉 | 把 `build-log` 最后 50 行发我，我改代码 |

---

## 装好之后能干什么

- 复制抖音/小红书/快手/微博/X/TikTok 等平台的分享链接 → 切回 App 自动识别开下（跟 Android 版一致）
- 视频、图集都支持；图集会逐张存进相册并带序号
- **YouTube / Instagram 默认不可用**：iOS 不允许 App 内部跑 yt-dlp，需要你在 NAS 上跑 `backend/` 那个 Docker（`docker build -t grabbox-api . && docker run -d -p 8471:8471 grabbox-api`），然后在 App 设置里填 NAS 地址。不填也不影响其他平台。

---

## 一句实话

这套流程能走通，但**第一步云编译还没真正跑过**。你要是决定走 A 路线，把 GitHub 仓库地址给我（或者直接贴 Actions 的报错日志），我把编译问题一次修干净，你再装。
