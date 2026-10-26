# Time Note 应用

当前运行入口是 `Native/AppMain.swift`，界面来自打包的 `Web/index.html` 与 `Web/app.js`。本应用没有本地 HTTP 服务。

根目录执行 `bash scripts/build-app.sh`，生成 `build/Time Note.app`。`BRIDGE.md` 是 Native 与 Web 的共享契约；界面只发送有明确目标的命令，不直接保存整个账本。

Native StoreEngine 使用 actor 串行化操作并原子提交版本化 JSON。默认账本位于 `~/Library/Application Support/Time Note/store.json`；测试必须设置 `TIME_NOTE_DATA_DIR`。应用目录中的任何资源都不保存用户记录。

Native SmokeTest 仅在明确传入测试参数且指定隔离数据目录时启动，不能在正常启动时产生测试数据。通知测试采用纯计划器校验，不向用户发送测试提醒。

完整用户说明与实际验收结果见根目录 `docs/11-user-guide.md`、`docs/12-release-verification.md`。
