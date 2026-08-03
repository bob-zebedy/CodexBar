import AppKit
import Foundation
import os
import UserNotifications

/// CodexBar 可用于系统通知的声音, 系统提示音按本机声音目录实时枚举, 其余随 App 打包
/// `id` 是落在 UserDefaults 里的持久化值, 系统提示音取文件名小写形式, 与旧版本的枚举值天然对齐
struct NotificationSoundOption: Identifiable, Hashable {
    let id: String
    let title: String
    private let source: SoundSource

    var localizedTitle: String {
        switch source {
        case .silent:
            String(localized: "notification.sound.silent", defaultValue: "静音")
        case .systemDefault:
            String(localized: "notification.sound.default", defaultValue: "默认")
        case .system, .bundled:
            title
        }
    }

    static let silent = NotificationSoundOption(id: "silent", title: "静音", source: .silent)
    static let systemDefault = NotificationSoundOption(
        id: "systemDefault",
        title: "默认",
        source: .systemDefault
    )

    /// 分组的唯一登记点, 菜单渲染与 id 解析都从这里派生, 新增一组声音只改这一处
    static let categories: [Category] = [
        Category(title: "System", sounds: systemSounds),
        Category(title: "Modern", sounds: modernSounds),
        Category(title: "Material", sounds: materialSounds)
    ]

    /// 持久化值可能指向已经不存在的声音, 例如换了机器或者用户删掉了自定义音, 这时交给调用方回落
    static func option(forID id: String) -> NotificationSoundOption? {
        if id == silent.id {
            return silent
        }

        if id == systemDefault.id {
            return systemDefault
        }

        return categories.lazy.flatMap(\.sounds).first { $0.id == id }
    }

    /// 通知中心解析不到声音文件时是静音而不是回落默认音, 用户只会发现通知不响却查不出原因
    /// 所以这里先确认文件在位, 缺失就主动降级, 宁可换个声音也不要静默失声
    var notificationSound: UNNotificationSound? {
        switch source {
        case .silent:
            nil
        case .systemDefault:
            .default
        case let .system(url):
            if FileManager.default.fileExists(atPath: url.path) {
                UNNotificationSound(named: UNNotificationSoundName(rawValue: url.lastPathComponent))
            } else {
                Self.degraded(id: id, source: "system")
            }
        case let .bundled(name):
            if Bundle.main.url(forResource: name, withExtension: Self.bundledExtension) != nil {
                UNNotificationSound(
                    named: UNNotificationSoundName(rawValue: "\(name).\(Self.bundledExtension)")
                )
            } else {
                Self.degraded(id: id, source: "bundled")
            }
        }
    }

    /// 降级本身没有用户可见的痕迹, 通知照常弹出只是换了个声音, 这条日志是事后唯一的线索
    /// 记 id 是定位所需, 它是选项标识而不是文件路径, 用户自定义音也只会暴露文件名本身
    private static func degraded(id: String, source: String) -> UNNotificationSound {
        AppLog.notification.notice(
            "通知音已降级: id=\(id, privacy: .public); source=\(source, privacy: .public); reason=missing; action=default"
        )
        return .default
    }

    /// 静音本就没有声音, 默认音由通知中心内部决定且不暴露文件, 两者都没有可试听的对象
    /// 拿系统警告声冒充默认音会误导, 它和通知中心默认音是两个独立设置
    var isPreviewable: Bool {
        switch source {
        case .silent, .systemDefault:
            false
        case .system, .bundled:
            true
        }
    }

    func makePreviewSound(bundle: Bundle = .main) -> NSSound? {
        switch source {
        case .silent, .systemDefault:
            nil
        case let .system(url):
            NSSound(contentsOf: url, byReference: true)
        case let .bundled(name):
            bundle.url(forResource: name, withExtension: Self.bundledExtension)
                .flatMap { NSSound(contentsOf: $0, byReference: true) }
        }
    }

    static func == (lhs: NotificationSoundOption, rhs: NotificationSoundOption) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    struct Category: Identifiable {
        let title: String
        let sounds: [NotificationSoundOption]

        var id: String {
            title
        }
    }

    /// 系统提示音由声音目录提供, 枚举时就定下具体文件, 通知与预览都用它而不再重新搜索
    /// 打包的声音出自私有框架或第三方资源包, 不在系统声音搜索路径内, 只能按 bundle 资源名解析
    private enum SoundSource: Hashable {
        case silent
        case systemDefault
        case system(URL)
        case bundled(String)
    }

    /// Apple 现代提示音, 取自 ToneLibrary 框架
    private static let modernSounds: [NotificationSoundOption] = [
        bundled(id: "antic", title: "Antic"),
        bundled(id: "cheers", title: "Cheers"),
        bundled(id: "droplet", title: "Droplet"),
        bundled(id: "handoff", title: "Handoff"),
        bundled(id: "milestone", title: "Milestone"),
        bundled(id: "passage", title: "Passage"),
        bundled(id: "portal", title: "Portal"),
        bundled(id: "rattle", title: "Rattle"),
        bundled(id: "rebound", title: "Rebound"),
        bundled(id: "slide", title: "Slide"),
        bundled(id: "receivedMessage", title: "Received Message", resource: "ReceivedMessage"),
        bundled(id: "exclamation", title: "Exclamation"),
        bundled(id: "haHa", title: "Ha Ha", resource: "HaHa"),
        bundled(id: "heart", title: "Heart"),
        bundled(id: "questionMark", title: "Question Mark", resource: "QuestionMark"),
        bundled(id: "thumbsDown", title: "Thumbs Down", resource: "ThumbsDown"),
        bundled(id: "thumbsUp", title: "Thumbs Up", resource: "ThumbsUp")
    ]

    /// Google Material Design 提示音, 取自 material_product_sounds 的 01 Hero 与 02 Alerts and Notifications
    private static let materialSounds: [NotificationSoundOption] = [
        bundled(id: "materialAlert", title: "Alert", resource: "Alert"),
        bundled(id: "materialAlertIntense", title: "Alert Intense", resource: "AlertIntense"),
        bundled(id: "materialSimple1", title: "Simple 1", resource: "Simple-1"),
        bundled(id: "materialSimple2", title: "Simple 2", resource: "Simple-2"),
        bundled(id: "materialDecorative1", title: "Decorative 1", resource: "Decorative-1"),
        bundled(id: "materialDecorative2", title: "Decorative 2", resource: "Decorative-2"),
        bundled(id: "materialIntense", title: "Intense", resource: "Intense"),
        bundled(id: "materialAmbient", title: "Ambient", resource: "Ambient"),
        bundled(id: "materialCelebration1", title: "Celebration 1", resource: "Celebration-1"),
        bundled(id: "materialCelebration2", title: "Celebration 2", resource: "Celebration-2"),
        bundled(id: "materialCelebration3", title: "Celebration 3", resource: "Celebration-3"),
        bundled(id: "materialFanfare1", title: "Fanfare 1", resource: "Fanfare-1"),
        bundled(id: "materialFanfare2", title: "Fanfare 2", resource: "Fanfare-2"),
        bundled(id: "materialFanfare3", title: "Fanfare 3", resource: "Fanfare-3")
    ]

    /// 本机声音目录里实际存在的提示音, 不同机器上内容可以不同
    /// 只在首次访问时扫一次, 运行期间新放进声音目录的文件要重启 App 才会出现
    private static let systemSounds: [NotificationSoundOption] = loadSystemSounds()

    /// 打包声音的 id 先占位, 本机同名文件不再生成第二个同 id 的选项
    /// 否则用户在 System 组里选中的声音, 下次读取会被解析成打包组里那个同名资源
    private static let reservedIDs: Set<String> = Set((modernSounds + materialSounds).map(\.id))

    private static func bundled(
        id: String,
        title: String,
        resource: String? = nil
    ) -> NotificationSoundOption {
        NotificationSoundOption(
            id: id,
            title: title,
            source: .bundled("CodexBar-\(resource ?? title)")
        )
    }

    /// 同名文件以靠前的目录为准, 与系统解析声音的顺序一致
    private static func loadSystemSounds() -> [NotificationSoundOption] {
        var seen = reservedIDs
        var sounds: [NotificationSoundOption] = []

        for directory in systemSoundDirectories {
            let directoryURL = URL(fileURLWithPath: directory)
            let fileNames = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            for fileName in fileNames {
                let name = fileName as NSString
                guard supportedExtensions.contains(name.pathExtension.lowercased()) else {
                    continue
                }

                let title = name.deletingPathExtension
                let id = title.lowercased()
                guard !title.isEmpty, seen.insert(id).inserted else {
                    continue
                }

                sounds.append(
                    NotificationSoundOption(
                        id: id,
                        title: title,
                        source: .system(directoryURL.appendingPathComponent(fileName))
                    )
                )
            }
        }

        return sounds.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    /// 声音按这组目录逐级解析, 用户可以在靠前的目录放同名文件覆盖系统音
    /// 标准搜索路径里还有 `/Network/Library/Sounds`, 这里不查它, 探测自动挂载点可能拖住调用方
    private static let systemSoundDirectories = [
        "\(NSHomeDirectory())/Library/Sounds",
        "/Library/Sounds",
        "/System/Library/Sounds"
    ]

    private static let supportedExtensions: Set<String> = ["aiff", "aif", "wav", "caf"]
    private static let bundledExtension = "wav"
}
