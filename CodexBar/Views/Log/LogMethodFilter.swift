import SwiftUI

struct LogMethodFilter: View {
    @ObservedObject var store: AppServerLogViewModel
    @State private var isPresented = false
    @State private var query = ""
    @State private var methods: [String] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if store.selectedMethods.isEmpty {
                Button {
                    isPresented.toggle()
                } label: {
                    Label("log.filter.methods", systemImage: "line.3.horizontal.decrease")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(.secondary)
            } else {
                Button {
                    store.setSelectedMethods([])
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 24)
                        .contentShape(Rectangle())
                }

                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        ForEach(store.selectedMethods.sorted(), id: \.self) { method in
                            HStack(spacing: 4) {
                                Text(verbatim: method)
                                    .font(LogTypography.captionFont.monospaced())
                                    .lineLimit(1)
                                Button {
                                    toggle(method)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.caption2)
                                }
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                isPresented.toggle()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .padding(.horizontal, 4)
            }
        }
        .buttonStyle(.plain)
        .font(LogTypography.controlFont)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture { isPresented = true }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            methodPicker
        }
    }

    private var methodPicker: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("log.filter.search", text: $query)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            Divider()
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(Color.red)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if matchingMethods.isEmpty {
                Text("log.filter.no-matches")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(matchingMethods, id: \.self) { method in
                            Button {
                                toggle(method)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark")
                                        .opacity(store.selectedMethods.contains(method) ? 1 : 0)
                                        .frame(width: 14)
                                    Text(verbatim: method)
                                        .font(LogTypography.captionFont.monospaced())
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(6)
                }
            }
        }
        .font(LogTypography.controlFont)
        .frame(width: 360, height: 320)
        .task {
            query = ""
            isSearchFocused = true
            isLoading = true
            defer { isLoading = false }
            do {
                let available = try await store.availableMethods()
                try Task.checkCancellation()
                methods = available
                errorMessage = nil
            } catch is CancellationError {
                // 关闭下拉框后不再更新候选项
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var matchingMethods: [String] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return Set(methods).union(store.selectedMethods).sorted().filter {
            search.isEmpty || $0.localizedStandardContains(search)
        }
    }

    private func toggle(_ method: String) {
        var selection = store.selectedMethods
        if !selection.insert(method).inserted {
            selection.remove(method)
        }
        store.setSelectedMethods(selection)
    }
}
