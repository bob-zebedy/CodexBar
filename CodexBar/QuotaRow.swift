//
//  QuotaRow.swift
//  CodexBar
//
//  Created by Bob on 2026-06-10.
//

import SwiftUI

struct QuotaRow: View {
    let window: QuotaWindow
    
    var body: some View {
        HStack(alignment: .center, spacing: Metrics.spacing) {
            Text(window.label)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .frame(width: Metrics.labelWidth, alignment: .leading)
            
            SegmentedQuotaBar(percent: window.remainingPercent)
                .frame(height: Metrics.barHeight)
            
            Text(percentText)
                .font(.caption.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .frame(width: Metrics.percentWidth, alignment: .leading)
            
            Text(resetText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: Metrics.resetWidth, alignment: .trailing)
        }
    }
}

private extension QuotaRow {
    enum Metrics {
        static let spacing: CGFloat = 8
        static let labelWidth: CGFloat = 52
        static let barHeight: CGFloat = 12
        static let percentWidth: CGFloat = 32
        static let resetWidth: CGFloat = 76
    }
    
    var resetText: String {
        guard window.hasData else {
            return "暂无数据"
        }
        
        guard let resetsAt = window.resetsAt else {
            return "--"
        }
        
        return Self.resetFormatter.string(from: resetsAt)
    }
    
    var percentText: String {
        guard window.hasData else {
            return "--"
        }
        
        return "\(window.remainingPercent)%"
    }
    
    static let resetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}

private struct SegmentedQuotaBar: View {
    let percent: Int
    
    var body: some View {
        GeometryReader { proxy in
            let segmentCount = segmentCount(for: proxy.size.width)
            let filledSegments = filledSegments(for: segmentCount)
            
            HStack(spacing: Metrics.spacing) {
                ForEach(0..<segmentCount, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(index < filledSegments ? fillStyle : emptyStyle)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityLabel("剩余 \(percent)%")
    }
}

private extension SegmentedQuotaBar {
    enum Metrics {
        static let spacing: CGFloat = 2
        static let idealSegmentWidth: CGFloat = 6
    }
    
    func segmentCount(for width: CGFloat) -> Int {
        max(1, Int((width + Metrics.spacing) / (Metrics.idealSegmentWidth + Metrics.spacing)))
    }
    
    func filledSegments(for segmentCount: Int) -> Int {
        Int((Double(percent) / 100.0 * Double(segmentCount)).rounded())
    }
    
    var fillStyle: Color {
        switch percent {
        case 50...:
            return .green
        case 25..<50:
            return .orange
        default:
            return .red
        }
    }
    
    var emptyStyle: Color {
        Color.secondary.opacity(0.18)
    }
}
