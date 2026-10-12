# 状态管家 StatusButler 0.1.0

> 发布日期：2026-10-12 · macOS 13+（Ventura 及更高）· 首个公开版本（build 1）

## 这是什么

**状态管家（StatusButler）**是一款原生 macOS 菜单栏状态聚合工具：把电池、Wi-Fi、音量等多个系统信号收进**一个**自绘图标，点开即得六分区弹层（电池 / 网络 / 音量 / 蓝牙 / 温度 / 性能），下钻可看详情、可直接操作。附带的 `butler` 命令行让你在终端和脚本里也能查询与控制。

- **三合一图标**：菜单栏一格看电池、网络、音量；充电时有呼吸动画；底部槽位可轮换显示温度、风扇、网速等附加信号
- **弹层六分区**：左键图标展开；分区数据按需加载，不看不停采样（能效优先）
- **设置中心**：图标外观实时预览、状态面板行为、深浅色主题（6 套预设）、中英双语
- **动作中心与自动化**：`butler://` URL Scheme + `butler` CLI，音量、面板、风扇、熄屏等均可脚本化
- **安全红线**：不碰 Wi-Fi 密码与钥匙串；充电相关硬件绝不写入（风扇为唯一白名单例外）；隐私权限最小化

## 安装

### 方式一：DMG（推荐）

1. 从 GitHub Releases 下载 `StatusButler-0.1.0.dmg` 与同名 `.sha256` 文件
2. 校验完整性（可选但建议）：
   ```bash
   shasum -a 256 --check StatusButler-0.1.0.dmg.sha256
   ```
3. 打开 DMG，把「状态管家」拖入「应用程序」文件夹
4. **首次打开**：因为 0.1.0 使用 ad-hoc 签名（见下方已知限制），macOS 会拦截。请在 Finder 中**右键点 App → 打开 → 再点「打开」**；或在「系统设置 → 隐私与安全性」底部点「仍要打开」

### 方式二：从源码构建

```bash
git clone <本仓库>
cd mactool/statusbutler
bash scripts/build-app.sh release no-open   # 产物在 dist/状态管家.app
```

命令行工具在同一次构建中产出：`statusbutler/.build/release/butler`，可自行复制到 `/usr/local/bin` 或 `~/.local/bin`。

### CLI 快速上手

```bash
butler status              # 人类可读快照（需主 App 在运行）
butler status --json       # 机器可读 JSON（脚本友好）
butler volume 50           # 设定音量为 50
butler panel thermal       # 直达温度分区面板
butler --help              # 全部动词与退出码表
```

完整功能说明见仓库 `docs/a13-usage.html`（用户使用指南）。

## 已知限制

- **ad-hoc 签名与首开放行**：0.1.0 未购买 Developer ID 证书，App 为 ad-hoc 签名且未经公证。首次打开需右键「打开」或到「系统设置 → 隐私与安全性」放行；升级到新版本时可能需再次放行。
- **沙盒网络限制**：脚本插件槽以 `sandbox-exec` 禁网隔离，但 macOS 26（darwin26）上 `network*` 拒绝规则已失效、部分机型缺少该工具——此时插件降级为"无沙盒标记 + 严格超时"模式运行（T-035b 登记的替代方案）。天气模块仅访问 Open-Meteo 白名单域，经 URL / DNS / 重定向三道闸校验。
- **桌面小组件（即将）**：数据层已就绪，WidgetKit 扩展尚未随 0.1.0 发布，小组件暂不可用。
- **无自动更新**：Sparkle 更新链未接入，新版本请手动关注 Releases 页。
- **开机自启动**：设置页该项为占位，登录项注册待后续版本接入。
- **功能面**：iDevice 设备电量、每 App 独立音量未包含在本版。
- **架构**：DMG 仅含 arm64（Apple Silicon）；Intel Mac 请从源码自行构建。

## 反馈

问题与建议请提 GitHub Issue；开发规划见 `docs/c1-plan.html`。
