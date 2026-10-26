# TimeNoteCore

Swift 6.2、最低 macOS 14 的核心包，无外部依赖。

**这是一份可编译的领域算法与应用契约骨架，不是完整业务实现或可安装 App。**

## 已实现

- `TimeNoteDomain`：仅依赖 Foundation；`TimeEntry`、`TimerRun`、分类来源与手动锁等不可变 `Codable` / `Sendable` 值类型。
- `IntervalAnalytics.summarize`：将各活动裁切到统计窗口及 `asOf`，分别计算事项累计、区间并集覆盖、至少两项同时进行的时长、已过去但未记录的时长和峰值并发数。算法为 O(n log n) 的时间点扫描。
- `TimerPolicy`：计算独立番茄的截止时间，以及运行中开始时间修改的预览结果；原截止时间已到达时抛出 `originalDeadlineElapsed`，要求先协调结束；原截止未到、但修改后截止已到时返回 `requiresExplicitFinish`。策略不会替 UI 或业务层执行结束。
- `TimeNoteApplication`：值类型草稿、带 `operationID` 的命令 DTO、带 `expectedRevision` 的编辑契约，以及 start / manualRecord / finish / edit / reconcile / snapshot 协议。
- 12 个 Swift Testing 场景，覆盖并发、三重重叠、半开相邻、跨午夜、未来裁切、DST 日界限、独立截止时间、开始时间修正、非法输入和序列化。

## 尚未实现

生产存储、业务用例处理器、原子事务、持久化幂等记录、完整命令校验、通知调度、真实时钟驱动、定时后台、撤销服务、分类引擎、SwiftUI/AppKit UI 与系统权限均未实现。本包没有用假的内存存储冒充这些能力。

模型构造与 Codable 解码只是表达数据，不会自动保证数据库约束。后续命令处理器需要校验合法日期、时长、分类锁、时区、非负版本、run/entry 一对一关系，以及 running/finished/cancelled 与 entry.endAt 的一致性。策略函数只校验其所负责的输入。

## 集成约定

1. 每次开始创建新的 entry 和 run，开始即持久化开放记录；结束时关闭同一条 entry。再次开始创建新的 IDs，不能复用已结束 run。
2. 写入经过单一存储写入 actor；读取最新状态、校验修订号、写 entry/run 及操作收据在同一事务内完成，期间不 `await` 外部服务。
3. `operationID` 必须持久化去重。同一个 ID 重试返回既有结果；同 ID 不同内容报冲突。不能只靠按钮禁用保证幂等。
4. 编辑使用 `EntryDraft` 和 `expectedRevision`，不得直接双向绑定持久化对象。若原 deadline 已到，上游先协调该轮结束，再按历史记录编辑，不能通过后移开始时间续命。若原 deadline 未到，运行番茄修改开始时间后按新开始 + 原目标时长预览 deadline，并由用户明确确认修改导致的到期结束。
5. 修改 deadline 时增加 `scheduleVersion`。通知回调携带的旧版本不能结束已经重新排期的 run。`FinishTrigger.manual` 携带 `expectedEntryRevision`；`pomodoroDeadline` 只携带 `expectedScheduleVersion`，事务内读取并关闭最新 entry，保留最新标题和分类，不能因元数据改动导致 revision 变化而拒绝正常到期。通知副作用在提交成功之后执行；通知权限不影响记录结算。
6. 自动到期按各自 deadline 结束，不按唤醒或通知送达时间结束；普通计时继续。自动完成不走普通撤销；提前手动结束后的撤销也不能复活已超过原 deadline 的番茄。
7. `reconcile` 契约用于恢复时核对持久化 run，不自动补造遗漏的轮次。该协议目前没有实现，不能据此宣称应用已支持恢复。
8. snapshot 是一致读取；即使查询历史窗口，仍需带回全部运行项及其 entry，保持全局进行中区域完整。

## 时间区间规则

所有区间使用 `[start, end)`。首尾相接不算重叠；零长度区间不计入，反向区间报错。开放区间的截止为 `asOf`，显式结束也裁切到 `asOf`。窗口未来部分不算未记录。

`ActivityInterval(entry:)` 只有 entry、没有 run 信息，不知道开放记录是不是已经到期的番茄。调用方必须先执行到期协调，或在只读投影中把开放番茄的区间结束设置为 `min(asOf, run.deadline)`；不要直接把过期番茄的 nil endAt 传入后计算到现在。普通开放计时仍计算至 `asOf`。

调用方需先按 entry ID 去重，避免把同一记录的多个快照重复传入。三条不同记录即便起止相同，也必须分别传入并正常计为三重并发。

一天的窗口应由 `Calendar.dateInterval(of: .day, for:)` 在目标时区中生成，不能一律加 86,400 秒；夏令时切换日可能有 23 或 25 小时。区间算法只接受绝对时间，不猜测时区，也不会把跨午夜记录复制成多条。

例如三项都在 14:00—15:00，累计为 3 小时，覆盖为 1 小时，至少两项并发的时长仍是 1 小时。累计减覆盖得到的 2 小时不是“并发时长”。

## 构建与测试

在包目录执行：

```sh
bash Scripts/test.sh
```

脚本把构建与模块缓存放在包内 `.build/`，不修改系统开发工具或下载依赖。完整 Xcode 环境也可直接使用 `swift test`。

本机 Swift 6.2.3 使用 Command Line Tools，缺少 XCTest，并且自带 Testing 框架未进入默认搜索路径。脚本针对这一环境添加现有框架和宏插件路径；若可选 `_Testing_Foundation` overlay 缺失模块接口，则关闭自动 cross-import overlay。这不修改生产模块的逻辑；测试只使用基础 Swift Testing API。2026-10-23 已在此环境实际通过全部 12 个测试。

这些测试验证已实现的纯算法和类型契约；不证明尚未实现的存储、通知、并发命令事务或恢复行为正确。
