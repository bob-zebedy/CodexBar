import Foundation

/// 只读 tail 读取 HookEvents/events 目录: 轮询当日 JSONL 文件大小,
/// 增量解码新追加的完整事件行后回调
/// 仅服务于通知判定, 不参与统计维护; 任何读取失败都静默跳过本轮
@MainActor
final class HookEventTailReader {
    private let onEvents: ([WorkflowHookEvent]) -> Void
    private var pollTask: Task<Void, Never>?
    private var activeDateKey = ""
    private var activeFileOffset: UInt64 = 0

    init(onEvents: @escaping ([WorkflowHookEvent]) -> Void) {
        self.onEvents = onEvents
    }

    func start() {
        guard pollTask == nil else {
            return
        }

        // 初始位点取当天文件当前大小: 只处理启动之后写入的事件, 不回放历史
        activeDateKey = WorkflowStorage.dateKey(for: Date())
        activeFileOffset = WorkflowStorage.fileSize(at: activeFileURL)

        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollInterval))
                guard let self, !Task.isCancelled else {
                    return
                }

                drainNewLines()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private var activeFileURL: URL {
        WorkflowStorage.eventLogURL(for: activeDateKey)
    }

    private func drainNewLines() {
        let todayKey = WorkflowStorage.dateKey(for: Date())
        if todayKey != activeDateKey {
            // 跨零点: 先清掉旧文件尾部, 再从新文件头开始
            readAppendedLines()
            activeDateKey = todayKey
            activeFileOffset = 0
        }

        readAppendedLines()
    }

    private func readAppendedLines() {
        let url = activeFileURL
        let size = WorkflowStorage.fileSize(at: url)
        if size < activeFileOffset {
            // 文件被截断或替换, 从当前头部重新开始
            activeFileOffset = 0
        }

        guard size > activeFileOffset,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return
        }

        defer {
            try? handle.close()
        }

        guard (try? handle.seek(toOffset: activeFileOffset)) != nil,
              let data = try? handle.readToEnd(),
              !data.isEmpty else {
            return
        }

        // 只消费到最后一个完整行, 半行留待下一轮
        guard let lastNewlineIndex = data.lastIndex(of: Self.newlineByte) else {
            return
        }

        let completeData = data[...lastNewlineIndex]
        activeFileOffset += UInt64(completeData.count)

        let events = JSONLines.decode(WorkflowHookEvent.self, from: completeData)
        guard !events.isEmpty else {
            return
        }

        onEvents(events)
    }

    private static let pollInterval: TimeInterval = 2
    private static let newlineByte: UInt8 = 0x0A
}
