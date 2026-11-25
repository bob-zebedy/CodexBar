import Darwin
import os
import SwiftUI

@main
nonisolated enum CodexBarMain {
    static func main() {
        if CommandLine.arguments.dropFirst().elementsEqual(["--mcp"]) {
            exit(BridgeStdio.run())
        }
        do {
            // 在 SwiftUI 创建 CodexBarLifecycle 前互斥, 避免重复实例初始化服务
            guard let descriptor = try JSONFileStorage.acquireLock(
                at: AppStoragePaths().lockURL(.appInstance), nonblocking: true
            ) else { return }
            defer { JSONFileStorage.releaseLock(descriptor) }

            // 同步进程入口位于主线程, 取得锁后才进入 SwiftUI 生命周期
            BridgeLogPrivacy.shared.beginRestoration()
            MainActor.assumeIsolated {
                CodexBarApp.main()
            }
        } catch {
            AppLog.app.error("App 实例锁获取失败")
            exit(EXIT_FAILURE)
        }
    }
}
