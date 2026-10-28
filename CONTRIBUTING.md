# 开发说明

## 环境与命令

需要 macOS 14+、Swift 6.0+ 和匹配的 macOS SDK。项目使用 Swift Package Manager、AppKit、SwiftUI 和 ServiceManagement，无第三方生产依赖。

```sh
./scripts/test.sh
./scripts/build.sh
./dist/ChatGPT额度助手.app/Contents/MacOS/QuotaCompanion --check
```

- `test.sh` 使用 Swift Testing；RPC 测试使用系统 `/usr/bin/python3` 模拟子进程，不访问真实账号。
- `build.sh` 构建当前主机架构的 Release 可执行文件，组装 `.app` 并进行 ad-hoc 签名，不生成通用二进制或执行公证。
- `--check` 会通过 ChatGPT 内置服务联网读取真实额度；仅输出窗口、剩余百分比与重置倒计时，不输出账号、令牌或原始响应。目前自检入口固定检查 `/Applications/ChatGPT.app`。

不要用单独的 `swift run` 代替打包后的 app 验证登录项和图标；这些行为依赖应用 bundle。

本机 Swift 6.4 默认构建引擎需要显式指定测试宏插件路径，测试脚本会在工具链提供 `plugins/testing` 目录时补上这个路径。构建脚本通过 SwiftPM 查询产物位置，适应不同版本的输出目录。移动项目目录后，若提示模块缓存路径不匹配，先将旧 `.build/` 移出项目再重新构建。

## 目录

```text
Package.swift                    SwiftPM 清单
Sources/QuotaCompanion/           菜单栏、面板、生命周期与登录项
Sources/QuotaCore/                额度解析和 JSON-RPC 客户端
Tests/QuotaCoreTests/             解析、边界条件与模拟 RPC 测试
Resources/AppIcon.png            图标母版
Resources/AppIcon.icns           macOS 图标资源
scripts/                         测试、构建和图标转换脚本
docs/RELEASING.md                GitHub 发布指南
VALIDATION.md                    验证记录
```

## 服务适配

GUI 检测 `com.openai.codex` 和 `com.openai.chat` 两个 bundle 标识。寻找内置二进制时，先通过 `com.openai.codex` 定位应用，否则回退到 `/Applications/ChatGPT.app`，再依次检查：

```text
Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex
Contents/Resources/codex
```

本项目依赖桌面端当前的打包结构；检测到进程并不代表该版本一定提供兼容服务。变更适配时核对 [官方 App Server 文档](https://learn.chatgpt.com/docs/app-server) 和实际应用结构。

解析优先使用非空 `rateLimitsByLimitId`，否则回退到 `rateLimits`。额度通知会触发重新读取，并以五秒间隔限制通知产生的请求。解析和通信行为变更应补充相关测试，避免将缺失字段当成零用量。

## 图标

图标母版由内置 ImageGen 生成，设计为深蓝圆角底、薄荷色额度仪表环、琥珀色末端与白色指针，不使用 OpenAI 标识。母版保留透明边缘，便于 macOS 展示。

替换 `Resources/AppIcon.png` 后，运行：

```sh
./scripts/make-icon.sh
./scripts/build.sh
```

转换脚本仅使用 macOS 自带的 `sips` 与 `iconutil`，生成 16–1024 像素的标准图标尺寸。提交 PNG 母版和生成的 ICNS，构建时会复制 ICNS 并写入 `CFBundleIconFile`。中间 `.iconset` 放在被忽略的 `.build/` 中。

<details>
<summary>图标生成提示词</summary>

```text
Use case: logo-brand. Create one finished macOS application icon for an independent utility named Quota Companion that shows remaining Work/Codex usage quota. Asset: a square 1024x1024 icon master, straight-on, no device mockup. A refined dark midnight-navy rounded-square macOS icon tile with a subtle dimensional bevel and soft restrained shadow, surrounded by transparent margin. Center one bold, beautifully balanced circular quota gauge: an incomplete thick mint/teal ring, a small warm amber terminal segment, and a clean white gauge needle with a round hub. The gauge should read clearly at 32 pixels, with generous negative space. Premium native Mac productivity utility aesthetic, crisp geometry, restrained material depth, no busy detail, no text, no letters, no digits, no percent sign. Do not use the OpenAI knot logo or any existing brand logo. Single icon only. Transparent background outside the rounded-square tile; never a white or checkerboard backdrop.
```

</details>

## 提交修改

保持变更范围集中，说明行为变化和验证结果。提交前运行 `./scripts/test.sh`；涉及 app 打包或图标时同时执行 `./scripts/build.sh`，并验证生成的 bundle。

报告问题时提供系统、处理器架构、ChatGPT 版本、复现步骤和界面错误提示。截图请遮盖个人信息，不上传登录文件、令牌或原始账号响应。
