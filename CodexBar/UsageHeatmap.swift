//
//  UsageHeatmap.swift
//  CodexBar
//
//  Created by Bob on 2026-06-14.
//

import SwiftUI

struct UsageSummaryView: View {
    let usage: CodexUsageSnapshot
    private let days: [DailyUsageBucket]
    @State private var hoveredDay: DailyUsageBucket?
    
    init(usage: CodexUsageSnapshot) {
        self.usage = usage
        self.days = usage.recentDays(count: UsageHeatmap.Metrics.dayCount, endingDaysAgo: 1)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                metric(label: "单日峰值", value: usage.summary.peakDailyTokens, alignment: .leading)
                Spacer()
                metric(label: "全时累计", value: usage.summary.lifetimeTokens, alignment: .trailing)
            }
            
            UsageHeatmap(days: days, hoveredDay: $hoveredDay)
        }
        .padding(10)
        .liquidGlassSurface(cornerRadius: 8, tint: .blue)
        .onAppear {
            hoveredDay = nil
        }
    }
    
    private func metric(label: String, value: Int, alignment: Alignment) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: alignment)
            
            TokenCountText(tokens: value)
                .frame(maxWidth: .infinity, alignment: alignment)
        }
        .frame(width: 96)
    }
}

struct UsageHeatmap: View {
    let days: [DailyUsageBucket]
    @Binding var hoveredDay: DailyUsageBucket?
    @State private var hoveredSquareFrame: CGRect = .zero
    // hover 期间 body 频繁重算, 峰值只在构建时求一次
    private let peakTokens: Int
    
    init(days: [DailyUsageBucket], hoveredDay: Binding<DailyUsageBucket?>) {
        self.days = days
        self._hoveredDay = hoveredDay
        self.peakTokens = max(days.lazy.map(\.tokens).max() ?? 0, 1)
    }
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            heatmapGrid
            
            if let hoveredDay {
                UsageHeatmapTooltip(day: hoveredDay)
                    .id(hoveredDay.id)
                    .allowsHitTesting(false)
                    .offset(tooltipOffset)
                    .zIndex(1)
                    .transition(.opacity)
            }
        }
        .frame(height: Metrics.height)
        .coordinateSpace(name: Metrics.coordinateSpaceName)
    }
    
    private var heatmapGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("近 \(days.count) 天")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                if let firstDate = days.first?.startDate, let lastDate = days.last?.startDate {
                    Text("\(firstDate) ~ \(lastDate)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            
            HStack(alignment: .top, spacing: Metrics.squareSpacing) {
                ForEach(0..<Metrics.columnCount, id: \.self) { column in
                    VStack(spacing: Metrics.squareSpacing) {
                        ForEach(0..<Metrics.rowCount, id: \.self) { row in
                            let index = column * Metrics.rowCount + row
                            
                            if days.indices.contains(index) {
                                let day = days[index]
                                UsageHeatmapSquare(
                                    day: day,
                                    percent: Double(day.tokens) / Double(peakTokens),
                                    isHovered: hoveredDay?.id == day.id
                                ) { frame in
                                    if hoveredDay?.id != day.id {
                                        withAnimation(.easeInOut(duration: Metrics.tooltipFadeDuration)) {
                                            hoveredDay = day
                                            hoveredSquareFrame = frame
                                        }
                                    } else if hoveredSquareFrame != frame {
                                        hoveredSquareFrame = frame
                                    }
                                } onEnded: {
                                    if hoveredDay?.id == day.id {
                                        withAnimation(.easeInOut(duration: Metrics.tooltipFadeDuration)) {
                                            hoveredDay = nil
                                        }
                                    }
                                }
                            } else {
                                Color.clear
                                    .frame(width: Metrics.squareSize, height: Metrics.squareSize)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private var tooltipOffset: CGSize {
        let aboveY = hoveredSquareFrame.minY - Metrics.tooltipSquareSpacing - Metrics.tooltipHeight
        let tooltipY = aboveY >= 0 ? aboveY : hoveredSquareFrame.maxY + Metrics.tooltipSquareSpacing
        
        return CGSize(
            width: tooltipX(for: hoveredSquareFrame),
            height: min(max(tooltipY, 0), max(0, Metrics.height - Metrics.tooltipHeight))
        )
    }
    
    private func tooltipX(for squareFrame: CGRect) -> CGFloat {
        let trailingX = squareFrame.maxX + Metrics.tooltipSquareSpacing
        let leadingX = squareFrame.minX - Metrics.tooltipSquareSpacing - Metrics.tooltipWidth
        let maxX = max(0, Metrics.totalWidth - Metrics.tooltipWidth)
        
        if leadingX >= 0 {
            return leadingX
        }
        
        if trailingX + Metrics.tooltipWidth <= Metrics.totalWidth {
            return trailingX
        }
        
        return min(max(leadingX, 0), maxX)
    }
}

extension UsageHeatmap {
    enum Metrics {
        static let coordinateSpaceName = "usageHeatmap"
        static let columnCount = 30
        static let rowCount = 7
        static let squareSize: CGFloat = 12
        static let squareSpacing: CGFloat = 3
        static let height: CGFloat = 120
        static let tooltipWidth: CGFloat = 78
        static let tooltipHeight: CGFloat = 38
        static let tooltipSquareSpacing: CGFloat = 2
        static let tooltipFadeDuration: TimeInterval = 0.15
        
        static var dayCount: Int { columnCount * rowCount }
        
        static var totalWidth: CGFloat {
            CGFloat(columnCount) * squareSize + CGFloat(columnCount - 1) * squareSpacing
        }
    }
}

private struct UsageHeatmapSquare: View {
    let day: DailyUsageBucket
    let percent: Double
    let isHovered: Bool
    let onActive: (CGRect) -> Void
    let onEnded: () -> Void
    
    var body: some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(fillColor)
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(borderColor, lineWidth: isHovered ? 1.2 : 0.7)
                }
                .shadow(color: .blue.opacity(0.22), radius: isHovered ? 5 : 0, y: isHovered ? 2 : 0)
                .scaleEffect(isHovered ? 1.08 : 1)
                .onContinuousHover { phase in
                    switch phase {
                    case .active:
                        onActive(proxy.frame(in: .named(UsageHeatmap.Metrics.coordinateSpaceName)))
                    case .ended:
                        onEnded()
                    }
                }
        }
        .frame(width: UsageHeatmap.Metrics.squareSize, height: UsageHeatmap.Metrics.squareSize)
        .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .animation(.snappy(duration: 0.14), value: isHovered)
    }
    
    private var clampedPercent: Double {
        min(max(percent, 0), 1)
    }
    
    private var fillColor: Color {
        guard day.tokens > 0 else {
            return Color.blue.opacity(isHovered ? 0.16 : 0.08)
        }
        
        let intensity = pow(clampedPercent, 0.62)
        let opacity = 0.18 + intensity * 0.68
        return Color.blue.opacity(isHovered ? min(opacity + 0.10, 1.0) : opacity)
    }
    
    private var borderColor: Color {
        if isHovered {
            return Color.blue.opacity(0.78)
        }
        
        return Color.blue.opacity(day.tokens > 0 ? 0.18 : 0.10)
    }
}

private struct UsageHeatmapTooltip: View {
    let day: DailyUsageBucket
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(day.startDate)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Color.codexSecondaryLabel)
            
            TokenCountText(tokens: day.tokens)
                .foregroundStyle(Color.codexLabel)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(width: UsageHeatmap.Metrics.tooltipWidth, alignment: .leading)
        .liquidGlassSurface(cornerRadius: 7, tint: .blue)
    }
}
