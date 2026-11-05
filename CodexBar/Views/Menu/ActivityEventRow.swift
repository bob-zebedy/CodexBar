import SwiftUI

struct ActivityEventRow<Content: View>: View {
    @Environment(\.contentAnimationsEnabled) private var allowsAnimations

    let symbolName: String
    private let content: Content

    init(symbolName: String, @ViewBuilder content: () -> Content) {
        self.symbolName = symbolName
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Group {
                if #available(macOS 26.0, *) {
                    // 保留符号身份和原生字形尺寸, 避免替换时插值图片宽高比
                    Image(systemName: symbolName)
                        .contentTransition(allowsAnimations ? .symbolEffect(.replace.magic(fallback: .replace.downUp.wholeSymbol)) : .identity)
                } else {
                    ZStack {
                        Image(systemName: symbolName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 10, height: 10)
                            .id(symbolName)
                            .transition(allowsAnimations ? .opacity : .identity)
                    }
                }
            }
            .symbolRenderingMode(.monochrome)
            .symbolVariant(.none)
            .font(.system(size: 10, weight: .regular))
            .frame(width: 10, height: 10)
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            .foregroundStyle(Color.codexSecondaryLabel)
            .animation(allowsAnimations ? .codexStatus : nil, value: symbolName)
            content
                .clipped()
        }
        .font(MenuMetrics.bodyFont)
        .fixedSize(horizontal: false, vertical: true)
    }
}
