# OpenCode Agent Chip - 开发计划

日期: 2026-11-06
仓库: ribbon (本仓库)
目标版本: opencode 2.1.x (本机实测 2.1.4)
状态: 设计已定稿; spike A1/A2/A3/A5/A6 已完成 (A4 留待 P3), 可进入 P0 编码

## 1. 目标

Touch Bar 上增加一个 56pt 的 agent chip, 实时显示本机 opencode 后台 service 中全部会话的状态:

- 一触审批: 确认卡上 Allow / Always / Deny (对应 decision once / always / reject), 二次点击提交
- 长按 chip: 有待审批时跳到下一条; 无待审批且忙碌时中断会话
- 跳转: 点卡片身份格, 经 wezterm cli 定位并激活对应 pane
- TUI 全部关闭后仍然可用 (会话由 service 持有, 不随 TUI 消失)

## 2. 非目标

- 不写 opencode 插件 (V1 / V2 都不写)
- 不做语音输入 (用户使用系统 fn/globe 长按听写)
- 不在 bar 上预览命令文本或 diff (身份格负责跳去终端看)
- 不做每会话一 chip, 永远聚合为 1 个
- 不支持 Claude Code / Codex (后续另立项, 通道独立)
- 不新增任何 TCC 权限: 无麦克风, 无 Accessibility, 无 Apple Events
- 不做本地 socket server (纯出站 HTTP)

## 3. 已验证事实

来源: opencode.ai/v2/docs (plugins/server, plugins/cli, migrate-v1, build/client, troubleshooting, api), openapi.json 摘录, 本机文件探测 (2026-11-06).

| 事实 | 值 |
|---|---|
| service 注册文件 | ~/.local/state/opencode/service.json |
| service.json 字段 | {id, version, url, pid, password}, 本机 2.1.4, http://127.0.0.1:49374 |
| 认证 (A1 实测) | HTTP Basic: Authorization: Basic base64("opencode:" + password); /openapi.json 同样需要认证; GET / 返回 Web UI 免认证 |
| 事件流 wire (A6 实测) | GET /api/event, 200, content-type: text/event-stream; 帧为 `data: {json}` 行, 空行分隔; 连接后 ~25ms 内收到 server.connected 事件 (data 为空对象) 与 `: heartbeat` 注释行 |
| types 过滤 (A6 实测) | 2.1.4 服务端忽略 ?types= 参数 (伪事件名也全量推送), 必须客户端本地过滤 |
| 事件信封 (实测) | {id: "evt_...", created: 毫秒 epoch, type, location: {directory}, data, durable: {aggregateID, seq, version}}; 事件 id 前缀 evt_, 会话 id 前缀 ses_; permission.asked 的 data 内联完整请求对象 |
| 需要订阅的事件 | permission.asked, permission.replied, session.created, session.deleted, session.status, session.idle, form.created, form.replied, form.cancelled (tui.session.select 见 A4) |
| 不存在的事件 | permission.updated, message.updated, question.* (V2 无) |
| Permission.Request | {id(前缀 per), sessionID, action, resources[], save[], metadata, source{type,messageID,id}, message}, 必填 id/sessionID/action/resources |
| 回审批 | POST /api/session/{sessionID}/permission/{requestID}/reply, body {"decision":"once"|"always"|"reject"}, 204 (实测方法 POST) |
| 中断 (A2 实测) | POST /api/session/{sessionID}/interrupt |
| 发消息 (备用) | POST /api/session/{sessionID}/prompt, body {"text", "delivery":"steer"|"queue"} |
| 全量对账 (A3 实测) | GET /api/session/active 返回 running 集合; GET /api/session?limit=N 每项含 {id, projectID, agent, model, cost, tokens, outcome, time, title, location:{directory}}; POST /api/session 创建的返回体包一层 {"data":{...}} |
| Form.Info (A5 静态) | {id, sessionID, title, metadata, fields} |
| 会话状态 | Session.Info 无 status 字段; 迁移经 session.status 事件 (data.status.type = idle/busy/retry) |
| V1 插件 | V1 实现在 V2 不运行 (migrate-v1 明示), 故 Openbar 的插件不可抄; 且 Openbar 为 GPL-3.0, ribbon 为 MIT, 代码不可搬 |
| 布局常量 | fullWidth 1004, containerHeight 30, controlSize 24, chipWidth 56, chipMinWidth 40, clusterGap 8, appLabelMaxWidth 160, appLabelTrailingPriority 999; 右 cluster 约 225pt (以 dumpLayout 实测为准) |

## 4. 待验证假设 (spike 已完成, 2026-11-06)

| # | 假设 | 状态 | 结论 / 后续 |
|---|---|---|---|
| A1 | 认证头 | 已验证 | HTTP Basic, 用户名固定 opencode, 密码为 service.json 的 password |
| A2 | interrupt 端点 | 已验证 | POST /api/session/{sessionID}/interrupt |
| A3 | 会话列表字段 | 已验证 | 列表项含 title 与 location.directory; 事件信封亦带 location.directory, 会话短名可零请求获得 |
| A4 | tui.session.select payload | 未验证 | P3 期间实测; 失败则保持 P3 的 wezterm cli 启发式, 不阻塞 P0-P2 |
| A5 | form payload | 静态验证 | Form.Info = {id, sessionID, title, metadata, fields}; 卡片交互仍留 P4 实测 |
| A6 | SSE 格式与 types 过滤 | 已验证 | text/event-stream; ?types= 在 2.1.4 被服务端忽略, 必须客户端本地过滤 |

spike 全部结论已并入第 3 节。

## 5. 架构

```
~/.local/state/opencode/service.json
        |  ServiceLocator (读 + DispatchSource watch, 原子替换安全)
        v
   ServiceEndpoint {url, password, version, pid}
        |
        |  EventStream (SSE: GET /api/event 不带 types, 客户端本地过滤, 重连退避 1s..30s, 读空闲 60s 判死)
        v
AgentSessionStore (纯 reducer, 无 IO)  <--- OpenCodeClient (info / active / list / reply / interrupt)
        |
        v  main queue
AgentChipView (56x24, 独立槽位) + AgentCardView (224x24, BarContainer 内浮层)
        |
        v  按需 (开卡 / 点身份格, 结果缓存 2s)
WeztermLocator (wezterm cli list --format json -> pane 匹配梯子)
        |
        v
wezterm cli activate-tab --tab-id T; activate-pane --pane-id P; NSRunningApplication 激活 WezTerm
```

原则:

- reducer 纯函数, 时间注入 (照 Sources/MediaPollPolicy.swift 的写法), 全部状态机单测不依赖网络。
- 网络层可注入 URLSession (URLProtocol stub), 子进程层可注入 runner (照 Tests/NehirTests.swift 的 stub 范式)。
- service 只 discover 不 ensure: ribbon 永不主动拉起 opencode service。

## 6. UI 规格 (锁定, 不再讨论)

### 6.1 布局 (full 1004pt)

```
0          88                                     ~564   ~612      ~715  ~779      1004
+-----------+--------------------------------------+--------+---------+----+---------+
| << > >>   |  1  2  3  4  5  6  7  8             | iTerm2 |  (空)   |oc!2| 右cluster|
+-----------+--------------------------------------+--------+---------+----+---------+
   media 80    chips 56each/gap4                   label<=160  弹性空隙  agent  right
                                                                   56pt
```

- agent chip 直接 addSubview 到 container (与 levelPop 同级), trailing = rightStack.leadingAnchor - clusterGap, centerY 居中, 宽 56 高 24。
- 不进 leftStack, 不进 workspaces 数组, 不改 rebuildChips (那边 button.tag 当下标用)。
- 槽位伸缩: 桥接健康 -> 宽 56; 失联 -> 宽 0 且 isHidden (约束保留, LevelPop 锚点不失效)。伸缩只随桥接健康度变化 (低频), 不随会话状态变化。
- LevelPopView 的 trailing 锚点从 rightStack.leadingAnchor - 8 改为 agentChip.leadingAnchor - 8, 一条约束的改动。
- 宽度代价: agent 槽占 64pt (56+gap), 等于一个 workspace 的容量; 8 个 workspace 时 label 仍有约 135pt, 9 个约 75pt, 10 个时 label 塌缩 (可接受, 与现状同级别的挤压)。

### 6.2 chip 状态 (只改颜色与文字, 永不改宽度)

| 状态 | 视觉 | 进入条件 |
|---|---|---|
| off | 不存在 (宽 0) | 桥接失联 |
| idle | 空心圆点, controlBackground + 暗描边 | 无 running 会话 |
| busy | 青绿描边, 底边 2pt 进度毛边, 文字为 busy 计数 | >=1 会话 busy/retry |
| awaiting | 琥珀填充 + "!" + 等待计数, layer.opacity 1.2s 慢呼吸 | >=1 待审批或待填表单 |
| done | 绿色, 3s 后回落 idle | 全部会话从 busy 变 idle |

优先级 awaiting > busy > done > idle。呼吸与毛边用 layer 属性动画 (opacity / frame), 不触发布局, 范式照 LevelPopView 的 timer 写法。

### 6.3 确认卡 (点 chip 后)

```
+---------+--------+--------+--------+
| api 1/3 |  允许  |  总是  |  拒绝  |
+---------+--------+--------+--------+
    56        56       56       56      共 224x24, 右缘对齐 chip 右缘, 向左盖住 label 与至多 3 个 chip
```

- 第 1 格: basename(session.directory) 截断 + 队列位置 N/M。点它 = 跳转, 不决策。
- 后 3 格: once / always / reject。点格即提交 (开卡是第一次确认, 点格是第二次)。
- 卡在打开瞬间锁定 (sessionID, requestID); 若收到 permission.replied 且 id 匹配, 立即收卡, 不再发请求。
- 决策提交成功后: 卡关闭, chip 刷新, 若还有下一条需重新点 chip 打开 (不自动连开)。
- 5s 无操作自动收回 (时长进 Theme.Timing)。
- 排序: 待审批队列按事件信封 created 时间升序 (最老的先)。
- 卡是画在 BarContainer 内的普通 NSView 浮层 (Touch Bar 远端渲染, NSPopover 不可用), hitTest 只在卡内生效。

### 6.4 手势

| 手势 | 有待审批时 | 无待审批时 |
|---|---|---|
| 点 chip | 开卡 | 跳转到最活跃会话的 pane |
| 长按 chip (约 500ms, 阈值进 Theme.Timing) | 跳过当前条目看下一条, 不决策 | 中断当前展示的 busy 会话 (依赖 A2) |
| 点卡第 1 格 | 跳转, 卡收回 | - |

### 6.5 strip 模式 (680pt)

chip 锚点是 rightStack.leadingAnchor, media/label/系统键在 strip 下本就隐藏, chip 自动落在电池组左侧, 无需额外代码。

## 7. 阶段计划

每阶段独立可验收, 提交前过 make lint 与 make test。

### P0 连接层 (无 UI)

文件:

- Sources/OpenCode/ServiceEndpoint.swift
- Sources/OpenCode/ServiceLocator.swift
- Sources/OpenCode/OpenCodeClient.swift
- Sources/OpenCode/EventStream.swift
- Sources/OpenCode/AgentSessionStore.swift
- Sources/OpenCode/AgentEvent.swift (SSE 帧的解码模型)
- Tests/OpenCodeEventStreamTests.swift
- Tests/OpenCodeAgentStoreTests.swift
- Tests/OpenCodeServiceLocatorTests.swift

接口 (签名即契约):

```swift
struct ServiceEndpoint: Equatable {
    let url: URL          // http://127.0.0.1:<port>
    let password: String  // 只读不改, 不落日志
    let version: String
    let pid: Int32
}

final class ServiceLocator {
    var onEndpoint: ((ServiceEndpoint?) -> Void)?
    func start()   // DispatchSourceFileSystemObject: 文件 .write/.delete/.rename + 父目录源 (应对原子替换)
    func stop()
}

enum AgentDecision: String { case once, always, reject }

struct OpenCodeClient {
    let endpoint: ServiceEndpoint
    let session: URLSession          // 注入, 测试用 URLProtocol stub
    func info() async throws -> [String: Any]          // GET /api/info, 兼作健康探测
    func activeSessionIDs() async throws -> Set<String> // GET /api/session/active, 取 type=="running" 的键
    func replyPermission(sessionID: String, requestID: String, decision: AgentDecision) async throws
}

struct AgentEvent: Equatable {
    let type: String        // "permission.asked" 等
    let created: Date       // 信封 created, 毫秒 epoch
    let sessionID: String?
    let permissionID: String?
    let statusType: String? // session.status 专用
    // 保留原始 data 以便 reducer 取 action/resources/directory
}

final class EventStream {
    var onEvent: ((AgentEvent) -> Void)?
    var onResync: (() -> Void)?     // (重)订阅成功或收到 server.connected 时触发, 上层做全量对账
    func update(endpoint: ServiceEndpoint)
    func stop()
    // 行为: URLSession.bytes 按行读; 订阅 URL 不带 types (2.1.4 服务端忽略该参数);
    //       JSON 解码前做字节级预过滤: 行内不含任一订阅类型的 "type":"..." 子串则整行丢弃
    //       (事件流含 session.text.delta 高频帧, 不预过滤会有可观解码开销);
    //       `: heartbeat` 注释行与任何收到的行都重置空闲计时; server.connected 触发 onResync;
    //       重连退避 1s 起指数至 30s 封顶; 60s 无任何行判死重连
}

struct PendingRequest: Equatable {
    let id: String
    let kind: Kind              // .permission | .form
    let action: String
    let resources: [String]
    let requestedAt: Date
}

struct AgentSession: Equatable {
    let id: String
    var shortName: String       // basename(directory), 未知时 "?"
    var isBusy: Bool
    var pending: [PendingRequest]
    var lastSeen: Date
}

enum AgentChipState: Equatable {
    case off, idle, busy(count: Int), awaiting(count: Int), done
}

struct AgentSessionStore {
    mutating func apply(_ event: AgentEvent, now: Date)
    mutating func replaceAll(sessions: [AgentSession], now: Date)   // 对账路径
    var chip: AgentChipState { get }
    var triageHead: (session: AgentSession, request: PendingRequest)? { get }  // 最老优先
    var triageCount: Int { get }
}
```

要点:

- reducer 规则: permission.asked 入队; permission.replied 按 requestID 出队; session.created/deleted 增删; session.status/idle 置忙闲; 短名在 created 与对账时补。 session.status(idle) 与 session.idle 均参与 done 计时; replaceAll(sessions:now:pendingIsAuthoritative:) 在非权威模式下保留存活会话的既有 pending。
- 对账: onResync -> activeSessionIDs + 会话列表 -> replaceAll。冷启动与每次重连都走同一条路。
- 认证头由 endpoint 派生: Authorization: Basic base64("opencode:" + password), 不落日志不落盘。
- AgentEvent 带 envelopeDirectory (来自信封 location.directory), 会话短名无需额外请求。
- 健康度: chip 层在 P1 定义, P0 只保证 onEndpoint/onEvent/onResync 三个回调正确。

测试:

- EventStream: 帧解析 (多行 data / 半行 / 注释 / server.connected), 重连退避序列, 读超时触发。
- Store: 固定事件序列 -> 状态断言 (含: replied 竞态出队, 多会话聚合计数, triage 排序)。
- ServiceLocator: 临时目录写 service.json (TestTemp 范式), 覆盖创建/替换/删除。

验证: make lint && make test

### P1 chip 只读态

文件:

- Sources/AgentChipView.swift (56x24, 复用 ChipTapButton 的按压转发)
- Sources/TouchBarController+Agent.swift (装配: locator/stream/store -> main queue -> chip)
- Theme.swift: 新增 agentWaitFill / agentWaitBorder / agentBusyBorder / agentDoneFill 色值 token 与 agentCardTimeout / agentPulsePeriod / longPressThreshold 计时 token (色值从现有调色板取, 不新造色系)
- TouchBarController+Layout.swift: 挂 agent chip (约束见 6.1), 改 levelPop 锚点
- Tests/AgentChipStateTests.swift (状态 -> 视觉参数的纯映射)

要点:

- 桥接健康判定: 60s 内有过 /api/info 成功或任一事件帧 -> 健康; 否则 chip 宽 0 收起。
- 不改 refreshNow 的 workspaces 早退逻辑, 只在其后追加 updateAgentChip()。
- busy 的底边毛边与 awaiting 的呼吸用 timer 驱动 layer 属性, 频率 <= 10Hz。

验证: make lint && make test; 手工: 起一个 opencode 会话跑任务, chip 出现 busy; 关 service, chip 收起且 label 宽度恢复。

### P2 审批卡

文件:

- Sources/AgentCardView.swift (224x24 四格)
- Sources/TouchBarController+AgentCard.swift (开卡/锁定/提交/收卡状态机)
- Tests/AgentCardStateMachineTests.swift (纯状态机: idle -> open(sessionID, requestID) -> decide -> closed; replied 竞态 -> closed; 超时 -> closed)

要点:

- 卡状态机为纯类型, UI 只渲染; 状态机持有锁定的 (sessionID, requestID), decide 时用锁定值发请求, 绝不现场查询队列。
- 提交失败 (网络错): 卡保持打开并给出错误色闪烁一次, 不自动重试。
- form 类待办在本阶段只计入 awaiting 计数与 ? 视觉, 不开卡 (A5 通过后 P4 补)。

验证: make lint && make test; 手工: 审批往返, 终端抢先答复后卡自动关, 连续两条待审批的 1/2 -> 2/2 流转。

### P3 跳转

文件:

- Sources/WeztermLocator.swift
- Tests/WeztermLocatorTests.swift (stub runner 注入, JSON fixture)

要点:

- CLI 解析梯子: wezterm -> /opt/homebrew/bin/wezterm -> /Applications/WezTerm.app/Contents/MacOS/cli。
- pane 匹配梯子: cmdline 含 "opencode" 且 cwd == session.directory -> is_active 优先 -> pane_id 最小; 失败退到仅 cwd 匹配; 再失败只激活 WezTerm 应用。
- 激活顺序: activate-tab -> activate-pane -> NSRunningApplication.activate。
- cli list 按需调用, 结果缓存 2s。

验证: make lint && make test; 手工: 双 pane 双仓库, 点身份格各归其位; 同仓库双 pane 时落 active 侧。

### P4 收尾

- 中断手势 (依赖 A2): 无待审批且 busy 时长按 -> POST interrupt。
- form 卡 (依赖 A5)。
- tui.session.select 精确 pane 映射 (依赖 A4): 命中则替代 P3 的 cmdline 启发式, 启发式降为兜底。
- 配置: JSONConfigStore 第三个实例 agent.json {enabled: true}, 关闭时槽位永久收起。
- README 增补: 功能段 + 已知限制 (版本耦合 2.1.x, service.json 格式无稳定性承诺)。

## 8. 测试策略

- 一切状态迁移走纯类型 + 注入 (时间/URLSession/runner), 不 mock AppKit, 不做 UI 测试 (仓库现状亦无)。
- SSE 与 HTTP 用 URLProtocol stub 回放固定帧; 子进程用 runner 闭包 stub。
- 手工验收场景固化在第 9 节, 每阶段完成过一遍对应行。

## 9. 验收场景 (手工)

| # | 场景 | 期望 |
|---|---|---|
| 1 | 单会话触发一次权限请求 | chip 琥珀 !1, 开卡, 允许, TUI 继续执行 |
| 2 | 双 pane 双会话先后待审批 | !2, 卡显示 1/2, 决策后卡关, 重点开显示 2/2 |
| 3 | 卡开着时在终端抢先答复 | 卡立即收起, 后续点击无效 |
| 4 | 关闭全部 TUI, service 存活, 会话跑完触发权限 | chip 仍琥珀, 审批仍成功 |
| 5 | opencode service restart | url/password 变化后 30s 内自动恢复, 无重复 chip, 无僵尸待审批 |
| 6 | service stop / 文件删除 | chip 收起, bar 布局与今日一致 |
| 7 | Control Strip (strip) 模式 | chip 位于电池组左侧, 功能不变 |
| 8 | 点身份格 | 落到对应 pane; 同仓库双 pane 落 active 侧; 无匹配只前置 WezTerm |
| 9 | 长按 | 有待审批: 跳下一条; busy 无待审批: 中断 (若 A2 成立) |
| 10 | 桥接全程健康但无会话 | chip 为 idle 空心点, label 正常, 无布局抖动 |

## 10. 风险与对策

| 风险 | 对策 |
|---|---|
| SSE 心跳为 `: heartbeat` 注释行, 连接时必发但周期未证实 | 任意行重置 60s 空闲计时, 超时重连 + 全量对账 |
| 事件流含 session.text.delta 等高频帧 | 字节级预过滤, 未命中订阅类型不解码 |
| service 重启换 url/password | ServiceLocator watch 父目录应对原子替换, 端点变更即重建 EventStream |
| openapi 字段随版本漂移 | 解码容忍缺字段 (短名退 "?", metadata 只取已知键); 启动时 /api/info 的 version 写一条日志 |
| service.json 含明文密码 | 只读, 不复制, 不进日志与诊断输出; dumpLayout 类日志评审时确认 |
| 多会话同 cwd 导致跳转歧义 | 可接受: 最坏跳到同仓库另一 pane, 决策与跳转已解耦 |
| Touch Bar 误触 | 开卡 + 点格两次确认; 卡锁定 requestID; 5s 超时 |
| bar 远端渲染限制 | 卡与呼吸动画全部为 container 内 layer 属性, 无 NSPopover 无 window 级动画 |
