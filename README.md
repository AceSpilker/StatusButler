# 状态管家 · StatusButler

> 大小状态，管家打理 —— Every signal, at your service.

原生 macOS 状态聚合工具箱：把 Wi-Fi、电池、音量等系统信号收进**一个**自绘图标（菜单栏 / Dock / 桌面小组件），弹层可下钻操作；并以"管家"人设持续扩展温控、性能监控、自动化等能力。

**当前阶段：设计完备，进入编码准备。** 全套设计文档见 [`docs/`](docs/index.html)（浏览器打开 `docs/index.html`，默认首页为功能总目录）。

## 功能全景（十大类型 · 12 复刻域 + 25 扩展）

| 类型 | 代表能力 |
|---|---|
| 状态图标与展示 | 三合一自绘图标 · 信号槽系统 · 桌面小组件（WidgetKit） |
| 个性化与设置 | 主题系统 · 昼夜自动主题 · iCloud 同步 |
| 硬件监控 | 温度/风扇（对标 TG Pro）· 网速/CPU/内存/GPU · 磁盘 · iDevice 电量 |
| 电池与电源 | 电池详情 · 电池养护中心 · 一键熄屏不睡眠 |
| 网络与连接 | Wi-Fi/链路详情 · 网络质量测试 |
| 音频与显示 | 设备切换 · DDC 外接屏音量/亮度 · 每 App 独立音量 |
| 控制与自动化 | 动作中心 · butler:// URL Scheme · CLI · 全局热键 · 菜单栏整理 |
| 信息与效率 | 天气 · 日程倒数 · 会议助手 · 脚本插件槽（沙盒） |
| 健康与维护 | 状态历史 · 系统健康体检 · 更新扫描 |
| 平台基础 | 引导 · 本地化 · 无障碍 · 发布流水线 |

完整功能点索引（可点击直达设计章节）：[docs/a0-catalog.html](docs/a0-catalog.html)

## 技术路线（摘要）

- **Swift 6 严格并发** · AppKit 壳 + SwiftUI 内容 + CoreGraphics 自绘图标 · 纯 SPM（构建/测试不依赖 Xcode IDE）
- **四层架构**：Monitoring（协议化监控器）→ Store（单快照）→ Presentation（纯映射）→ UI；组合根手工装配
- **能效纪律**：事件驱动 + 兜底轮询；采样器"有人看才运行"；界面不可见零开销
- **部署目标 macOS 13+**，Universal；Sparkle 2 自动更新；GitHub Releases + DMG 分发（Ad-hoc 签名起步，免账号）
- **四条产品红线**：不碰 Wi-Fi 密码 / 充电域 SMC 不写（风扇域为唯一例外，键白名单+自愈）/ 隐私权限最小化 / 私有 API 白名单（DDC、菜单栏整理、风扇）

详见 [docs/b1-tech.html](docs/b1-tech.html)（技术与架构方案）。

## 文档导航

| 编号 | 内容 |
|---|---|
| [A0](docs/a0-catalog.html) | **功能总目录**（十大类型索引） |
| [A1](docs/a1-brand.html) | 品牌与命名 |
| [A2](docs/a2-features.html) | 复刻功能规格（S1~S12 全量） |
| [A3](docs/a3-extensions.html) | 扩展速览（E1~E12） |
| [A5](docs/a5-thermal.html) / [A6](docs/a6-widgets.html) / [A7](docs/a7-perf.html) | 温度风扇 / 桌面小组件 / 性能监控 |
| [A8](docs/a8-slots-info.html) / [A9](docs/a9-control-personalize.html) | 信号槽与信息 / 控制与个性化 |
| [A10](docs/a10-landscape.html) | 竞品版图（候选已全部转正） |
| [A11](docs/a11-power-display-audio.html) / [A12](docs/a12-productivity-platform.html) | 电池显示音频 / 效率与平台 |
| [A4](docs/a4-register.html) | 需求登记表（R-1~R-6 已采纳） |
| [B1](docs/b1-tech.html) | 技术与架构方案 |
| [01~07](docs/01-overview.html) | 参考项目 Status Trio 源码分析（附录） |

## 参考项目

设计对标并深度分析了开源项目 [lingyired/status-trio](https://github.com/lingyired/status-trio)（Apache-2.0），分析文档见 `docs/01~07`。参考源码克隆在仓库外的 `../reference/status-trio/` 本地对照（不入库）。

## 许可证

待定（计划随首个可运行版本一同确定）。
