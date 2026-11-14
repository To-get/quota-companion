# 验证记录

最近验证：2026-11-14（Asia/Shanghai）。此记录只代表下列环境与检查范围。

## 验证环境

| 项目 | 环境 |
| --- | --- |
| 系统 | macOS 27.0.1 |
| 处理器架构 | Apple Silicon / arm64 |
| 工具链 | Apple Swift 6.4.2，Xcode Command Line Tools |
| ChatGPT 桌面端 | 26.1106.51428（26605），`com.openai.codex` |
| 应用版本 | 1.2.0（构建号 3） |
| 签名 | 本地 ad-hoc，未公证 |

## 本次结果

| 检查 | 结果 |
| --- | --- |
| `./scripts/test.sh` | 50 项 Swift Testing 测试全部通过（额度 10、会话 13、空窗口策略 13、CLI 运行器 7、自动化控制器 7） |
| `./scripts/build.sh` | Release 构建成功，生成 arm64 app |
| `zsh -n scripts/build.sh scripts/test.sh scripts/make-icon.sh` | 脚本语法通过 |
| `plutil -lint` | 应用 Info.plist 校验通过 |
| `codesign --verify --strict` | 通过；仅证明当前 ad-hoc 签名完整性 |
| `lipo -archs` | 可执行文件为 `arm64` |
| app 图标 | ICNS 包含 16–1024 像素资源；bundle 中资源与源文件一致，`CFBundleIconFile` 引用正确 |
| 系统图标解析 | 使用 `NSWorkspace` 获取生成的 app 图标并渲染，人工确认显示新仪表图标 |
| `QuotaCompanion --check` | 成功读取真实额度窗口；本记录不保留个人额度快照 |
| `QuotaCompanion --sessions` | 7 个会话的累计 token 与独立脚本从 rollout 计算的结果逐项一致；2 个子代理会话正确并入父会话 |
| `QuotaCompanion --ping` | 真实发送一次「你好」：会话 `01a1d933…`，23,820 tokens（输入 23,806 / 缓存 12,288 / 输出 14），已归档 |
| 锚定效果 | 发送前 5 小时窗口的 `resetsAt` 每次读取都等于「当前时间 + 18000 秒」（滑动）；发送后两次相隔 70 秒读取，倒计时 4 小时 59 分 → 4 小时 58 分（固定） |
| 自动化面板 | 临时预览窗口核对「自动固定刷新时间」开关、说明与上次结果行 |
| 会话面板渲染 | 用合成夹具渲染面板：总量、输入/缓存/输出/推理、3 个模型占比、子代理提示与增量刷新均正确 |
| 文档链接 | 所有本地 Markdown 链接与图标路径均存在 |
| 上传清单 | 27 个源码、文档和资源文件；常见缓存、安装包、凭证路径均被忽略 |

测试覆盖多窗口解析、最低剩余值、窗口时长命名、多额度桶、旧协议回退、缺失或非法字段、零额度、重置边界与分段 JSON-RPC 握手；会话部分覆盖增量累加、缓存不重复计入、按模型拆分、缺失模型回退、累计快照回退、半行与损坏行、文件截断重解析、子代理合并、标题回退与会话排序；自动化部分覆盖空窗口判定（滑动 `resetsAt` 与四舍五入为 0% 的已锚定窗口）、armed/退避/上限、状态持久化、假可执行文件的发送与归档、超时与失败、控制器只发送一次。RPC 自动测试使用模拟服务，其余测试使用临时目录，都不依赖个人账号。

## 构建兼容性处理

本次从旧目录迁移的缓存包含过时的绝对路径。将旧 `.build/` 移出项目后重新构建；缓存不应随源码上传。

本机 Swift 6.4 默认构建引擎未自动加载 `TestingMacros`。测试脚本已在工具链存在 `plugins/testing` 时显式指定宏搜索路径；构建脚本通过 `--show-bin-path` 查询实际产物位置，不固定假设 `.build/release`。

自动执行环境中，macOS 图标转换、系统图标解析和 AppKit 自检需要在沙箱外运行；这不等于 app 面向用户需要管理员权限。

## 尚待验证

- 其他 macOS 版本，尤其是最低声明版本 macOS 14。
- Intel 构建和运行、Universal 打包。
- 不同版本 ChatGPT 桌面端的服务路径与协议兼容性。
- 手动完整检查菜单面板、退出和重开 ChatGPT、睡眠唤醒等交互。
- 真实弹窗中的会话选择交互；本机菜单栏较满时状态栏图标会被系统收进隐藏区，需要先腾出位置再点击。
- 真实 5 小时/每周窗口空出时的自动触发（本次 5 小时窗口已锚定，需等下次空出，或睡眠后唤醒补发）。
- 睡眠唤醒后的补发、ChatGPT 未运行时的持续轮询与发送。
- 归档失败时面板提示与手动归档流程。
- 已归档会话（`archived_sessions/*.jsonl.zst`）的统计；当前版本不解析压缩记录。
- 重启系统后的登录项行为。
- Developer ID 签名、Apple 公证及从互联网下载后的安装体验。

历史记录：2026-10-26 已通过 10 项测试、Release 构建及真实额度自检；2026-10-28 补充图标和 GitHub 发布文档验证；2026-11-14 新增会话 token 统计，23 项测试通过，`--sessions` 与真实记录核对一致；同日新增自动固定刷新时间，50 项测试通过，`--ping` 真实发送并归档，发送后 5 小时窗口重置时间由滑动变为固定。面板截图与完整交互验收仍未完成，系统图标解析通过不代表所有 GUI 流程已验证。

## 复核命令

```sh
./scripts/test.sh
./scripts/build.sh
plutil -lint 'dist/ChatGPT额度助手.app/Contents/Info.plist'
codesign --verify --strict 'dist/ChatGPT额度助手.app'
lipo -archs 'dist/ChatGPT额度助手.app/Contents/MacOS/QuotaCompanion'
./dist/ChatGPT额度助手.app/Contents/MacOS/QuotaCompanion --check
./dist/ChatGPT额度助手.app/Contents/MacOS/QuotaCompanion --sessions
./dist/ChatGPT额度助手.app/Contents/MacOS/QuotaCompanion --ping   # 会真实消耗额度
```

最后一条命令会联网读取实际账号额度；其余构建和模拟测试不需要个人登录数据。
