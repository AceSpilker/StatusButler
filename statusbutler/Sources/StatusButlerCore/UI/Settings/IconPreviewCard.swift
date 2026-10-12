import SwiftUI

// T-031 / A2·S9：外观类设置的实时预览卡。
// 直接订阅 SettingsStore（@Published 变更即重算 body），注入一份固定的假快照——
// 预览的变量只有"设置本身"，系统状态掺进来会污染归因（改图标大小 vs 网络抖动分不清）。

public struct IconPreviewCard: View {
    @ObservedObject private var settings: SettingsStore
    private let snapshot: StatusSnapshot
    @Environment(\.colorScheme) private var colorScheme

    /// 预览用固定快照：充电中 + 3 格信号 + 60% 音量，覆盖电池/信号/音量/呼吸环全部绘制分支
    public static let sampleSnapshot = StatusSnapshot(
        battery: .battery(level: 78, charging: true),
        link: .wifi(ssid: "Preview", signalBars: 3),
        volume: VolumeState(level: 60, isMuted: false)
    )

    /// 时钟槽位若用真实 Date，每次 body 求值文本都可能变化导致无意义重绘；
    /// 固定一个历史时刻即可，显示"几点"不重要，恒定才重要
    private static let fixedNow = Date(timeIntervalSince1970: 45_240)

    public init(settings: SettingsStore, snapshot: StatusSnapshot = IconPreviewCard.sampleSnapshot) {
        self.settings = settings
        self.snapshot = snapshot
    }

    public var body: some View {
        VStack(spacing: 10) {
            previewImage
                .frame(height: 64)
            Text(summaryLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary.opacity(0.35))
        )
        .accessibilityLabel("状态图标实时预览：\(summaryLine)")
    }

    private var previewImage: some View {
        let dark = colorScheme == .dark
        let scene = IconSceneState.from(snapshot)
        let footer = SlotComposer(selectedID: settings.footerSlotID)
            .footer(snapshot: snapshot, now: Self.fixedNow)
        // 呼吸相位取静态 0.5：预览要展示"开了是什么样"，不追真实动画相位
        let glow: Double? = {
            guard settings.showsChargingEffect, case .battery(_, let charging) = snapshot.battery, charging else { return nil }
            return 0.5
        }()
        let image = StatusIconRenderer.image(
            scene: scene,
            pointSize: settings.menuBarIconSize,
            dark: dark,
            chargingGlow: glow,
            footerSlot: footer
        )
        return HStack(spacing: 24) {
            // 实际尺寸：菜单栏里真正的观感（衬一条基线供对比）
            Image(nsImage: image)
                .offset(y: 2)
            // 放大 2 倍：小尺寸下看不清的细节（环、槽位文本）在这里可辨
            Image(nsImage: StatusIconRenderer.image(
                scene: scene,
                pointSize: settings.menuBarIconSize * 2,
                dark: dark,
                chargingGlow: glow,
                footerSlot: footer
            ))
        }
    }

    private var summaryLine: String {
        let percent = settings.showsBatteryPercentage ? "显示" : "隐藏"
        let slot = SettingsSlotOptions.option(id: settings.footerSlotID)?.title ?? settings.footerSlotID
        return "尺寸 \(Int(settings.menuBarIconSize)) pt · 百分比\(percent) · 底部槽位：\(slot)"
    }
}
