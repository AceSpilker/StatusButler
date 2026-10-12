# 状态管家 · StatusButler

> 大小状态，管家打理 —— Every signal, at your service.

原生 macOS 状态聚合工具箱：把 Wi-Fi、电池、音量等系统信号收进**一个**自绘图标（菜单栏 / Dock），左键弹层六分区下钻操作，右键菜单直达设置；随附 `butler` 命令行与 `butler://` URL Scheme，终端与脚本同享全部查询与控制能力。

**当前状态：0.1.0 已可构建运行。** 全部逻辑收在 `StatusButlerCore` 一个模块，54 个测试套件 455 个用例全绿；纯 SPM 构建，不依赖 Xcode IDE。首版发布说明见 [release-notes/0.1.0/](release-notes/0.1.0/zh-Hans.md)（[English](release-notes/0.1.0/en.md)）。

## 构建

依赖：macOS 13+、Swift 6 工具链（推荐 [swiftly](https://www.swift.org/install/swiftly/) 安装）。

```bash
export PATH="$HOME/.swiftly/bin:$PATH"

# 包根在仓库的 statusbutler/ 子目录
cd statusbutler
swift build                # debug
swift build -c release     # release
```

三个 target：`StatusButlerCore`（全部逻辑，含监控/存储/映射/UI 与测试对象）、`StatusButler`（App 薄壳）、`butler`（CLI 薄壳）。

## 运行

```bash
cd statusbutler
bash scripts/build-app.sh release no-open   # 组装 ad-hoc 签名的 dist/状态管家.app
open "dist/状态管家.app"                     # 菜单栏出现三合一图标
```

首次打开因 ad-hoc 签名会被 Gatekeeper 拦截：Finder 右键 App →「打开」，或到「系统设置 → 隐私与安全性」放行（详见发布说明的已知限制）。

## CLI

`butler` 随构建产出（`statusbutler/.build/debug/butler` 或 `.build/release/butler`），可复制进 PATH。查询类直读主 App 的共享快照文件；动作类经 `butler://` 转发给主 App 执行。

```bash
butler status              # 人类可读快照（需主 App 在运行）
butler status --json       # 机器可读 JSON；主 App 未运行时退出码 2 + {"error":"app-not-running"}
butler volume 50           # 设定音量为 50
butler volume up           # 音量步进 / mute 静音
butler panel thermal       # 打开弹层直达温度分区（battery / network 同理）
butler fan 4000            # 风扇恒定 4000 RPM（fan auto 恢复）
butler slot cycle          # 底部槽位轮换
butler screen off          # 熄屏不睡眠
butler --help              # 全部白名单动词与退出码表（0 成功/1 未知命令/2 快照不可用/3 被拒）
```

完整动词面与参数校验由 `ButlerCommand.allowed` 单一事实源约束（A9·AU-01），帮助文本自动生成、永不漂移。

## 测试

```bash
cd statusbutler
swift test                      # 全量（54 套件 455 用例）
bash scripts/test.sh <过滤词>    # 单套件
bash scripts/full-regression.sh # T-057 全量回归：双配置构建→测试两遍（抓偶发）→组包→
                                # dist 断言（Info.plist/可执行/ad-hoc 签名）→butler CLI 冒烟，
                                # 每步 PASS/FAIL 摘总，任一 FAIL 退出码 1
```

CI（`.github/workflows/ci.yml`）在每次 push 上重复 build / test / 组包冒烟三步；发布链草稿见 `release-draft.yml`（v* tag 触发）。

## 架构（一图流 · 文字版）

四层单向依赖，禁止反向 import；组合根手工装配：

```
Monitoring 层    协议化监控器（-ing 后缀）：BatteryMonitor / WiFiMonitor / VolumeMonitor /
      │          BluetoothMonitor / ThermalMonitor(SMC) / CpuMonitor / MemoryMonitor /
      │          NetRateMonitor / NetworkConnectionMonitor(NWPath) …事件驱动 + 兜底轮询
      ▼
Store 层         SystemStatusStore：单一 StatusSnapshot（@MainActor，能画进图标的都在这）
      │                            旁路属性只服务弹层，不进快照
      ▼
Presentation 层  纯函数映射：IconSceneState（三合一场景）/ SlotComposer（底部槽位）/
      │          PanelModels（六分区）/ Theme（6 预设）——无状态、可全量单测
      ▼
UI 层            StatusBarController（菜单栏，左键弹层/右键菜单）· Dock 渲染 · NSPopover
                 分区面板 · 设置中心（四分区实时预览）· 首次引导

旁路（不进四层主链）：
  WidgetSnapshotWriter ──原子写──▶ ~/Library/Application Support/StatusButler/WidgetData/
                                    widget-snapshot.json ──▶ butler CLI / 未来小组件扩展
  ButlerCommand ──▶ butler:// URL Scheme（主 App 执行）/ CLIEngine（CLI 进程执行）
  PluginRunner（sandbox-exec 沙盒）· HistoryStore（SQLite）· TelemetryEngine（默认关）
```

工程纪律：Swift 6 严格并发；采样"有人看才运行"；订阅 `removeDuplicates()`；四条产品红线由 `ForbiddenPatternGuardTests` 钉死（详见 [AGENTS.md](AGENTS.md)）。

## 文档导航

浏览器打开 `docs/index.html`（默认首页为功能总目录）。

| 编号 | 内容 |
|---|---|
| [A0](docs/a0-catalog.html) | **功能总目录**（十大类型索引） |
| [A1](docs/a1-brand.html) | 品牌与命名 |
| [A2](docs/a2-features.html) | 复刻功能规格（S1~S12 全量） |
| [A3](docs/a3-extensions.html) | 扩展速览（E1~E12） |
| [A4](docs/a4-register.html) | 需求登记表 |
| [A5](docs/a5-thermal.html) / [A6](docs/a6-widgets.html) / [A7](docs/a7-perf.html) | 温度风扇 / 桌面小组件 / 性能监控 |
| [A8](docs/a8-slots-info.html) / [A9](docs/a9-control-personalize.html) | 信号槽与信息 / 控制与个性化 |
| [A10](docs/a10-landscape.html) | 竞品版图 |
| [A11](docs/a11-power-display-audio.html) / [A12](docs/a12-productivity-platform.html) | 电池显示音频 / 效率与平台 |
| [A13](docs/a13-usage.html) | **用户使用指南**（菜单栏/弹层/设置/槽位/CLI/FAQ） |
| [B1](docs/b1-tech.html) | 技术与架构方案 |
| [C1](docs/c1-plan.html) | 开发规划与追踪（排期看板） |
| [01~07](docs/01-overview.html) | 参考项目 Status Trio 源码分析（附录） |

## 参考项目

设计对标并深度分析了开源项目 [lingyired/status-trio](https://github.com/lingyired/status-trio)（Apache-2.0），分析文档见 `docs/01~07`。参考源码克隆在仓库外的 `../reference/status-trio/` 本地对照（不入库）。

## 贡献

- 分支纪律：`main` 常绿，跨子系统改动走 `feat/` `fix/` `docs/` 短生命周期分支；Conventional Commits + 中文描述 + 任务号尾注（如 `(T-057)`）。
- 提交前验证门必须全绿：`cd statusbutler && swift build && swift test`；发布/大改动前跑 `scripts/full-regression.sh`。
- 工程规范、架构铁律与产品红线以 [AGENTS.md](AGENTS.md) 为准，违反即打回；功能变更先改 `docs/` 规格（单一事实源），需求变更先登记 `docs/a4-register.html`。

## 许可

待定。首个可运行版本 0.1.0 已产出，许可定案列入近期事项；定案前代码默认保留所有权利（All Rights Reserved），文档与发布说明可按署名引用。
