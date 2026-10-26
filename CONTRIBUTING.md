# 源码构建与验证

源码遵循 LICENSE 与 NOTICE 的非商业使用条款。运行版为 AppKit + 本地 WKWebView，纯 Swift 核心包负责部分计时和区间规则；Web 文件单独打开不能替代原生桥。

## 构建 Mac App

需要 macOS 和 Apple Command Line Tools（当前使用 Swift 6.2.3），无需生产 Node 依赖。

```sh
bash scripts/build-app.sh
open "build/Time Note.app"
```

默认构建 arm64 + x86_64 通用 App；最低目标 macOS 14。图标源在 `design/assets/time-note-logo-v3.png`。本地脚本生成 ad-hoc 签名，不执行 Apple 公证。

```sh
bash scripts/package-release.sh
```

生成带 LICENSE/NOTICE 的版本化 ZIP 和 SHA256SUMS，详见 scripts/README.md。

## 验证

```sh
bash packages/TimeNoteCore/Scripts/test.sh
bash tests/app/run-store-tests.sh
bash tests/app/native-tests.sh
```

Web 交互和真实 WKWebView／进程重开检查见 tests/app/README.md。所有 App 集成测试必须把 TIME_NOTE_DATA_DIR 指向独立临时目录，不使用真实账本。

当前桥接契约见 app/TimeNoteApp/BRIDGE.md，用户操作说明见 docs/11-user-guide.md。开发期设计参考和私人图片不随本次源码公开发布。
