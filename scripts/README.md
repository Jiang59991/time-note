# 构建与分发脚本

- `bash scripts/build-app.sh`：macOS 双架构构建、图标生成、嵌入 LICENSE/NOTICE 和本地签名。
- `bash scripts/build-icon.sh`：将已确认 Logo 转换为 macOS ICNS。
- `bash scripts/package-release.sh`：生成 ZIP、SHA256SUMS 及下载说明；需先构建 App。
- `bash scripts/install-macos.sh`：下载已发布的 Mac 二进制并校验安装。

开发构建见 CONTRIBUTING.md，用户及安装助手请先阅读 INSTALL.md。不得提交个人账本或凭证。
