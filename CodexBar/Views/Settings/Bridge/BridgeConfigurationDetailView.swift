import AppKit
import SwiftUI

struct BridgeConfigurationDetailView: View {
    let configuration: BridgeConfiguration
    let host: BridgeHost
    @State private var format = BridgeMCPExportFormat.allCases[0]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("bridge.export.format")
                Picker("bridge.export.format", selection: $format) {
                    ForEach(BridgeMCPExportFormat.allCases, id: \.self) { format in
                        Text(verbatim: format.title).tag(format)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            BridgeMCPPreview(configuration: configuration, host: host, format: format)
                .id(format)
        }
    }
}

private struct BridgeMCPPreview: View {
    let configuration: BridgeConfiguration
    let host: BridgeHost
    let format: BridgeMCPExportFormat
    @State private var result: Result<String, any Error>?
    @State private var copyStatus = CopyStatus.idle

    private enum CopyStatus: String {
        case idle = "doc.on.doc"
        case copied = "checkmark"
        case failed = "exclamationmark.triangle"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let path = format.defaultFilePath {
                    Label {
                        Text(verbatim: path)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "doc")
                    }
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Group {
                    if case let .success(text) = result {
                        copyButton(for: text)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 26, height: 26)
            }
            .frame(minHeight: 26)
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 4)
            .background(.background.secondary)
            Divider()
            Group {
                switch result {
                case let .success(text):
                    ScrollView([.horizontal, .vertical]) {
                        Text(verbatim: text)
                            .font(.system(.callout, design: .monospaced))
                            .lineSpacing(2)
                            .fixedSize()
                            .textSelection(.enabled)
                            .padding(14)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                case let .failure(error):
                    Text(verbatim: error.localizedDescription)
                        .foregroundStyle(.red)
                        .padding(14)
                case nil:
                    ProgressView().controlSize(.small).padding(14)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .bridgeSettingsGroup()
        .task {
            do {
                let text = try await host.runtime.exportMCPConfiguration(for: configuration.id, format: format)
                if !Task.isCancelled {
                    result = .success(text)
                }
            } catch {
                if !Task.isCancelled {
                    result = .failure(error)
                }
            }
        }
        .task(id: copyStatus) {
            guard copyStatus != .idle else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copyStatus = .idle
        }
    }

    private func copyButton(for text: String) -> some View {
        let title: LocalizedStringKey = copyStatus == .failed ? "bridge.export.copy-failed" : "common.action.copy"
        return Button { copy(text) } label: {
            Label(title, systemImage: copyStatus.rawValue)
                .labelStyle(.iconOnly)
                .frame(width: 26, height: 26)
                .foregroundStyle(copyStatus == .failed ? Color.red : Color.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func copy(_ text: String) {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        NSPasteboard.general.clearContents()
        copyStatus = NSPasteboard.general.writeObjects([item]) ? .copied : .failed
    }
}
