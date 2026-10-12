# StatusButler 状态管家 · Agent 规则

> 本项目（mactool 仓库）的工程纪律。人机协作共同遵守，违反即打回。

## 任务与文档

- 单一事实源：功能以 `docs/` 规格为准（A2 复刻基线 / A5~A12 扩展深设 / A0 总索引）——**改功能先改规格，再写代码**。
- 任务追踪：`docs/c1-plan.html`（C1）是唯一排期看板；每个任务完成的同一提交里更新其状态徽标与测试报告行；提交信息末行标注任务号，例如 `(T-002)`。
- 需求变更一律先登记 `docs/a4-register.html`（R 编号），采纳后并入对应设计页。

## 验证门（提交前必须全绿）

```bash
export PATH="$HOME/.swiftly/bin:$PATH"
cd statusbutler && swift build && swift test
```

- 触碰图标渲染/几何/映射的改动：额外跑全量测试并人工核对菜单栏与 Dock 两端一致。
- CI（`.github/workflows/ci.yml`）在每次 push 上重复同样三步：build / test / 组包冒烟。

## Swift 6 规范

- 严格并发：Store/控制器 `@MainActor`；`nonisolated(unsafe)` 仅限 teardown 场景并注释论证；不把 actor 隔离方法直接当函数值传。
- 监控器全部协议化（`-ing` 后缀），测试注入假实现；映射层保持纯函数。
- 能效铁律：采样"有人看才运行"；定时器带宽容忍（间隔/5）；订阅 `removeDuplicates()`。
- 注释只写"为什么"（约束/边界/坑），不写"是什么"。

## 架构铁律

1. 依赖单向：Monitoring → Store → Presentation → UI，禁止反向 import。
2. 菜单栏与 Dock 图标改动必须同一提交两端同步（设置/订阅/缓存/渲染/测试五处）。
3. 能画进图标的进 `StatusSnapshot`，只服务面板的走旁路属性。
4. 四条产品红线（A2·S12）：不碰 Wi-Fi 密码/钥匙串；充电域 SMC 永不写入（风扇域为唯一白名单例外）；隐私权限最小化；私有 API 仅限白名单（DDC、菜单栏整理、风扇域）——由 `ForbiddenPatternGuardTests` 钉死。

## 分支与提交

- `main` 常绿 + 短生命周期分支（`feat/` `fix/` `docs/`）；小改动直进 main，跨子系统改动走分支。
- Conventional Commits + 中文描述 + 任务号尾注；每任务一提交，完成即 push。

## 实战经验（踩坑存档，出处任务号）

- **大小写不敏感 FS 的 target 名冲突**：可执行 target `statusbutler` 在大小写不敏感文件系统（macOS/CI）上与 App 产物 `StatusButler` 同路径相撞，链接期才炸且本地难复现。多可执行 target 命名先过一遍"去掉大小写后是否同形"。出处：(T-052，终集成修订)。
- **c1-plan 用 union 合并策略**：多 agent 并行分支都会登记看板行，默认合并必冲突；`.gitattributes` 里 `docs/c1-plan.html merge=union` 让双方行全保留。副作用是无人兜底删行，集成时必须人工复核一遍。出处：(T-023b，第三轮并行集成)。
- **CI 无 WindowServer 的测试守卫**：GitHub runner 没有窗口服务，弹窗/引导类用例直接崩。环境探测守卫（有 WindowServer 才跑，本地 GUI 照常验证）比删用例好——守卫条件写成能力探测而非平台白名单，未来 runner 补上能力即自动恢复。出处：(T-032，修订)。
- **darwin26 上 sandbox-exec 的 network\* 规则失效**：macOS 26 的 `network*` deny 规则不生效、部分机型连工具都缺。测试改环境自适应（能测则测、缺能力则跳过并标注），产品侧降级模式（无沙盒标记 + 严格超时）并登记 T-035b 替代方案——不要对同一行为在不同 macOS 版本上假设一致。出处：(T-035，修订)。
- **@Published 订阅即回放与 dropFirst/静置排空**：`$prop.sink` 订阅瞬间会回放当前值，慢机上 VM 初始赋值又可能晚于订阅到达——`dropFirst()` 排回放之外，还要订阅后静置一小段（如 200ms）再清零计数，否则时序类断言在 CI 慢机上偶发多计一次。这类负载敏感偶发正是回归脚本跑两遍 swift test 的原因。出处：(T-030，防抖用例)。
- **macOS 自带 bash 3.2 会把 `$var` 后的中文粘进变量名**：`"$app（…）"` 中全角括号等 ≥0x80 字节被 bash 3.2 当作变量名字符，`set -u` 下即 unbound variable 直接退出，且报错变量名是乱码极难定位。shell 脚本里变量与中文之间一律写 `${var}` 显式定界。出处：(T-057，full-regression.sh)。

