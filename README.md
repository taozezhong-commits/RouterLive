# 无 Mac 打包 IPA 说明

这套工程让你**不需要拥有 Mac、不需要 Apple 开发者账号（$99/年）**就能产出并安装一个可运行的 iOS App。

## 原理：把 Mac 放到云上

iOS 的编译器和 SDK 只运行在 macOS 上，但"用到 Mac"和"拥有一台 Mac"是两回事。GitHub Actions 提供免费的 macOS 云主机（每次最多 6 小时，公开仓库完全免费、私有仓库每月 2000 分钟），上面预装 Xcode。我们把编译流程写成 `build.yml`，由云端 Mac 执行，产物是一个**未签名 IPA**，下载回 Windows 后再用免费 Apple ID 签名安装。

三步链路：

```
Windows 写好的源码
   → GitHub Actions 的 macOS 云主机编译（免费）
   → 下载未签名 IPA 到 Windows
   → Sideloadly / AltStore 用免费 Apple ID 签名 + USB 安装到 iPhone
```

## 目录结构

```
cloud-build/
  project.yml                       # XcodeGen 工程描述（文本定义 .xcodeproj）
  RouterLive/
    RouterAPI.swift                 # 路由器接口数据层（移植自 RouterLive.js）
    RouterLiveApp.swift             # App 入口
    ContentView.swift               # 最小界面：WAN 速率 + 设备列表 + 配置
  .github/workflows/build.yml       # 云编译流水线
```

## 操作步骤

### 1. 上传源码到 GitHub

在 GitHub 新建一个仓库。把 `cloud-build` 目录下的**全部内容**（含 `.github` 隐藏目录）上传到仓库根目录。

仓库可见性会影响免费额度，建议优先用 **public**：

- **public 仓库**：macOS runner 不限时长，完全免费。
- **private 仓库**：免费账户每月 2000 分钟，但 macOS runner 按 **10 倍**扣减，实际约 200 分钟/月。一次编译约 5–10 分钟，够用但要留意额度。

⚠️ 注意：`.github` 是隐藏目录，Windows 资源管理器默认不显示。用 `git add -A` 命令行最稳妥，或勾选"显示隐藏的项目"。

### 2. 触发编译

推送后 workflow 自动运行。也可以进入仓库的 **Actions** 标签页 → 左侧选 `Build RouterLive IPA` → **Run workflow** 手动触发。

首次编译需要装 XcodeGen，约 5–10 分钟。完成后在本次运行的页面底部 **Artifacts** 里下载 `RouterLive-unsigned-IPA`（zip 包，解压得到 `.ipa`）。

### 3. 在 Windows 上签名并安装

1. 下载安装 [Sideloadly](https://sideloadly.io/)（Windows 版，免费）。
2. 用你的 Apple ID 登录（免费账号即可，不需要开发者账号）。
3. 把 IPA 拖进 Sideloadly，iPhone 用数据线连上电脑。
4. 点击 **Start** 签名并安装。首次安装需在 iPhone 上信任证书：
   设置 → 通用 → VPN 与设备管理 → 选择你的 Apple ID → 信任。

**免费 Apple ID 的签名 7 天过期**，到期后 App 打不开。解决办法：每 7 天把手机连上电脑，用 Sideloadly 重新签名安装一次（数据会保留），或购买 Apple Developer Program（$99/年）获得 1 年有效签名。

### 4. 在 App 内配置

打开 App 后，在"路由器"一栏填入地址（默认 `192.168.0.1`）和管理密码，点"开始监控"。手机必须连在该路由器的 Wi-Fi 下，且首次联网会弹出"本地网络"授权，需要点允许。

## 如果想改代码

改完 Swift 文件后 `git commit && git push`，GitHub Actions 会自动重新编译出新 IPA。你全程不需要碰 `.xcodeproj`——它由 `project.yml` 在云端自动生成。

## 重要说明

- 这个 App 是**新建的最小工程**，只包含路由器监控功能，**不是原 Device Status⁺ IPA 的改版**。要改原 App 并保留其全部功能，必须拿到它的 Xcode 源码工程；编译后的二进制无法安全反编译回可维护源码。
- 云编译产出的是未签名 IPA，只能在 Sideloadly/AltStore 侧载后运行，无法上架 App Store。
- 数据在 `RouterAPI.swift` 里硬编码了固件常量（salt/charset），如果你的路由器固件不同，需要替换这两个值（从路由器管理页前端脚本里取）。

## 其他不用买 Mac 的替代方案

- **Codemagic**（codemagic.io）：专为移动 App 设计的云编译，免费档每月有额度，网页上点选即可，比 GitHub Actions 更傻瓜化，适合不想配 YAML 的情况。
- **租云 Mac**：MacinCloud / MacStadium 按小时租 macOS 远程桌面，装好 Xcode 后手动编译。适合需要交互式调试的场景，但要花钱。
- **找有 Mac 的人代编译**：把 `cloud-build` 目录发给对方，`xcodegen generate` 然后 `xcodebuild archive` 即可，全程 5 分钟。

这几种方式都只能编译**你有源码的工程**。要让原 Device Status⁺ IPA 本身带上路由器数据功能，仍然只能靠它的开发者改源码重新发版——这是 iOS 生态无法绕开的。

## 验证编译是否成功

看 GitHub Actions 运行日志的最后一步：
- `Archive (unsigned)` 输出 `** ARCHIVE SUCCEEDED **`
- `Pack unsigned IPA` 输出 IPA 文件大小（通常 1–3 MB）
- 出现 `RouterLive-unsigned-IPA` artifact 即成功
