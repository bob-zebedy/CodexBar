import SwiftUI

struct ActivityCardHeader: View {
    let components: [String]
    let projectName: String?
    let positionText: String?
    let hasPin: Bool
    let isPinned: Bool
    let showsKeepAliveBadge: Bool
    var usesWrappedLayout: Binding<Bool>?
    @Environment(\.contentAnimationsEnabled) private var allowsAnimations

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            ActivitySummaryText(
                components: components,
                primaryLineLimit: 1,
                primaryTruncationMode: .middle,
                supplementaryLineLimit: 1,
                singleLineWidthReserve: 32,
                usesWrappedLayout: usesWrappedLayout,
                primaryHelp: projectName
            )
            .font(MenuMetrics.titleFont)
            .padding(.vertical, 3)
            .foregroundStyle(Color.codexLabel)
            .numericTransition(value: components)
            .fixedSize(horizontal: false, vertical: true)
            .clipped()
            .frame(maxWidth: .infinity, alignment: .leading)
            if hasPin || positionText != nil || showsKeepAliveBadge {
                badges.fixedSize()
                    .transition(.opacity)
            }
        }
        .animation(allowsAnimations ? .easeInOut(duration: 0.25) : nil, value: hasPin)
    }

    private var badges: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if hasPin {
                // 保留数字徽标的行高和基线, 无位置数字时图标也不改变对齐位置
                Text(verbatim: "0")
                    .font(MenuMetrics.badgeFont)
                    .hidden()
                    .frame(width: 10)
                    .overlay {
                        Image(systemName: isPinned ? "pin.fill" : "pin")
                            .resizable()
                            .scaledToFit()
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(isPinned ? Color.accentColor : Color.codexSecondaryLabel)
                            .frame(width: 10, height: 10)
                    }
                    .padding(.vertical, 3)
                    .transition(.opacity)
            }
            if let positionText {
                Text(verbatim: positionText)
                    .font(MenuMetrics.badgeFont.monospacedDigit())
                    .foregroundStyle(Color.codexSecondaryLabel)
                    .numericTransition(value: positionText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.secondary.opacity(0.12), in: Capsule())
            }
            if showsKeepAliveBadge {
                Text(verbatim: "0")
                    .font(MenuMetrics.badgeFont)
                    .hidden()
                    .frame(width: 10)
                    .overlay {
                        Group {
                            if allowsAnimations {
                                RotatingKeepAliveSun()
                            } else {
                                Image(systemName: "sun.max.fill")
                                    .resizable()
                                    .scaledToFit()
                            }
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.teal)
                        .frame(width: 10, height: 10)
                    }
                    .padding(.vertical, 3)
                    .transition(.opacity)
            }
        }
        .animation(allowsAnimations ? .codexStatus : nil, value: showsKeepAliveBadge)
        .allowsHitTesting(false)
    }
}

private struct RotatingKeepAliveSun: View {
    @State private var isRotating = false

    var body: some View {
        Image(systemName: "sun.max.fill")
            .resizable()
            .scaledToFit()
            .rotationEffect(.degrees(isRotating ? 360 : 0))
            .animation(.linear(duration: 2).repeatForever(autoreverses: false), value: isRotating)
            .onAppear { isRotating = true }
    }
}
