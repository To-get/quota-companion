# 验证记录

最近验证：2026-10-28（Asia/Shanghai）。此记录只代表下列环境与检查范围。

## 验证环境

| 项目 | 环境 |
| --- | --- |
| 系统 | macOS 27.0.1 |
| 处理器架构 | Apple Silicon / arm64 |
| 工具链 | Apple Swift 6.4，Xcode Command Line Tools |
| ChatGPT 桌面端 | 26.1021.31345（21828），`com.openai.codex` |
| 应用版本 | 1.0.0（构建号 1） |
| 签名 | 本地 ad-hoc，未公证 |

## 本次结果

| 检查 | 结果 |
| --- | --- |
| `./scripts/test.sh` | 10 项 Swift Testing 测试全部通过 |
| `./scripts/build.sh` | Release 构建成功，生成 arm64 app |
| `zsh -n scripts/build.sh scripts/test.sh scripts/make-icon.sh` | 脚本语法通过 |
| `plutil -lint` | 应用 Info.plist 校验通过 |
| `codesign --verify --strict` | 通过；仅证明当前 ad-hoc 签名完整性 |
| `lipo -archs` | 可执行文件为 `arm64` |
| app 图标 | ICNS 包含 16–1024 像素资源；bundle 中资源与源文件一致，`CFBundleIconFile` 引用正确 |
| 系统图标解析 | 使用 `NSWorkspace` 获取生成的 app 图标并渲染，人工确认显示新仪表图标 |
| `QuotaCompanion --check` | 成功读取真实额度窗口；本记录不保留个人额度快照 |
| 文档链接 | 所有本地 Markdown 链接与图标路径均存在 |
| 上传清单 | 16 个源码、文档和资源文件；常见缓存、安装包、凭证路径均被忽略 |

测试覆盖多窗口解析、最低剩余值、窗口时长命名、多额度桶、旧协议回退、缺失或非法字段、零额度、重置边界与分段 JSON-RPC 握手。RPC 自动测试使用模拟服务，不依赖个人账号。

## 构建兼容性处理

本次从旧目录迁移的缓存包含过时的绝对路径。将旧 `.build/` 移出项目后重新构建；缓存不应随源码上传。

本机 Swift 6.4 默认构建引擎未自动加载 `TestingMacros`。测试脚本已在工具链存在 `plugins/testing` 时显式指定宏搜索路径；构建脚本通过 `--show-bin-path` 查询实际产物位置，不固定假设 `.build/release`。

自动执行环境中，macOS 图标转换、系统图标解析和 AppKit 自检需要在沙箱外运行；这不等于 app 面向用户需要管理员权限。

## 尚待验证

- 其他 macOS 版本，尤其是最低声明版本 macOS 14。
- Intel 构建和运行、Universal 打包。
- 不同版本 ChatGPT 桌面端的服务路径与协议兼容性。
- 手动完整检查菜单面板、退出和重开 ChatGPT、睡眠唤醒等交互。
- 重启系统后的登录项行为。
- Developer ID 签名、Apple 公证及从互联网下载后的安装体验。

历史记录：2026-10-26 已通过 10 项测试、Release 构建及真实额度自检；本次更新补充图标和 GitHub 发布文档验证。面板截图与完整交互验收仍未完成，系统图标解析通过不代表所有 GUI 流程已验证。

## 复核命令

```sh
./scripts/test.sh
./scripts/build.sh
plutil -lint 'dist/ChatGPT额度助手.app/Contents/Info.plist'
codesign --verify --strict 'dist/ChatGPT额度助手.app'
lipo -archs 'dist/ChatGPT额度助手.app/Contents/MacOS/QuotaCompanion'
./dist/ChatGPT额度助手.app/Contents/MacOS/QuotaCompanion --check
```

最后一条命令会联网读取实际账号额度；其余构建和模拟测试不需要个人登录数据。
