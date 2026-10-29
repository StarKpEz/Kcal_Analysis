import Combine
import SwiftUI
import UIKit

@MainActor
final class NativeTabBarState: ObservableObject {
    // The web route is authoritative; taps wait for its confirmed selection.
    @Published var section = "diet"
    @Published var visible = false
    var onSelect: ((String) -> Void)?
}

@MainActor
struct NativeTabBar: View {
    @ObservedObject var state: NativeTabBarState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var accentColor: Color {
        colorScheme == .dark
            ? Color(red: 100.0 / 255, green: 168.0 / 255, blue: 1)
            : Color(red: 0, green: 98.0 / 255, blue: 204.0 / 255)
    }

    var body: some View {
        barSurface
            .fixedSize(horizontal: false, vertical: true)
            .allowsHitTesting(state.visible)
            .accessibilityHidden(!state.visible)
            .transaction { transaction in
                if reduceMotion {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
    }

    @ViewBuilder
    private var barSurface: some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            buttons
                .glassEffect(.regular.interactive(), in: Capsule())
        } else {
            buttons
                .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(
                        Color.primary.opacity(contrast == .increased ? 0.65 : 0.18),
                        lineWidth: 1
                    )
                }
        }
    }

    private var buttons: some View {
        HStack(spacing: 4) {
            tab("diet", title: "饮食", symbol: "fork.knife")
            tab("health", title: "健康", symbol: state.section == "health" ? "heart.fill" : "heart")
        }
        .padding(4)
        .tint(accentColor)
    }

    private func tab(_ section: String, title: String, symbol: String) -> some View {
        let selected = state.section == section
        return Button {
            state.onSelect?(section)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: selected ? .semibold : .regular))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.caption)
                    .fontWeight(selected ? .semibold : .medium)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 56)
            .foregroundStyle(selected ? accentColor : Color.primary)
            .background {
                if selected {
                    // A plain selection fill does not sample or add another glass layer.
                    Capsule().fill(Color.primary.opacity(contrast == .increased ? 0.16 : 0.08))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint("切换到" + title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("native-tab-" + section)
    }
}
