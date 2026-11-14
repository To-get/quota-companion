# 开发说明

## 环境与命令

需要 macOS 14+、Swift 6.0+ 和匹配的 macOS SDK。项目使用 Swift Package Manager、AppKit、SwiftUI 和 ServiceManagement，无第三方生产依赖。

```sh
./scripts/test.sh
./scripts/build.sh
./dist/ChatGPT额度助手.app/Contents/MacOS/QuotaCompanion --check
```

- `test.sh` 使用 Swift Testing；RPC 测试使用系统 `/usr/bin/python3` 模拟子进程，会话统计测试使用临时 `CODEX_HOME` 构造记录，都不访问真实账号。
- `build.sh` 构建当前主机架构的 Release 可执行文件，组装 `.app` 并进行 ad-hoc 签名，不生成通用二进制或执行公证。
- `--check` 会通过 ChatGPT 内置服务联网读取真实额度；仅输出窗口、剩余百分比与重置倒计时，不输出账号、令牌或原始响应。目前自检入口固定检查 `/Applications/ChatGPT.app`。
- `--sessions` 只读本机会话记录并打印各会话的 token 表，不联网、不写入文件，适合核对统计口径。
- `--ping` 会真实新建会话、发送「你好」并归档（消耗额度），用于验证自动固定刷新时间；仅在需要时手动执行。

不要用单独的 `swift run` 代替打包后的 app 验证登录项和图标；这些行为依赖应用 bundle。

本机 Swift 6.4 默认构建引擎需要显式指定测试宏插件路径，测试脚本会在工具链提供 `plugins/testing` 目录时补上这个路径。构建脚本通过 SwiftPM 查询产物位置，适应不同版本的输出目录。移动项目目录后，若提示模块缓存路径不匹配，先将旧 `.build/` 移出项目再重新构建。

## 目录

```text
Package.swift                    SwiftPM 清单
Sources/QuotaCompanion/           菜单栏、面板、会话刷新、自动发送 UI、生命周期与登录项
Sources/QuotaCore/                额度解析、JSON-RPC、会话 token 统计与自动发送
Tests/QuotaCoreTests/             解析、会话增量、空窗口策略、CLI 运行器与模拟 RPC 测试
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

## 会话 Token 数据源

面板的 token 统计不经过 RPC，直接读取本机会话记录：

```text
<CODEX_HOME>/sessions/YYYY/MM/DD/rollout-<时间>-<uuid>.jsonl
<CODEX_HOME>/session_index.jsonl           # id → thread_name
<CODEX_HOME>/archived_sessions/rollout-*      # 已归档（.jsonl 或 .jsonl.zst），不解析
```

- 每个 rollout 文件首行的 `session_meta` 提供会话 id、cwd、开始时间、`thread_source` 与子代理的 `parent_thread_id`；文件后段可能再追加父会话的 meta，因此身份只取首行。
- `turn_context` 提供 `turn_id → model`；`token_usage_record.usage` 是逐响应增量，累加等于服务端累计值；`event_msg/token_count` 是累计快照，仅在旧格式没有逐响应记录时回退使用，避免重复计数。
- 只对含 `session_meta`、`turn_context`、`token_usage_record`、`token_count` 的行做 JSON 解析，消息正文与图片不会进入解析。
- 扫描器按 offset 增量读取，未闭合的行留到下次；文件变短视为截断并从头重解析。只完整解析最近 10 个父会话，更早的会话只读首行 meta。
- 不使用 `state_5.sqlite`：该库为 WAL 模式，当前没有 `-wal/-shm` 时只读连接会失败，`immutable=1` 又看不到最新数据。若以后需要历史标题，可考虑复制 db 与 wal 到临时目录再打开。
- 统计口径变更、模型归属规则变更或新增记录类型时，先补 `SessionUsageTests` 的夹具，再改解析代码。

无界面核对：

```sh
./dist/ChatGPT额度助手.app/Contents/MacOS/QuotaCompanion --sessions
```

## 自动固定刷新时间

空窗口的 `resetsAt` 会随当前时间滑动，发送一次消息后固定为「发送时刻 + 窗口时长」。实现只用 Codex CLI 的公开自动化入口：

```sh
codex exec --json --color never --ignore-user-config \
  -c forced_login_method="chatgpt" -c approval_policy="never" \
  -c model_reasoning_effort="low" -s read-only --skip-git-repo-check \
  -C <Application Support>/QuotaCompanion/ping 你好
codex archive <thread_id>
```

- `exec --json` 输出 `thread.started`（`thread_id`）、`turn.completed`（`usage`）、`turn.failed`；其余事件忽略。
- `--ignore-user-config` 跳过用户的 MCP/插件，保持回合轻量；认证仍来自 `CODEX_HOME/auth.json`（ChatGPT 订阅登录）。
- 拿到 `thread_id` 后立即归档；回合失败或超时也尝试归档，避免留下「你好」会话。归档失败重试一次，仍失败则在面板提示。
- 空窗口判定不能只看 `usedPercent`：一次发送的用量可能四舍五入为 0%。判定条件是 `remaining >= 99.9` **且** `resetsAt ≈ now + duration`（容差 180 秒）。发送后 `resetsAt` 固定，窗口自然变成“非空”并重新 armed。
- 状态机在 `AnchorState`：目标窗口是 `codex.*` 且时长 300/10080 分钟；成功 disarm，窗口出现用量后 re-arm；失败按 1/5/15/30 分钟退避，最多 10 次。
- 自动化开启时额度客户端在 ChatGPT 退出后继续运行，以便按时发现空窗口；关闭后恢复原行为。
- 为什么不用 app-server RPC：`thread/start` / `turn/start` 仍是实验性协议，CLI 的事件与 `archive` 子命令更稳定；运行器与策略都可以用假可执行文件测试。

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
