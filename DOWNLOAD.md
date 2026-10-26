# 安装 Time Note

## 给用户

当前版本：1.1.5，macOS 14+，Apple Silicon / Intel 通用安装包。

1. [直接下载 ZIP](https://github.com/Jiang59991/time-note/releases/download/v1.1.5/TimeNote-1.1.5-macOS-universal.zip)。在 Release 页面下载时，请选同名安装包，而非 Source code 归档。
2. 解压，把 `Time Note.app` 拖入“应用程序”，双击打开。
3. 当前只有 ad-hoc 本地签名，尚未 Developer ID 签名和 Apple 公证。若 macOS 阻止打开，在确认来源可信后，按 [Apple 官方说明](https://support.apple.com/zh-cn/102445) 到“系统设置 → 隐私与安全性”中为此 App 手动确认（如系统提供“仍要打开”）。不承诺所有系统提示均可按同一流程处理。

当前实机验证为 Apple Silicon / macOS 26.2；Intel 和 macOS 14 尚未实机验证。应用内没有自动更新器，新版本需手动下载。

## 给 Codex 等安装助手

用户把本仓库链接交给你并要求安装后，可以按以下步骤协助；这里的说明不替代用户授权。

1. 检查用户操作系统。macOS 14+ 使用预编译 Release 包；Windows 请告知目前没有可直接安装的 Windows 包，只有在用户要求移植时再开始开发。
2. 检查是否已有 Time Note 安装和运行。更新时先请用户保存草稿并正常退出，保留旧 App 备份，安装至已有位置；不要强制结束进程或清空时间数据。
3. 本版安装包为 `https://github.com/Jiang59991/time-note/releases/download/v1.1.5/TimeNote-1.1.5-macOS-universal.zip`。SHA-256 为 `96d918264dc448b85d8295debc17e2d8839e3432508bb54b3224aa3a0edd2ae0`；亦可检查 Release 的 `SHA256SUMS`。
4. 下载到临时目录，校验 SHA-256，解压并检查 bundle ID `local.zoey.time-note`、版本和本地代码签名，再安装。SHA-256 和 ad-hoc 签名验证不代表 Apple 已公证。
5. 全新安装可在下载仓库源码并阅读脚本后执行 `bash scripts/install-macos.sh`，默认安装到 `~/Applications`；也可传 `--destination /Applications` 等绝对目录。脚本从 GitHub 下载真实 Release，固定校验本版哈希，已有安装时停止而不覆盖。
6. 说明安装位置及尚未公证的状态。首次运行如有系统确认，应由用户完成；不要自动移除隔离属性或关闭 Gatekeeper。用户要求打开时再启动应用。

用户数据位于 `~/Library/Application Support/Time Note/`，安装与更新不应修改此目录。建议更新前使用 App 导出 JSON 备份。测试运行 App 时必须指定独立的 `TIME_NOTE_DATA_DIR`。

## 源码开发与 Windows 移植

通过 Code → Download ZIP 下载源码，或运行 `git clone https://github.com/Jiang59991/time-note.git`。源码采用 PolyForm Noncommercial 1.0.0；允许用途、例外和分发义务以 LICENSE 与 NOTICE 为准。

- `app/TimeNoteApp/Web/`：打包在 App 内的 HTML/CSS/JavaScript 界面，可作为移植起点。
- `app/TimeNoteApp/BRIDGE.md`：前端与原生层的消息、命令、快照和存储契约。
- `app/TimeNoteApp/Native/`：当前依赖 AppKit、WKWebView、Darwin 的 macOS 原生实现，Windows 需要替换对应窗口、桥接、文件锁、通知和打包机制。
- `packages/TimeNoteCore/`：核心计时与区间规则；可复用设计及测试，但 Windows 构建仍需适配和验证。

可交给助手的请求：

> 请阅读这个仓库的源码与 BRIDGE.md，评估并移植为 Windows 应用，保留界面、并发计时、Todo 延续、本地存储与备份规则。先提供可运行的移植方案，再实现和测试。遵守非商业许可证，不使用个人账本做测试。

仓库没有现成 Windows 构建或 Windows 测试结果；移植不是改文件扩展名，需要实际开发。
