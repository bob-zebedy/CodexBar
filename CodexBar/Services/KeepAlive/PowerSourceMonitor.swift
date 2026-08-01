import AppKit
import Foundation
import IOKit.ps
import os

/// 一次电源读取的结果
/// 三态而不是可选值: 把读取失败折叠进"没有电池"会让设置项凭空消失, 保护也静默失效
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

    /// 日志用的状态标识; 不带电量, 那个只在触及阈值那一条里记
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

/// 只读系统电源状态并在变化时通知外部, 不知道阈值也不知道防睡眠
/// IOKit 的 C 接口和内存管理约定全部收在这里, 不漏到调用方
@MainActor
final class PowerSourceMonitor {
    private(set) var reading = BatteryReading.unreadable

    private var onChange: (() -> Void)?
    private var runLoopSource: CFRunLoopSource?
    private var wakeObserver: NSObjectProtocol?
    private var pollTask: Task<Void, Never>?
    /// 重入守卫; 不能拿 runLoopSource 顶替: 注册失败时它是 nil, 而唤醒观察者已经装上了
    private var isMonitoring = false
    /// 这台机器确认装着内置电池
    /// 硬件不会中途消失, 所以见过之后再读到空列表只能是枚举缺口, 不能当成台式机
    private var hasSeenBattery = false

    /// 回调里持有的是 unretained 指针, 停止监听必须显式做, 由持有者在 stop 时调用
    /// 不放 deinit: Swift 6 的 nonisolated deinit 碰不了这两个非 Sendable 属性
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
        // 不走 refresh: 它按变化过滤, 而初始值就是 unreadable, 首读失败会被静默吞掉
        // 那之后低电量判定一直冻着, 却只在恢复时留下一条没有配对失败行的日志
        let initialReading = currentReading()
        if initialReading == .unreadable {
            AppLog.keepAlive.error("电源监听读取失败: stage=start")
        }
        reading = initialReading

        // 装在 source 之前: 注册失败时它已经就位, 与那条路的轮询兜底叠着用
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
            // action= 记的是降级后还剩什么, 否则只知道注册失败, 不知道保护是不是全没了
            AppLog.keepAlive.error(
                "电源监听注册失败: stage=createRunLoopSource; action=poll"
            )
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

        // 降级与恢复成对记: 判定在整个 unreadable 窗口里被冻结, 只记进不记出就看不出冻了多久
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
    /// 只靠唤醒补读不够: 防睡眠正在生效的机器按定义就不会睡, 那条通知永远不来
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

    /// 电量取 Current/Max 的比例而不是直接用 Current
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
            // 只有 Battery Power 才是真的在耗电池
            // 不能用 Is Charging: 接电但停充时它也是 false, 而那时电量并没有在掉
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
        // 见过电池就只能算这一次读不到, 交给调用方维持上一次判定, 否则一次缺口会当场撤掉保护
        return hasSeenBattery ? .unreadable : .unavailable
    }

    private static let pollIntervalSeconds = 60
}
