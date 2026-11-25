import Darwin
import Foundation
import os

actor BridgeHost {
    private struct Session {
        let connection: BridgeSocketConnection
        let peer: BridgePeer
        let authenticationTimeout: Task<Void, Never>
        let reader: Task<Void, Never>

        func disconnect(endingClient: Bool, waitingForReader: Bool = true) async {
            authenticationTimeout.cancel()
            await peer.close()
            if endingClient {
                // 客户端停止读取时也要按时关闭已撤销的连接
                let deadline = Task {
                    try await Task.sleep(for: .milliseconds(250))
                    connection.close()
                }
                try? await connection.write(BridgeIPC.endSession)
                deadline.cancel()
            }
            connection.close()
            if waitingForReader {
                await reader.value
            }
        }
    }

    static let shared = BridgeHost()
    let runtime: BridgeRuntime
    nonisolated var directory: URL {
        runtime.directory
    }

    private var stopping = false
    private var listeners: [UUID: AsyncStream<Bool>.Continuation] = [:]
    private var restoration: Task<Void, Error>?
    private var listener: BridgeSocketListener? {
        didSet {
            for continuation in listeners.values {
                continuation.yield(listener != nil)
            }
        }
    }

    private var sessions: [UUID: Session] = [:]
    private let queue = DispatchSerialQueue(label: "app.zabrian.codexbar.bridge.ipc")

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    init(runtime: BridgeRuntime = BridgeRuntime()) {
        self.runtime = runtime
    }

    func listeningUpdates() -> AsyncStream<Bool> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        listeners[id] = continuation
        continuation.yield(listener != nil)
        continuation.onTermination = { [weak self] _ in Task { await self?.removeListener(id) } }
        return stream
    }

    private func removeListener(_ id: UUID) {
        listeners[id] = nil
    }

    func restoreAtLaunch() async {
        do { try await restore() } catch is CancellationError { return } catch {
            AppLog.app.error("Codex Bridge 启动恢复失败: \(error.localizedDescription, privacy: .private)")
        }
    }

    func restore() async throws {
        if let restoration {
            return try await restoration.value
        }
        let task = Task {
            for attempt in 0 ... 3 {
                try Task.checkCancellation()
                do {
                    try await runtime.load()
                    try Task.checkCancellation()
                    if runtime.isEnabled {
                        try await start()
                    }
                    return
                } catch {
                    let busy = (error as? BridgeSQLite.Failure)?.isBusy == true
                    let transient = (error as? POSIXError).map { [.EAGAIN, .EINTR, .EMFILE, .ENFILE].contains($0.code) } ?? false
                    guard attempt < 3, busy || transient else { throw error }
                    try await Task.sleep(for: .seconds(1 << attempt))
                }
            }
        }
        restoration = task
        defer { restoration = nil }
        try await task.value
    }

    func setEnabled(_ enabled: Bool) async throws {
        guard !stopping else { throw CancellationError() }
        restoration?.cancel()
        if enabled {
            try await runtime.setEnabled(true)
            do {
                try await start()
            } catch {
                if !stopping {
                    try await runtime.setEnabled(false)
                }
                throw error
            }
        } else {
            let active = stopListening()
            try await runtime.setEnabled(false)
            await disconnect(active, endingClients: true)
        }
    }

    func stop() async {
        stopping = true
        restoration?.cancel()
        let active = stopListening()
        await runtime.shutdown()
        await disconnect(active, endingClients: false)
    }

    private func stopListening() -> [Session] {
        listener = nil
        let active = Array(sessions.values)
        sessions.removeAll()
        return active
    }

    private func disconnect(_ active: [Session], endingClients: Bool) async {
        await withTaskGroup(of: Void.self) { group in
            for session in active {
                group.addTask { await session.disconnect(endingClient: endingClients) }
            }
        }
    }

    func deleteConfiguration(_ configurationID: UUID) async throws {
        try await runtime.deleteConfiguration(configurationID)
        await withTaskGroup(of: Void.self) { group in
            for (key, entry) in sessions where await entry.peer.configurationID == configurationID {
                if let session = sessions.removeValue(forKey: key) {
                    group.addTask { await session.disconnect(endingClient: true) }
                }
            }
        }
    }

    private func start() async throws {
        try Task.checkCancellation()
        guard !stopping else { throw CancellationError() }
        guard runtime.isEnabled, listener == nil else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        listener = try BridgeSocketListener(in: directory, queue: queue) { [weak self] descriptor in
            guard let self else {
                Darwin.close(descriptor)
                return
            }
            // 监听源与 host 使用同一串行队列, 在此处直接执行连接数检查
            assumeIsolated { $0.add(descriptor) }
        }
        await runtime.activate()
    }

    private func add(_ descriptor: Int32) {
        guard listener != nil, sessions.count < 32 else {
            Darwin.close(descriptor)
            return
        }
        guard let connection = try? BridgeSocketConnection(taking: descriptor, queue: queue) else { return }
        let id = UUID()
        let peer = BridgePeer(runtime: runtime, endSession: { [weak self] in await self?.drop(id, endingClient: true) }, output: connection.write)
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            if await peer.configurationID == nil {
                await drop(id)
            }
        }
        let reader = Task {
            do {
                try await connection.readMessages(into: peer)
            } catch let failure as BridgeFailure where ["unauthorized", "session_incompatible"].contains(failure.code) {
                await drop(id, endingClient: true, waitingForReader: false)
                return
            } catch {}
            await drop(id, waitingForReader: false)
        }
        sessions[id] = Session(connection: connection, peer: peer, authenticationTimeout: timeout, reader: reader)
    }

    private func drop(_ id: UUID, endingClient: Bool = false, waitingForReader: Bool = true) async {
        guard let session = sessions.removeValue(forKey: id) else { return }
        await session.disconnect(endingClient: endingClient, waitingForReader: waitingForReader)
    }
}
