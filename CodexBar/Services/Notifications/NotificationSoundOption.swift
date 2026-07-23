import AppKit
import Foundation
import UserNotifications

/// CodexBar 可用于系统通知的声音, 自定义声音随 App 打包, 确保通知中心能够解析文件名
enum NotificationSoundOption: String, Identifiable {
    case silent
    case systemDefault
    case basso
    case blow
    case bottle
    case frog
    case funk
    case glass
    case hero
    case morse
    case ping
    case pop
    case purr
    case sosumi
    case submarine
    case tink
    case antic
    case cheers
    case droplet
    case handoff
    case milestone
    case passage
    case portal
    case rattle
    case rebound
    case slide
    case receivedMessage
    case acknowledgementExclamation
    case acknowledgementHaHa
    case acknowledgementHeart
    case acknowledgementQuestionMark
    case acknowledgementThumbsDown
    case acknowledgementThumbsUp

    static let classicSounds: [NotificationSoundOption] = [
        .basso, .blow, .bottle, .frog, .funk, .glass, .hero,
        .morse, .ping, .pop, .purr, .sosumi, .submarine, .tink
    ]

    static let modernSounds: [NotificationSoundOption] = [
        .antic, .cheers, .droplet, .handoff, .milestone, .passage,
        .portal, .rattle, .rebound, .slide, .receivedMessage,
        .acknowledgementExclamation, .acknowledgementHaHa,
        .acknowledgementHeart, .acknowledgementQuestionMark,
        .acknowledgementThumbsDown, .acknowledgementThumbsUp
    ]

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .silent:
            "静音"
        case .systemDefault:
            "系统提示音"
        case .basso:
            "Basso"
        case .blow:
            "Blow"
        case .bottle:
            "Bottle"
        case .frog:
            "Frog"
        case .funk:
            "Funk"
        case .glass:
            "Glass"
        case .hero:
            "Hero"
        case .morse:
            "Morse"
        case .ping:
            "Ping"
        case .pop:
            "Pop"
        case .purr:
            "Purr"
        case .sosumi:
            "Sosumi"
        case .submarine:
            "Submarine"
        case .tink:
            "Tink"
        case .antic:
            "Antic"
        case .cheers:
            "Cheers"
        case .droplet:
            "Droplet"
        case .handoff:
            "Handoff"
        case .milestone:
            "Milestone"
        case .passage:
            "Passage"
        case .portal:
            "Portal"
        case .rattle:
            "Rattle"
        case .rebound:
            "Rebound"
        case .slide:
            "Slide"
        case .receivedMessage:
            "Received Message"
        case .acknowledgementExclamation:
            "Exclamation"
        case .acknowledgementHaHa:
            "Ha Ha"
        case .acknowledgementHeart:
            "Heart"
        case .acknowledgementQuestionMark:
            "Question Mark"
        case .acknowledgementThumbsDown:
            "Thumbs Down"
        case .acknowledgementThumbsUp:
            "Thumbs Up"
        }
    }

    var notificationSound: UNNotificationSound? {
        guard self != .silent else {
            return nil
        }

        guard let resourceFileName else {
            return .default
        }

        return UNNotificationSound(
            named: UNNotificationSoundName(rawValue: resourceFileName)
        )
    }

    func makePreviewSound(bundle: Bundle = .main) -> NSSound? {
        guard let resourceBaseName,
              let url = bundle.url(forResource: resourceBaseName, withExtension: Self.resourceExtension) else {
            return nil
        }

        return NSSound(contentsOf: url, byReference: true)
    }

    private var resourceBaseName: String? {
        resourceName.map { "CodexBar-\($0)" }
    }

    private var resourceName: String? {
        switch self {
        case .silent, .systemDefault:
            nil
        case .receivedMessage:
            "ReceivedMessage"
        case .acknowledgementExclamation:
            "Acknowledgement-Exclamation"
        case .acknowledgementHaHa:
            "Acknowledgement-HaHa"
        case .acknowledgementHeart:
            "Acknowledgement-Heart"
        case .acknowledgementQuestionMark:
            "Acknowledgement-QuestionMark"
        case .acknowledgementThumbsDown:
            "Acknowledgement-ThumbsDown"
        case .acknowledgementThumbsUp:
            "Acknowledgement-ThumbsUp"
        default:
            title
        }
    }

    private var resourceFileName: String? {
        resourceBaseName.map { "\($0).\(Self.resourceExtension)" }
    }

    private static let resourceExtension = "wav"
}
