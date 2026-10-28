import AppKit
import Foundation
import IOKit.ps
import os

/// 一次电源读取的结果
/// 区分读取成功, 失败和无电池, 避免读取失败时隐藏设置项并解除保护
nonisolated enum BatteryReading: Equatable {
    /// 确认这台机器没有内置电池 (台式机)
    case unavailable
    /// 读取失败, 有没有电池以及电量都未知
    case unreadable
    case present(BatteryStatus)

    var status: BatteryStatus? {
        guard case let .present(status) = self else {
            return nil
        }
        return status
    }

    /// 只有确认没有电池才隐藏设置项; 读不出来时按"可能有"处理, 避免设置项闪烁
    var hasBattery: Bool {
        self != .unavailable
    }

    /// 日志使用的状态标识, 电量仅在触及阈值时记录
    var loggedState: String {
        switch self {
        case .unavailable: "unavailable"
        case .unreadable: "unreadable"
        case .present: "present"
        }
    }
}

nonisolated struct BatteryStatus: Equatable {
    let percent: Int
    /// 正在靠电池供电; 接着电源时为 false, 此时电量不会被耗干
    let isOnBattery: Bool
}

/// 读取系统电源状态并在变化时通知调用方, 阈值和防睡眠由调用方处理
/// 封装 IOKit 的 C 接口及内存管理
@MainActor
final class PowerSourceMonitor {
    private(set) var reading = BatteryReading.unreadable

    private var onChange: (() -> Void)?
    private var runLoopSource: CFRunLoopSource?
    private var wakeObserver: NSObjectProtocol?
    private var pollTask: Task<Void, Never>?
    /// 独立记录启动状态, 注册失败时 runLoopSource 为 nil, 但唤醒观察者已安装
    private var isMonitoring = false
    /// 这台机器确认装着内置电池
    /// 硬件不会中途消失, 所以见过之后再读到空列表只能是枚举缺口, 不能当成台式机
    private var hasSeenBattery = false

    /// 回调里持有的是 unretained 指针, 停止监听必须显式做, 由持有者在 stop 时调用
    /// 在此释放资源, 因为 Swift 6 的 nonisolated deinit 无法访问这些非 Sendable 属性
    func stop() {
        isMonitoring = false
        pollTask?.cancel()
        pollTask = nil
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
            self.runLoopSource = nil
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        onChange = nil
    }

    /// onChange 只在读数真的变化时回调
    func start(onChange: @escaping () -> Void) {
        guard !isMonitoring else {
            return
        }
        isMonitoring = true
        self.onChange = onChange
        // refresh 会跳过与初始 unreadable 相同的结果, 因此首次读取单独处理
        // 首读失败也要记录, 才能与恢复日志配对, 确认低电量判定暂停的时段
        let initialReading = currentReading()
        if initialReading == .unreadable {
            AppLog.keepAlive.error("电源监听读取失败: stage=start")
        }
        reading = initialReading

        // 先安装唤醒观察者, source 注册失败后仍可与轮询一起补读
        // 睡眠期间电量可能变化很大, 而系统不一定为此补发电源通知
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else {
                return
            }
            // 回调跑在注册它的 runloop 上, 这里就是主线程
            MainActor.assumeIsolated {
                Unmanaged<PowerSourceMonitor>.fromOpaque(context)
                    .takeUnretainedValue()
                    .refresh()
            }
        }, context)?.takeRetainedValue() else {
            // action= 记录注册失败后仍可用的监测方式
            let details = LogFields.joined(
                "stage=createRunLoopSource",
                "action=poll"
            )
            AppLog.keepAlive.error("电源监听注册失败: \(details, privacy: .public)")
            startPolling()
            return
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = source
    }

    func refresh() {
        let newReading = currentReading()
        guard newReading != reading else {
            return
        }

        // 成对记录降级和恢复, 用于确认 unreadable 期间低电量判定暂停了多久
        if case .unreadable = newReading {
            AppLog.keepAlive.error("电源监听读取失败: stage=refresh")
        } else if case .unreadable = reading {
            let state = newReading.loggedState
            AppLog.keepAlive.notice("电源监听读取已恢复: state=\(state, privacy: .public)")
        }
        reading = newReading
        onChange?()
    }

    /// 注册失败后的兜底轮询
    /// 防睡眠生效期间没有唤醒通知, 需通过轮询继续读取电源状态
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollIntervalSeconds))
                guard !Task.isCancelled, let self else {
                    return
                }

                refresh()
            }
        }
    }

    /// 电量按 Current/Max 的比例计算
    /// 实测两者都是百分比 (Max=100), 但历史上某些路径下是 mAh, 按比例算两种情况都对
    private func currentReading() -> BatteryReading {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return .unreadable
        }

        for source in sources {
            // Get 语义, 不能 takeRetainedValue
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any],
                description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                description[kIOPSIsPresentKey] as? Bool == true else {
                continue
            }

            hasSeenBattery = true
            guard let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int,
                  maximum > 0 else {
                return .unreadable
            }

            let percent = Int((Double(current) / Double(maximum) * 100).rounded())
            // Battery Power 表示电池供电, Is Charging 在接电但停充时也为 false, 不能用于判断供电方式
            let isOnBattery = description[kIOPSPowerSourceStateKey] as? String
                == kIOPSBatteryPowerValue
            return .present(
                BatteryStatus(
                    percent: min(max(percent, 0), 100),
                    isOnBattery: isOnBattery
                )
            )
        }

        // 走到这里既可能是台式机, 也可能是 IOKit 正在重新枚举而列表暂时为空
        // 已确认有电池时按读取失败处理, 调用方保留上次判定, 避免枚举缺口解除保护
        return hasSeenBattery ? .unreadable : .unavailable
    }

    private static let pollIntervalSeconds = 60
}
