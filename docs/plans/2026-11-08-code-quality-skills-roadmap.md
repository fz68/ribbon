# 代码质量提升 - 技能路线图

日期: 2026-11-08
仓库: ribbon (本仓库)
基线提交: 64e7bb8 (refactor: fold the monitor wiring in, drop the dead members, share the test helpers)
状态: 阶段 0 完成 — 基线已测全并回填 (§3.2); 工具链已修复 (§3.3); AGENTS.md 已落地; 尚未提交
关联: `.opencode/skills/` 下 9 个技能 (2026-11-08 自 twostraws/Swift-Agent-Skills 索引精选安装)

## 1. 目标

- 按 §5 的顺序使用 9 个已安装技能提升代码质量, 每阶段有可验证的出口条件
- 顺序主线: 测试护栏 → 可观测性 → 并发正确性 → API/架构定形 → 风格/无障碍/文案 → 分发

## 2. 非目标

- 不为用技能而重构: architecture 技能只作诊断读物, 不做 MVVM/TCA 化
- 不改 README 对外契约: `~/Library/Logs/ribbon.log` 文件 sink 保留; `clock.json` 的 ICU pattern 继续用 `DateFormatter`
- 不引入 swift-security-expert / swiftui-design-principles (与本项目无关, 见 §7)
- 不新增任何 TCC 权限请求
- 本计划不修工具链; 修复方式由维护者决定 (§3.3)

## 3. 基线 (2026-11-08 实测)

### 3.1 静态事实

| 指标 | 值 |
|---|---|
| Swift 源文件 (Sources/) | 51 个, 8468 行 |
| 测试文件 (Tests/) | 38 个, 5999 行 |
| TODO/FIXME/XXX | 0 |
| 测试框架 | 38/38 `import Testing`, 0 XCTest |
| `@Suite(.serialized)` | 37/38 (唯一例外: TestSupport.swift, 无 suite) |
| `@MainActor` suite | 1 (Tests/TouchBarChipsTests.swift:5) |
| `@Test` 声明 | 266 个, 其中 async 11 个 (全部在 OpenCodeEventStreamTests.swift) |
| `#expect(throws:` | 3 处 |
| `try #require(` | 46 处 |
| `Log.path` 全局依赖 (测试侧) | 4 文件 12 处: LogTests 5, ParsingTests 3, TestSupport 1, ThrottledLoggerTests 3 |
| `RIBBON_LOG_PATH` | 仅 Sources/Log.swift 3 处, 测试不直接读 |
| 最大源文件 | AgentSessionStore.swift 563 行, EventStream.swift 519, AgentBridge.swift 437, AppDelegate.swift 358, TouchBarController.swift 356 |
| 最大测试文件 | OpenCodeAgentStoreTests.swift 840 行, OpenCodeEventStreamTests.swift 712, ConfigTests.swift 461 |
| 工具链 | Xcode 26.3 (17C529) / Swift 6.2.4, xcode-select 指向 Xcode, macOS 15.8.2, arm64; 磁盘上另有 CLT 16.4 (Swift 6.1.2), 与 Xcode 不同版 |

### 3.2 动态基线 (2026-11-08 工具链修复后实测, 全绿)

| 命令 | 结果 |
|---|---|
| `make lint` | 绿, 0 警告, 26.97s (冷编译; 两个半区都过) |
| `make test` | 绿: 37 suites / 266 tests 全过, 0 失败 0 跳过; 测试本体 25.98s, 含构建 35.61s |
| `make coverage` | 绿, 38.05s; TOTAL 行覆盖 85.12% (Sources+Tests 合并) |

行覆盖拆分 (对 87 个文件的行数求和得出, 与 TOTAL 精确对账 6347+5465=11812):

- Sources/: 73.86% (6347 行, 漏 1659)
- Tests/: 98.19% (5465 行, 漏 99)

热区 (阶段 1 的直接输入):

- 三文件占 Sources 漏行的 47.8%: AppDelegate.swift 0.00% (282 行), TouchBarController+Agent.swift 8.72%, TouchBarController+AgentCard.swift 10.22% — 都是需要活 NSTouchBar 的 AppKit 接线, 结构性缺口
- 耗时前四 suite 占 25.98s 中的 19.3s: SupportLayerTests 6.0s, ProcessRunnerTests 5.6s, WorkspaceMonitorTests 5.4s, NehirTests 2.3s (真实 sleep/轮询间隔, 非 flaky; 266 个测试里 264 个 < 0.5s)
- RibbonBridge (.m) 未被插桩, 报告中零代表; 分支覆盖列全空 (0/0), 85.12% 不是分支覆盖
- 三个 make 目标各触发一次全量冷编译 (flags 不同致 SwiftPM 缓存 miss), 没有"仅跑测试"的暖构建目标

### 3.3 本机工具链阻塞 (证据链)

- **已解决 (2026-11-08)**: 重装 CLT + 安装 Xcode 26.3, xcode-select -p 指向 /Applications/Xcode.app/Contents/Developer; Xcode 内 _Testing_Foundation.framework/Versions/A/Modules 完整; make lint / make test / make coverage 全绿 (§3.2)。以下为历史证据链:

- 现象: 39 个测试编译单元全部报 `no such module 'Testing'`
- 第一层已证: `Testing.framework` 在 CLT 内完整; 失败因 SwiftPM 传 `-I` 而非 `-F` 指向 `/Library/Developer/CommandLineTools/Library/Developer/Frameworks`
- 加 `-F` 后深入一层: `no such module '_Testing_Foundation'` (31/38 测试文件 `import Foundation` 触发 Testing 的 cross-import overlay)
- 根因: `_Testing_Foundation.framework/Versions/A/Modules` 目录不存在, `Modules` 是悬空符号链接; 而 `Testing.swiftcrossimport/Foundation.swiftoverlay` 声明依赖它 → CLT 26.3.0.0.1.1771626560 安装不完整
- 佐证: 2026-11-07 15:29 的 `.build` 测试产物可构建 (次日失效); 本机无 Xcode (`/Applications` 无, `xcode-select -p` → CommandLineTools); CI 固定 Xcode_16.3, 本地当前不可复现
- 修复选项 (维护者决策, 本计划不代做): (a) 重装 Command Line Tools; (b) 安装 Xcode 并 `xcode-select`; (c) 已否决 `-disable-cross-import-overlays` — 改变 `import Testing` 解析语义, 所测基线无效
- 临时口径: 修复前本地 gate 以应用半区 lint (`swift build -Xswiftc -warnings-as-errors`) 为准; 测试/覆盖率数字待修复后回填本节

## 4. 排序原则

1. 先护栏后手术: 能验证正确性的技能 (testing) 先于会改行为的技能 (concurrency)
2. 先可观测后修改: 能定位问题的技能 (observability) 先于最易出隐蔽 bug 的技能 (concurrency)
3. 零风险层靠后: 风格/文案/无障碍虽安全, 提前做会因语义层未定型而返工

## 5. 阶段计划

| 阶段 | 技能 | 关键动作 | 出口条件 |
|---|---|---|---|
| 0 | (无技能) | AGENTS.md; 基线 (已测全, §3.2); 工具链修复 (已解决, §3.3) | AGENTS.md 存在; 基线表可复现 |
| 1 | swift-testing-pro | `Log.path` 改 per-test 注入以解 `--no-parallel`; 参数化收敛同构用例; 错误路径补 `#expect(throws:)` (ProcessRunner / JSONConfigStore / ToolLocator) | `make test` 绿; 测试数不减; Sources 行覆盖不低于 73.86% |
| 2 | observability | `os.Logger` (子系统 + media/workspace/agent/status 分类) 双写, 保留文件 sink; `.privacy` 标注 workspace 名/前台 app 名/输入源 id; signpost 打 Nehir/AeroSpace 1s 轮询、30s 刷新、osascript 音量热路径 | lint+test 绿; README 日志契约不变 |
| 3 | swift-concurrency-pro | 先审计产出 findings 清单再动手; 收敛约 8 处 `@unchecked Sendable`; EventStream 裸 `Task {}` → 结构化并发 + 真实取消传播; EventStream.swift:306 "never hold NSLock across await" 从注释升级为可执行约束 | 0 个新增 `@unchecked Sendable`; lint+test 绿; Touch Bar 手工冒烟 |
| 4 | swift-api-design-guidelines-skill | RibbonCore public 符号 + RibbonBridge `include/` C 头的命名/参数标签/文档注释 | 纯增量, lint+test 绿 |
| 5 | swift-architecture-skill | 只读 references/selection-guide.md、coordinator.md、concurrency.md 作诊断, 判断三层划分与 TouchBarController+Agent 的 coordinator 角色; 不重构 | 产出一段诊断结论记入本文件, 无代码改动 |
| 6 | swift-format-style | ColorHex/电量/亮度等数值格式化改 `.formatted()`; ClockFormat.swift 有意保留 `DateFormatter` 并加注释说明 (clock.json 允许任意 ICU pattern, `Date.FormatStyle` 不接受原始 ICU 串) | lint+test 绿; 时钟行为逐字节不变 |
| 7 | appkit-accessibility-auditor | 对 BarViews / AgentChipView / AgentCardView 跑 P0-P2 审计; chip 截断名以完整名作 AX label; 审批卡 允许/总是/拒绝 三按钮 AX label | P0 清零; 不新增 TCC 请求 |
| 8 | writing-for-interfaces | 菜单项 (Re-present/Refresh/Show-Hide Control Strip/Agent Chip/IME Color/Clock Format)、chip `?` 占位、审批卡文案、日志错误文案 | 文案评审通过; 可与任意阶段并行 |
| 9 | macos-spm-app-packaging | 按其校验矩阵查 bundle 结构与签名; 公证被 Developer ID 阻塞, 只做结构校验 | 校验矩阵全过或差异清单记入本文件 |

## 6. 统一出口条件

- `make lint` 两步 + `make test` 全绿; Sources 行覆盖不低于 73.86% 基线 (§3.2)
- 注意: CI 固定 Xcode_16.3, 本地是 Xcode 26.3 (磁盘 CLT 又是 16.4), 三者不同版; 本地绿不保证 CI 绿, 合并前以 CI 运行为准

## 7. 明确不用的技能

- swiftui-design-principles: 本仓零 SwiftUI (全仓无 `import SwiftUI`), 其触发条件全是 SwiftUI/WidgetKit
- swift-security-expert: 全部内容是 Keychain/LAContext/CryptoKit/Secure Enclave, 本仓一个都不用

## 8. 已知缺口 (无技能覆盖)

- 真实攻击面是 ToolLocator.swift 的 PATH/Homebrew 前缀查找与 ProcessRunner.swift 的子进程调用; 9 个技能无一覆盖, 依赖人工 review + 阶段 3 的 hotspots 清单兜底
