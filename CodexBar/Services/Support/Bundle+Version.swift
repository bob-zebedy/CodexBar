import Foundation

nonisolated extension Bundle {
    var shortVersionString: String? {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// 版本文案包含构建号; 版本缺失时回退 `--`
    var displayVersionLabel: String {
        Self.displayVersionLabel(
            version: shortVersionString,
            build: object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

    static func displayVersionLabel(version: String?, build: String?) -> String {
        guard let version else { return "--" }
        let label = "v\(version)"
        guard let build, !build.isEmpty else { return label }
        return "\(label) (Build \(build))"
    }
}
