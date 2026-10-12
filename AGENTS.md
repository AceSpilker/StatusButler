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
