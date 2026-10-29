# Time Note 1.2.0 预发布版

macOS 14+，Apple Silicon / Intel 通用包。实机测试为 Apple Silicon / macOS 26.2；Intel 和 macOS 14 尚未实机验证。

下载 TimeNote-1.2.0-macOS-universal.zip，解压后将 Time Note.app 拖入应用程序目录。首次使用为空账本；数据保存在本机 Application Support / Time Note，应用更新不会主动清空账本。建议先使用应用菜单导出 JSON 备份。

注意：本版本仅有 ad-hoc 本地签名，尚未 Developer ID 签名，也未通过 Apple 公证。macOS 可能阻止从网络下载的 App 首次打开。本版本供早期测试；如需常规签名与公证后的安装体验，请等待后续发行版。没有应用内自动更新，请手动下载后续版本。

应用无需账户或网络服务，支持并发计时、番茄、补记、周览、未完成 Todo 跨天延续，以及可新增／改名／预设换色／删除的标签管理（新增“生活”）。删除标签只将记录归到“其他”，不删除时间记录。问题反馈：https://github.com/Jiang59991/time-note/issues

非商业许可：PolyForm Noncommercial 1.0.0。完整 LICENSE 与 NOTICE 均在 App 的 Contents/Resources 内，亦可在项目仓库查看：https://github.com/Jiang59991/time-note

校验下载文件：在下载目录运行 `shasum -a 256 TimeNote-1.2.0-macOS-universal.zip`，将结果与 `SHA256SUMS` 中该文件对应的一行比较，应完全一致。SHA256 用于校验文件完整性，不等于 Apple 公证。

旧账本和备份会补入默认标签；保存新标签配置后请用 1.2.0 或更新版本打开。
