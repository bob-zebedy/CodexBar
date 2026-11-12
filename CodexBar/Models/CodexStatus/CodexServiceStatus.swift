import Foundation

nonisolated struct CodexServiceStatus: Equatable, Sendable {
    enum Level: String, CaseIterable, Sendable {
        case operational
        case degradedPerformance = "degraded_performance"
        case partialOutage = "partial_outage"
        case fullOutage = "full_outage"
        case underMaintenance = "under_maintenance"

        /// 维护不表示故障, 与故障同时存在时优先展示故障级别
        fileprivate var priority: Int {
            switch self {
            case .operational: 0
            case .underMaintenance: 1
            case .degradedPerformance: 2
            case .partialOutage: 3
            case .fullOutage: 4
            }
        }
    }

    static let operational = Self(level: .operational, componentNames: [])
    let level: Level
    let componentNames: [String]

    init(level: Level, componentNames: [String]) {
        self.level = level
        self.componentNames = componentNames
    }

    init(data: Data) throws {
        let summary = try JSONDecoder().decode(Response.self, from: data).summary
        let groups = summary.structure.items.compactMap(\.group).filter { $0.name == "Codex" && $0.hidden != true }
        let groupIDs = Set(groups.flatMap(\.components).filter { $0.hidden != true }.map(\.componentID))
        let componentIDs = Set(summary.components.map(\.id))
        guard !groupIDs.isEmpty, groupIDs.isSubset(of: componentIDs) else {
            throw ParseError.missingComponents
        }

        // Desktop 的 Codex 组件位于 ChatGPT 分组, 不能只检查 Codex 分组
        let codexIDs = groupIDs.union(summary.components.filter { $0.name.hasPrefix("Codex ") }.map(\.id))
        var highestLevel = Level.operational
        var highestIDs = Set<String>()
        for component in summary.affectedComponents where codexIDs.contains(component.componentID) {
            guard let level = Level(rawValue: component.status) else { throw ParseError.unknownStatus }
            if level.priority > highestLevel.priority {
                highestLevel = level
                highestIDs.removeAll()
            }
            if level == highestLevel, level != .operational {
                highestIDs.insert(component.componentID)
            }
        }
        self.init(level: highestLevel, componentNames: summary.components.compactMap { component in
            highestIDs.contains(component.id) ? component.name : nil
        })
    }

    enum ParseError: Error {
        case missingComponents
        case unknownStatus
    }
}

private nonisolated struct Response: Decodable {
    let summary: Summary
}

private nonisolated struct Summary: Decodable {
    let components: [ResponseComponent]
    let affectedComponents: [AffectedComponent]
    let structure: Structure

    enum CodingKeys: String, CodingKey {
        case components, structure
        case affectedComponents = "affected_components"
    }
}

private nonisolated struct ResponseComponent: Decodable {
    let id: String
    let name: String
}

private nonisolated struct AffectedComponent: Decodable {
    let componentID: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case componentID = "component_id"
        case status
    }
}

private nonisolated struct Structure: Decodable {
    let items: [StructureItem]
}

private nonisolated struct StructureItem: Decodable {
    let group: ServiceGroup?
}

private nonisolated struct ServiceGroup: Decodable {
    let name: String
    let hidden: Bool?
    let components: [ComponentReference]
}

private nonisolated struct ComponentReference: Decodable {
    let componentID: String
    let hidden: Bool?

    enum CodingKeys: String, CodingKey {
        case componentID = "component_id"
        case hidden
    }
}
