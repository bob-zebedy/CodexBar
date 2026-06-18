import SwiftUI

struct LogView: View {
    @ObservedObject var store: RequestLogStore
    
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            
            if store.entries.isEmpty {
                emptyState
            } else {
                logList
            }
        }
        .frame(minWidth: 640, minHeight: 480)
    }
    
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(.tint)
            
            Text("Codex 日志")
                .font(.headline)
            
            Text("\(store.entries.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(.quaternary))
            
            Spacer()
            
            Button {
                store.clear()
            } label: {
                Label("清空", systemImage: "trash")
            }
            .controlSize(.small)
            .disabled(store.entries.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
    
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            
            Text("暂无日志")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var logList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(store.entries) { entry in
                    LogRow(entry: entry)
                    Divider()
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct LogRow: View {
    let entry: RequestLogEntry
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                summary
            }
            .buttonStyle(.plain)
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let request = entry.request {
                        payloadBlock(caption: requestCaption, time: entry.requestedAt, text: request, color: .primary)
                    }
                    
                    if let detail = entry.detail {
                        payloadBlock(
                            caption: detailCaption,
                            time: entry.respondedAt,
                            text: detail,
                            color: entry.kind == .failure ? .red : .primary
                        )
                    } else if entry.kind == .pending {
                        Text("等待响应…")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 6)
                .padding(.leading, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
    
    private var summary: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 12)
            
            Text(Self.timeFormatter.string(from: entry.requestedAt))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            
            Text(entry.kind.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(entry.kind.tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(entry.kind.tint.opacity(0.14))
                )
            
            if let method = entry.method {
                Text(method)
                    .font(.caption.weight(.medium).monospaced())
                    .foregroundStyle(.primary)
            } else if let detail = entry.detail {
                // 无方法名的记录(信息/进程级错误)直接预览正文, 避免标签后留空
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
    
    private func payloadBlock(caption: String, time: Date?, text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(caption)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                
                if let time {
                    Text(Self.timeFormatter.string(from: time))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            
            Text(text)
                .font(.caption.monospaced())
                .foregroundStyle(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    
    private var requestCaption: String {
        "请求"
    }
    
    private var detailCaption: String {
        switch entry.kind {
        case .response, .emptyResponse:
            return "响应"
        case .failure:
            return "错误"
        default:
            return "详情"
        }
    }
    
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

private extension RequestLogEntry.Kind {
    var label: String {
        switch self {
        case .pending:
            return "进行"
        case .response:
            return "完成"
        case .failure:
            return "错误"
        case .emptyResponse:
            return "请求"
        }
    }
    
    var tint: Color {
        switch self {
        case .pending:
            return .orange
        case .response:
            return .green
        case .failure:
            return .red
        case .emptyResponse:
            return .blue
        }
    }
}
