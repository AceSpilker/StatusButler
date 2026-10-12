import SwiftUI

// T-032: 首次引导视图（A2·S10 OG-FR-190"认识你的图标"三页：上电池 / 中网络 / 下音量）
// 示意图刻意不接真监控：用固定 IconSceneState 造示例场景，离屏渲染输出确定、可测试、可复现

/// 引导页数据：固定示例场景 + 文案键
public struct OnboardingPage: Sendable, Equatable {
    public let scene: IconSceneState
    public let caption: LocalizationKey

    public init(scene: IconSceneState, caption: LocalizationKey) {
        self.scene = scene
        self.caption = caption
    }
}

/// 三页固定示例场景（与生产代码、测试共用同一份，避免两处口径漂移）
public enum OnboardingSampleScenes {
    /// 电池页：78% 且充电——演示电量填充 + 绿色闪电
    public static let battery = IconSceneState(
        batteryLevel: 78, isCharging: true, signalBars: 4, volumeDots: 3, isMuted: false
    )
    /// 网络页：三格信号——演示弧线"越满越稳"
    public static let network = IconSceneState(
        batteryLevel: 72, isCharging: false, signalBars: 3, volumeDots: 3, isMuted: false
    )
    /// 音量页：两格音量——演示圆点点亮与变暗
    public static let volume = IconSceneState(
        batteryLevel: 72, isCharging: false, signalBars: 4, volumeDots: 2, isMuted: false
    )

    /// 页序固定绑定图标从上到下的物理顺序
    public static let pages: [OnboardingPage] = [
        OnboardingPage(scene: battery, caption: .onboardingIconTop),
        OnboardingPage(scene: network, caption: .onboardingIconMiddle),
        OnboardingPage(scene: volume, caption: .onboardingIconBottom),
    ]
}

public struct OnboardingView: View {
    private let localization: Localization
    /// 完成回调由窗口壳消费（关窗 + 通知集成方持久化 hasSeenGuide）
    private let onDone: () -> Void
    @State private var pageIndex = 0
    @Environment(\.colorScheme) private var colorScheme

    public init(localization: Localization, onDone: @escaping () -> Void) {
        self.localization = localization
        self.onDone = onDone
    }

    private var page: OnboardingPage {
        OnboardingSampleScenes.pages[pageIndex]
    }

    public var body: some View {
        VStack(spacing: 18) {
            Text.localized(.onboardingTitle, in: localization)
                .font(.title.weight(.bold))
            if pageIndex == 0 {
                Text.localized(.onboardingWelcome, in: localization)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)
            }
            iconPreview(page.scene)
            Text.localized(page.caption, in: localization)
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .frame(width: 500, height: 480)
        .animation(.easeInOut(duration: 0.15), value: pageIndex)
    }

    /// 大尺寸重渲染示意图：跟随窗口外观换墨色（一次性引导窗口，无需渲染缓存）
    private func iconPreview(_ scene: IconSceneState) -> some View {
        Image(
            nsImage: StatusIconRenderer.image(
                scene: scene, pointSize: 140, dark: colorScheme == .dark
            )
        )
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 148, height: 148)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.quaternary.opacity(0.35))
        )
    }

    private var footer: some View {
        HStack {
            Button {
                if pageIndex > 0 { pageIndex -= 1 }
            } label: {
                Text.localized(.onboardingBack, in: localization)
            }
            .disabled(pageIndex == 0)

            Spacer()

            HStack(spacing: 8) {
                ForEach(0..<OnboardingSampleScenes.pages.count, id: \.self) { index in
                    Circle()
                        .fill(index == pageIndex ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(width: 8, height: 8)
                }
            }

            Spacer()

            if pageIndex == OnboardingSampleScenes.pages.count - 1 {
                Button {
                    onDone()
                } label: {
                    Text.localized(.onboardingDone, in: localization)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    pageIndex += 1
                } label: {
                    Text.localized(.onboardingNext, in: localization)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
