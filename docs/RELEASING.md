# GitHub 上传与发布指南

## 源码仓库应包含什么

以下是本项目应提交的文件与目录：

```text
.gitignore
Package.swift
Sources/
Tests/
Resources/
scripts/
README.md
CONTRIBUTING.md
VALIDATION.md
docs/
LICENSE
```

`Resources/` 中的 PNG 母版与 ICNS 都要提交：前者便于修改，后者供构建脚本直接使用。`scripts/` 应保留可执行权限。

## 哪些内容不提交

| 内容 | 处理方式 |
| --- | --- |
| `.build/`、`.swiftpm/` | 本机构建与工具缓存，由构建命令重新生成 |
| `dist/`、`.app`、`.zip`、`.dmg` | 二进制发布物放到 GitHub Releases 的附件中 |
| `.DS_Store`、日志 | 忽略本机元数据和临时输出 |
| `.env*`、签名证书与私钥 | 保留在本地或专用密钥管理服务中 |
| `.codex/`、`.agents/`、`.aws/` | 本机工具配置不属于本项目的公开源码 |
| ChatGPT app、账号凭证、运行数据库 | 不复制到项目，不打包分发 |

这些常见本机文件已由 `.gitignore` 排除；提交前仍需检查暂存区，尤其是截图、测试夹具和手动新增的文件。

## 首次推送源码

在 GitHub 创建空仓库，不预先添加 README 或许可证。本目录尚未初始化 Git 时，在项目根目录执行：

```sh
git init -b main
git add .gitignore Package.swift Sources Tests Resources scripts README.md CONTRIBUTING.md VALIDATION.md docs LICENSE
git status --short
git diff --cached --stat
git diff --cached
```

确认暂存内容只有预期源码、文档和图标，没有私密数据，再提交：

```sh
git commit -m "Initial release of Quota Companion"
```

把下面地址替换成你实际创建的仓库地址，再执行：

```sh
git remote add origin https://github.com/YOUR_USERNAME/YOUR_REPOSITORY.git
git push -u origin main
```

若目录已初始化或已配置远端，不重复执行 `git init` 或 `git remote add`。推送源码不会自动创建 Release。

## 发布可下载的 app

先运行测试与构建，并检查产物：

```sh
./scripts/test.sh
./scripts/build.sh
plutil -lint 'dist/ChatGPT额度助手.app/Contents/Info.plist'
codesign --verify --strict 'dist/ChatGPT额度助手.app'
lipo -archs 'dist/ChatGPT额度助手.app/Contents/MacOS/QuotaCompanion'
```

手动确认 Finder 中图标正确、菜单面板可打开、真实额度可读取、登录项可用。发布前请同时查看 [验证记录](../VALIDATION.md) 中尚未完成的项目。

默认脚本只进行 ad-hoc 签名，未经过 Apple 公证。若按测试版分发，在 Release 标题和说明中明确写明签名、公证和已验证系统的情况；面向普通用户的正式分发建议使用 Developer ID 签名并完成 [Apple 公证流程](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)。不要把 ad-hoc 校验通过写成 Apple 已认证。

当前本机构建为 Apple Silicon / arm64 时，可用系统 `ditto` 打包，保留 app bundle 结构：

```sh
ditto -c -k --sequesterRsrc --keepParent \
  'dist/ChatGPT额度助手.app' \
  'dist/QuotaCompanion-v1.0.0-macos-arm64.zip'
shasum -a 256 'dist/QuotaCompanion-v1.0.0-macos-arm64.zip'
```

在对应源码提交上创建 `v1.0.0` 标签，再从 GitHub 的 Releases 页面选择该标签，上传 ZIP 附件和校验值。版本号应与 `scripts/build.sh` 中的 `CFBundleShortVersionString` 一致；后续版本同步递增 `CFBundleVersion`。不要将 Intel 构建标成 arm64，也不要将单架构构建称作 Universal。

Release 说明至少包含：

- 版本变化。
- 支持和已验证的 macOS 版本、处理器架构。
- 需要带 Codex 服务的 ChatGPT 桌面端及有效登录状态。
- ad-hoc / Developer ID 签名与公证状态。
- 已知限制和安装方法。
- 安装包 SHA-256。

源码和安装包是两类发布内容。GitHub 官方也建议通过 [Releases 分发二进制](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)。
