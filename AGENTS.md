# Ribbon 项目约定 (AGENTS.md)

## 结构

- RibbonBridge: C bridge target, 公共头在 `Sources/RibbonBridge/include/`
- RibbonCore: 库 target, `Sources/` (排除 `App/` 与 `RibbonBridge/`)
- Ribbon: 可执行 target, `Sources/App/main.swift`
- Tests/: 全部 swift-testing; 无 Xcode 工程, SwiftPM + Makefile

## 构建与验证

- `make` (release .app bundle) / `make test` / `make lint` / `make coverage` / `make dmg`; Makefile 是构建的唯一入口
- `make lint` = `-warnings-as-errors`: 任何新编译警告都会失败 CI
- `make test` 必须 `--no-parallel`: 测试共享进程级全局 `Log.path` (见下), 并行会串写
- CI (`.github/workflows/ci.yml`) 跑 lint + test + all, 固定 Xcode 16.3

## 测试

- 只用 swift-testing (`import Testing`), 禁止 XCTest
- 错误路径断言用 `#expect(throws:)`; 可失败前置用 `try #require()`
- 现状 35/38 个 suite 标了 `@Suite(.serialized)` (历史原因: 配置路径等进程级全局, 见路线图 §5.1); `LogTests` / `ThrottledLoggerTests` 已解除; 新测试尽量不依赖进程级全局状态
- 同构用例用 `@Test(arguments:)`: 用例载体类型需 `Sendable` + `CustomTestStringConvertible` (否则失败只报 "case N of M", 丢失场景可读性); 注意 runner 的 `Test run with N tests` 统计声明数而非用例数
- 断言日志内容时注入 `ThrottledLogger { ... }` 或自建 `LogFileSink`, 不要读进程级日志文件
- 确需改 `Log.path`: 先保存旧值, `defer` 恢复 (参考 Tests/LogTests.swift 的写法)

## 日志

- `Sources/Log.swift`: stderr + `~/Library/Logs/ribbon.log` 双写; `Log.path` 可重定向 (`RIBBON_LOG_PATH`)
- 文件 sink 是 README 对外契约, 不得移除

## 并发

- GCD-first: serial `DispatchQueue` + main queue hop 为主
- async/await 只存在于 `Sources/OpenCode/` 三文件 (OpenCodeClient / AgentBridge / EventStream); 新代码不要把 GCD 类型大面积改 async, 在已有 async 边界内扩展
- 不新增 `@unchecked Sendable` (现存 9 处, 含 2026-11-08 新增的 `LogFileSink`: 全部状态由单一 NSLock 守卫; 待阶段 3 收敛)
- 禁止跨 `await` 持 `NSLock` (见 EventStream.swift:306 注释)
- Package.swift 是 swift-tools-version 5.9 / Swift 5 语言模式, 未开 strict concurrency - 开了会炸现存 `@unchecked` 位点

## 平台与 API 边界

- macOS 13.0+, 纯 AppKit; 无 SwiftUI / SwiftData
- DFRFoundation / DisplayServices 私有 API 是已知并接受的风险 (README "Known limits")
- 不新增任何 TCC 权限请求; 不入沙盒

## UI 不变量

- chip 固定 56pt 宽 (行溢出时均匀压缩, 下限 40pt); 第 10 个工作区显示 `0`
- bar 内容与 Touch Bar 边缘齐平, 无左右 margin
- 电量槽 30pt 右对齐; 电池与时钟间隙恒 2pt

## 格式化

- `ClockFormat.swift` 必须用 `DateFormatter`: `clock.json` 允许用户填任意 ICU pattern, `Date.FormatStyle` 不接受原始 ICU 串 - 这是有意例外, 不要"现代化"它

## 文档同步

- 改动用户可见行为 (日志路径 / clock.json / 菜单项 / 配置文件格式) 必须同步更新 README 对应小节

## 技能

- `.opencode/skills/` 有 9 个已安装技能可用; 使用顺序与出口条件见 `docs/plans/2026-11-08-code-quality-skills-roadmap.md`
