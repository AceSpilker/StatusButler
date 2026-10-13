import AppIntents

// MARK: - App Shortcuts 注册（A9 · AU-02，A14-ε）
/// 快捷指令 App 里零配置可用的入口（App Shortcuts）。短语中文（本产品全中文域）；
/// 每条带一条 "\(.applicationName)" 插值变体——App Shortcut 短语规范要求至少一条
/// 含 App 名插值，纯中文短句作为第二条提升口语命中。
/// 上限意识：App Shortcuts 每 App 至多 10 条，此处只放最高频四条；
/// 其余动词用户可在快捷指令 App 里基于这些 Intent 自行组合（AU-01 白名单同源）。
public struct ButlerShortcuts: AppShortcutsProvider {
    public static var shortcutTileColor: ShortcutTileColor { .teal }

    @AppShortcutsBuilder
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: VolumeUpIntent(),
            phrases: ["音量调高", "\(.applicationName)音量调高"],
            shortTitle: "音量调高",
            systemImageName: "speaker.wave.2.fill"
        )
        AppShortcut(
            intent: VolumeMuteIntent(),
            phrases: ["静音", "\(.applicationName)静音"],
            shortTitle: "静音",
            systemImageName: "speaker.slash.fill"
        )
        AppShortcut(
            intent: ShowPanelIntent(),
            phrases: ["打开状态面板", "\(.applicationName)打开面板"],
            shortTitle: "打开面板",
            systemImageName: "square.grid.2x2"
        )
        AppShortcut(
            intent: VolumeSetIntent(),
            phrases: ["设置音量档位", "\(.applicationName)设置音量"],
            shortTitle: "设置音量",
            systemImageName: "speaker.wave.1.fill"
        )
    }
}
