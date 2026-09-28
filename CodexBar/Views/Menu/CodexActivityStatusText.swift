import SwiftUI

struct CodexActivityStatusText: View {
    enum Effect: Equatable {
        case none
        case shimmer
        case ionizing(taskID: UUID)
    }

    let text: String
    let tint: Color
    let effect: Effect

    var body: some View {
        Text(text)
            .foregroundStyle(tint)
            .overlay {
                if effect == .shimmer {
                    ActivityStatusShimmer()
                        .mask {
                            Text(text)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        }
                        .allowsHitTesting(false)
                }
            }
            .font(.caption2)
            .lineLimit(1)
            .truncationMode(.tail)
            .anchorPreference(key: ActivityIonizationSourceKey.self, value: .bounds) { bounds in
                if case let .ionizing(taskID) = effect {
                    return [ActivityIonizationSource(taskID: taskID, bounds: bounds)]
                }
                return []
            }
    }
}

extension View {
    func activityStatusParticles(cornerRadius: CGFloat) -> some View {
        // 在玻璃背景之前应用, 让粒子位于背景之上和文字之下
        backgroundPreferenceValue(ActivityIonizationSourceKey.self) { sources in
            GeometryReader { geometry in
                let panelBounds = CGRect(origin: .zero, size: geometry.size)
                let emitters = sources.compactMap { source -> ActivityIonizationEmitter? in
                    let bounds = geometry[source.bounds]
                    let viewport = source.viewport.map { geometry[$0] } ?? panelBounds
                    guard bounds.intersects(viewport), bounds.intersects(panelBounds) else { return nil }
                    return ActivityIonizationEmitter(taskID: source.taskID, bounds: bounds)
                }
                if !emitters.isEmpty {
                    ActivityIonizationParticles(emitters: emitters)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .allowsHitTesting(false)
        }
    }

    func activityStatusParticleViewport() -> some View {
        transformAnchorPreference(key: ActivityIonizationSourceKey.self, value: .bounds) { sources, viewport in
            for index in sources.indices {
                sources[index].viewport = viewport
            }
        }
    }
}

private struct ActivityIonizationSource {
    let taskID: UUID
    let bounds: Anchor<CGRect>
    var viewport: Anchor<CGRect>?
}

private struct ActivityIonizationEmitter {
    let bounds: CGRect
    let seed: Int

    init(taskID: UUID, bounds: CGRect) {
        self.bounds = bounds
        // 随机序列只依赖任务身份, 滚动过滤和任务增删不改变其他任务的粒子相位
        seed = Int(UInt32(truncatingIfNeeded: taskID.hashValue)) * 12
    }
}

private struct ActivityIonizationSourceKey: PreferenceKey {
    static var defaultValue: [ActivityIonizationSource] {
        []
    }

    static func reduce(value: inout [ActivityIonizationSource], nextValue: () -> [ActivityIonizationSource]) {
        value.append(contentsOf: nextValue())
    }
}

private struct ActivityIonizationParticles: View {
    let emitters: [ActivityIonizationEmitter]
    @State private var startedAt = Date()

    var body: some View {
        // 面板共用一条粒子时间线, 发射源为空时由宿主移除; 不受任务行和滚动容器裁剪
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSince(startedAt)
            Canvas { context, _ in
                context.addFilter(.shadow(color: .orange.opacity(0.9), radius: 4.0 / 3))
                context.addFilter(.shadow(color: .orange.opacity(0.5), radius: 4))
                for emitter in emitters {
                    for index in 0 ..< 12 {
                        let seed = emitter.seed + index
                        let age = elapsed / 1.1 + ActivityIonizationNoise.value(seed, seed: 7331)
                        let life = age - floor(age)
                        let angle = ActivityIonizationNoise.value(seed, seed: Int(floor(age))) * 2 * .pi
                        let origin = (ActivityIonizationNoise.value(seed, seed: 3) - 0.5) * 140
                        let x = emitter.bounds.midX + origin + cos(angle) * 40 * life
                        let y = emitter.bounds.midY + sin(angle) * 30 * life
                        var particleContext = context
                        particleContext.opacity = 1 - life
                        particleContext.fill(
                            Path(ellipseIn: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)),
                            with: .color(.orange)
                        )
                    }
                }
            }
        }
    }
}

private enum ActivityIonizationNoise {
    static func value(_ index: Int, seed: Int) -> Double {
        let value = sin(Double(index + 1) * 127.1 + Double(seed) * 311.7) * 43758.5453
        return value - floor(value)
    }
}

private struct ActivityStatusShimmer: View {
    @State private var startedAt = Date()

    var body: some View {
        // 动画只覆盖文字的绘制区域, 不参与排版; 隐藏时移除整个时间线
        GeometryReader { geometry in
            TimelineView(.animation) { timeline in
                let elapsed = timeline.date.timeIntervalSince(startedAt)
                let progress = elapsed.truncatingRemainder(dividingBy: 2.2) / 2.2
                let width = geometry.size.width * 0.4

                LinearGradient(
                    colors: [.clear, .white, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: width)
                .offset(x: (geometry.size.width + width) * progress - width)
            }
        }
    }
}
