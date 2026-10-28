import Foundation
import SwiftTreeSitter
import TreeSitterBash

/// 只生成实时展示摘要, 不展开变量或执行命令
nonisolated enum ActivityCommandParser {
    static func summarize(_ commands: [String]) -> ActivityItem.CommandSummary? {
        guard !commands.isEmpty, commands.count <= 32,
              commands.reduce(0, { $0 + $1.utf8.count }) <= 128 * 1024,
              var scan = Scan() else { return nil }
        var result: ActivityItem.CommandSummary?
        for command in commands {
            guard let summary = scan.parse(command) else { return nil }
            result = result?.appending(summary) ?? summary
        }
        return result
    }

    private struct Scan {
        let parser: Parser
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(50))
        var remainingNodes = 8192

        init?() {
            parser = Parser()
            guard (try? parser.setLanguage(Language(language: tree_sitter_bash()))) != nil else { return nil }
            parser.timeout = 0.01
        }

        mutating func parse(_ source: String, depth: Int = 0) -> ActivityItem.CommandSummary? {
            guard depth < 4, ContinuousClock.now < deadline,
                  let tree = parser.parse(source), let root = tree.rootNode, !root.hasError else { return nil }
            var pending = [root]
            var result: ActivityItem.CommandSummary?
            while let node = pending.popLast() {
                guard consumeBudget() else { return nil }
                switch node.nodeType {
                case "program", "list", "pipeline":
                    pending.append(contentsOf: children(node).reversed())
                case "redirected_statement":
                    guard !containsDynamicExecution(node), let body = node.child(byFieldName: "body") else { return nil }
                    pending.append(body)
                case "command":
                    guard !containsDynamicExecution(node), let nameNode = node.child(byFieldName: "name")?.namedChild(at: 0),
                          let name = literal(nameNode, source: source) else { return nil }
                    let arguments = (0 ..< node.childCount).compactMap { index -> Node? in
                        node.fieldNameForChild(at: index) == "argument" ? node.child(at: index) : nil
                    }.map { literal($0, source: source) }
                    guard let summary = summarizeInvocation([name] + arguments, depth: depth) else { return nil }
                    result = result?.appending(summary) ?? summary
                case "variable_assignment":
                    guard !containsDynamicExecution(node) else { return nil }
                case "comment": break
                default: return nil
                }
            }
            return result
        }

        private mutating func consumeBudget() -> Bool {
            remainingNodes -= 1
            return remainingNodes >= 0 && ContinuousClock.now < deadline
        }

        private mutating func containsDynamicExecution(_ root: Node) -> Bool {
            var pending = [root]
            while let node = pending.popLast() {
                guard consumeBudget() else { return true }
                if ["command_substitution", "process_substitution"].contains(node.nodeType) {
                    return true
                }
                pending.append(contentsOf: children(node))
            }
            return false
        }

        private func children(_ node: Node) -> [Node] {
            (0 ..< node.namedChildCount).compactMap { node.namedChild(at: $0) }
        }

        private mutating func summarizeInvocation(_ words: [String?], depth: Int) -> ActivityItem.CommandSummary? {
            guard depth < 4, let rawName = words.first ?? nil, let name = toolName(rawName) else { return nil }
            let arguments = Array(words.dropFirst())
            switch name {
            case "env":
                guard let index = envCommandIndex(arguments), arguments.indices.contains(index) else { return .tool(name) }
                return summarizeInvocation(Array(arguments[index...]), depth: depth + 1)
            case "xcrun":
                guard let index = xcrunCommandIndex(arguments), arguments.indices.contains(index) else { return .tool(name) }
                return summarizeInvocation(Array(arguments[index...]), depth: depth + 1)
            case "bash", "sh", "zsh":
                for (index, argument) in arguments.enumerated() {
                    guard let argument else { return nil }
                    if ["-c", "-lc", "-cl"].contains(argument) {
                        guard arguments.indices.contains(index + 1), let script = arguments[index + 1] else { return nil }
                        return parse(script, depth: depth + 1)
                    }
                    if !["-l", "-e", "-u", "-x", "-f", "--noprofile", "--norc"].contains(argument) {
                        break
                    }
                }
                return .tool(name)
            default: return .tool(name)
            }
        }

        private func envCommandIndex(_ arguments: [String?]) -> Int? {
            var index = 0
            while index < arguments.count {
                guard let argument = arguments[index] else { return index }
                if argument == "--" {
                    return index + 1
                }
                if ["-i", "--ignore-environment", "-"].contains(argument) {
                    index += 1
                } else if ["-u", "--unset"].contains(argument) {
                    guard arguments.indices.contains(index + 1), arguments[index + 1] != nil else { return nil }
                    index += 2
                } else if argument.hasPrefix("--unset=") || (argument.hasPrefix("-u") && argument.count > 2) || isAssignment(argument) {
                    index += 1
                } else {
                    return argument.hasPrefix("-") ? nil : index
                }
            }
            return index
        }

        private func xcrunCommandIndex(_ arguments: [String?]) -> Int? {
            var index = 0
            while index < arguments.count {
                guard let argument = arguments[index] else { return index }
                if argument == "--" {
                    return index + 1
                }
                if ["-r", "--run", "-v", "--verbose", "-l", "--log", "-n", "--no-cache", "-k", "--kill-cache"].contains(argument) {
                    index += 1
                } else if ["--sdk", "-sdk", "--toolchain", "-toolchain"].contains(argument) {
                    guard arguments.indices.contains(index + 1), arguments[index + 1] != nil else { return nil }
                    index += 2
                } else {
                    return argument.hasPrefix("-") ? nil : index
                }
            }
            return index
        }
    }

    private static func toolName(_ value: String) -> String? {
        let name = (value as NSString).lastPathComponent
        guard !name.isEmpty, ![".", "..", "/"].contains(name), name.count <= 160,
              name.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil else { return nil }
        return name
    }

    private static func isAssignment(_ value: String) -> Bool {
        guard let equal = value.firstIndex(of: "=") else { return false }
        let name = value[..<equal]
        return !name.isEmpty && name.utf8.enumerated().allSatisfy { index, byte in
            byte == 95 || (65 ... 90).contains(byte) || (97 ... 122).contains(byte) || (index > 0 && (48 ... 57).contains(byte))
        }
    }

    private static func literal(_ node: Node, source: String, depth: Int = 0) -> String? {
        guard depth < 16, let range = Range(node.range, in: source) else { return nil }
        let text = String(source[range])
        switch node.nodeType {
        case "word", "number":
            return unescape(text, quoted: false)
        case "raw_string":
            guard text.hasPrefix("'"), text.hasSuffix("'"), text.count >= 2 else { return nil }
            return String(text.dropFirst().dropLast())
        case "string":
            guard (0 ..< node.namedChildCount).allSatisfy({ node.namedChild(at: $0)?.nodeType == "string_content" }),
                  text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 else { return nil }
            return unescape(String(text.dropFirst().dropLast()), quoted: true)
        case "concatenation":
            var result = ""
            for index in 0 ..< node.namedChildCount {
                guard let child = node.namedChild(at: index), let part = literal(child, source: source, depth: depth + 1) else { return nil }
                result += part
            }
            return result
        default: return nil
        }
    }

    private static func unescape(_ text: String, quoted: Bool) -> String? {
        var result = ""
        var characters = text.makeIterator()
        while let character = characters.next() {
            if character == "\\" {
                guard let escaped = characters.next() else { return nil }
                if escaped == "\n" {
                    continue
                }
                if quoted, !"$`\"\\".contains(escaped) {
                    result.append("\\")
                }
                result.append(escaped)
            } else {
                if !quoted, "{}*?[]~^#$`".contains(character) || (result.isEmpty && character == "=") {
                    return nil
                }
                result.append(character)
            }
        }
        return result
    }
}
