# 运行版验证

## 原生逻辑

```sh
bash packages/TimeNoteCore/Scripts/test.sh
bash tests/app/run-store-tests.sh
bash tests/app/native-tests.sh
```

存储测试自行创建临时数据目录，验证磁盘持久化、并行命令、截止恢复、版本冲突、去重、导入和写入失败，以及 Todo 午夜延续、历史完成项保留、连续离线后重开、未来计划和迁移后的旧命令拒绝。可用 `TZ=America/New_York build/store-tests/store-tests` 复核夏令时跨日。通知测试仅验证计划，不代替用户授予权限，也不声称已观察到系统横幅。

## Web 界面

需要 Node、Playwright 和已安装的 Google Chrome；这些仅为开发测试依赖。

```sh
node tests/app/web-check.cjs --syntax
node tests/app/web-check.cjs
```

测试使用独立无头浏览器和内存模拟 Native 桥，覆盖表单、跨日和 DST、重叠、分类、Todo、错误草稿保留等交互。它不代表真实磁盘集成。Playwright 需在 Node 的依赖搜索路径中；项目没有生产 npm 依赖。

## 真实 Mac / WebKit 集成

```sh
bash scripts/build-app.sh
TIME_NOTE_DATA_DIR="$PWD/work/smoke-new" "build/Time Note.app/Contents/MacOS/TimeNote" --smoke-test
TIME_NOTE_DATA_DIR="$PWD/work/smoke-new" "build/Time Note.app/Contents/MacOS/TimeNote" --smoke-test --smoke-reopen
```

第一条冒烟必须使用新的空数据目录。测试通过实际 WKWebView 与原生消息桥写入并发计时、补记和 Todo，等待原生计时器自动结算番茄；同时验证过往未完成 Todo 经真实桥接迁移到今天；第二次进程检查磁盘恢复与延续项不重复。结果写到该隔离目录的 `smoke-result.json` 与 `native-week.png`；退出码 0 表示通过。测试参数未设置独立数据目录时应用拒绝执行。

结果及未实测范围见 `docs/12-release-verification.md`。

悬浮球保护测试：使用新的独立 TIME_NOTE_DATA_DIR 运行应用二进制并传入 `--orb-test`，结果写入 `orb-result.json`。


标题输入原生回归：使用新的独立 `TIME_NOTE_DATA_DIR` 运行应用二进制并传入 `--title-input-test`，结果写入该目录的 `title-input-result.json`。该测试使用真实 AppKit 鼠标／键盘事件和 WebKit 文本输入客户端，覆盖未激活悬浮展开、点击标题、删除、英文输入、中文组合文本提交及原生桥保存，不用 JS 赋值来代替输入验证。


1.2.0 标签管理回归：StoreEngine 覆盖旧 V1 默认补全、自定义 UUID、重复操作、名称／颜色校验、修订冲突、备份恢复、删除时原子归类及写入失败；Web 覆盖预设调色、新增／改名／换色／删除、失败草稿、周统计及进行中分类名即时刷新。真实 WKWebView 冒烟经标签管理界面提交命令，删除时验证记录保留，并在独立进程重开时验证自定义标签恢复。
