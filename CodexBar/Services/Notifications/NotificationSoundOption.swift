import AppKit
import Foundation
import os
import UserNotifications

/// 系统提示音首次使用时从 macOS 系统声音目录加载并缓存, 其余声音随 App 打包
/// id 用于持久化, 系统提示音取不含扩展名的文件名小写形式
struct NotificationSoundOption: Identifiable, Hashable {
    let id: String
    let localizedTitle: String
    private let source: SoundSource

    static let silent = NotificationSoundOption(
        id: "silent",
        localizedTitle: String(localized: "notification.sound.silent"),
        source: .silent
    )
    static let systemDefault = NotificationSoundOption(
        id: "systemDefault",
        localizedTitle: String(localized: "notification.sound.default"),
        source: .systemDefault
    )

    /// 菜单分组与持久化 id 的解析共用同一份声音列表
    static let categories: [Category] = [
        Category(title: "System", sounds: systemSounds),
        Category(title: "Modern", sounds: modernSounds),
        Category(title: "Material", sounds: materialSounds)
    ]

    /// 持久化值可能指向已移除或不再支持的声音, 这时交给调用方回落
    static func option(forID id: String) -> NotificationSoundOption? {
        if id == silent.id {
            return silent
        }

        if id == systemDefault.id {
            return systemDefault
        }

        return categories.lazy.flatMap(\.sounds).first { $0.id == id }
    }

    /// 声音列表会缓存, 文件可能在加载后被删除, 发送通知前检查并显式回退默认音
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

    /// 记录回退原因以便排查声音变化, 仅记录选项 id 和来源, 不记录完整文件路径
    private static func degraded(id: String, source: String) -> UNNotificationSound {
        let details = LogFields.joined(
            "id=\(id)",
            "source=\(source)",
            "reason=missing",
            "action=default"
        )
        AppLog.notification.notice("通知音已降级: \(details, privacy: .public)")
        return .default
    }

    /// 默认音由通知中心决定, 没有对应的试听资源, 不使用系统警告声代替
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

    /// 系统提示音保留文件 URL 供校验和试听, 发送通知时只将文件名交给系统解析
    /// 打包声音按 bundle 资源名定位, 不依赖本机声音目录
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

    /// 系统声音列表只在首次访问时加载并缓存
    private static let systemSounds: [NotificationSoundOption] = loadSystemSounds()

    /// 打包声音的 id 先占位, 系统同名文件不再生成第二个同 id 的选项
    /// 否则用户在 System 组里选中的声音, 下次读取会被解析成打包组里那个同名资源
    private static let reservedIDs: Set<String> = Set((modernSounds + materialSounds).map(\.id))

    private static func bundled(
        id: String,
        title: String,
        resource: String? = nil
    ) -> NotificationSoundOption {
        NotificationSoundOption(
            id: id,
            localizedTitle: title,
            source: .bundled("CodexBar-\(resource ?? title)")
        )
    }

    /// 同名声音只生成一个选项
    private static func loadSystemSounds() -> [NotificationSoundOption] {
        var seen = reservedIDs
        var sounds: [NotificationSoundOption] = []

        let directoryURL = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)
        let fileNames = (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? []
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
                    localizedTitle: title,
                    source: .system(directoryURL.appendingPathComponent(fileName))
                )
            )
        }

        return sounds.sorted {
            $0.localizedTitle.localizedStandardCompare($1.localizedTitle) == .orderedAscending
        }
    }

    private static let supportedExtensions: Set<String> = ["aiff", "aif", "wav", "caf"]
    private static let bundledExtension = "wav"
}
