import Foundation

enum TOMLError: Error { case malformed, unsupportedLayout }

indirect enum TOMLValue {
    case string(String), array([TOMLValue]), table([String: TOMLValue]), scalar(String)

    var string: String? { if case .string(let value) = self { value } else { nil } }
}

struct TOMLStatement {
    let start: Int
    var end: Int
    let table: [String]
    let key: [String]?
    let value: TOMLValue?
    let valueRange: Range<Int>?
    let arrayTable: Bool
}

struct TOMLDocument {
    let characters: [Character]
    let statements: [TOMLStatement]

    init(_ data: Data?) throws {
        guard let text = String(data: data ?? Data(), encoding: .utf8) else { throw TOMLError.malformed }
        characters = Array(text)
        var parser = TOMLParser(characters: characters)
        statements = try parser.parse()
    }

    func entry(definition: AgentDefinition, name: String) throws -> ServerEntry? {
        let path = [definition.config.serversKey, name]
        let keys = definition.entry
        try validateLayout(path: path, keys: keys)
        guard statements.contains(where: { $0.table.starts(with: path) }) else { return nil }
        let fields = statements.filter { $0.table == path && $0.key != nil }
        func field(_ key: String) -> TOMLValue? { fields.first { $0.key == [key] }?.value }
        let command = field(keys.commandKey)
        guard command == nil || command?.string != nil else { throw TOMLError.malformed }
        var args: [String] = []
        if let value = field(keys.argsKey) {
            guard case .array(let values) = value else { throw TOMLError.malformed }
            args = try values.map { guard let value = $0.string else { throw TOMLError.malformed }; return value }
        }
        var env: [String: String] = [:]
        for statement in statements where statement.table == path + [keys.envKey] && statement.key != nil {
            guard let key = statement.key?.first, let value = statement.value?.string else { throw TOMLError.malformed }
            env[key] = value
        }
        return ServerEntry(command: command?.string ?? "", args: args, env: env)
    }

    func updating(definition: AgentDefinition, name: String, entry: ServerEntry?) throws -> Data {
        let path = [definition.config.serversKey, name]
        let keys = definition.entry
        try validateLayout(path: path, keys: keys)
        let headers = statements.indices.filter { statements[$0].key == nil }
        let sections = headers.enumerated().compactMap { index, start -> (range: Range<Int>, table: [String], statements: [TOMLStatement])? in
            let header = statements[start]
            guard header.table.starts(with: path) else { return nil }
            let last = index + 1 < headers.count ? headers[index + 1] - 1 : statements.count - 1
            return (header.start..<statements[last].end, header.table, Array(statements[start...last]))
        }
        let envPath = path + [keys.envKey]
        var edits: [(range: Range<Int>, text: String)] = []
        if let entry {
            let hasEnv = sections.contains { $0.table == envPath }
            var fields = [(keys.commandKey, Self.quote(entry.command)), (keys.argsKey, "[\(entry.args.map(Self.quote).joined(separator: ", "))]")]
            if let key = keys.typeKey, let type = keys.type { fields.append((key, Self.quote(type))) }
            if let main = sections.first(where: { $0.table == path }) {
                var insertion = ""
                for (key, value) in fields {
                    if let range = main.statements.first(where: { $0.key == [key] })?.valueRange {
                        edits.append((range, value))
                    } else { insertion += "\(Self.key(key)) = \(value)\n" }
                }
                if !hasEnv && !entry.env.isEmpty { insertion += "\n" + renderEnvironment(entry.env, path: envPath) }
                if !insertion.isEmpty {
                    let end = main.range.upperBound
                    if end > 0 && !characters[end - 1].isNewline { insertion = "\n" + insertion }
                    edits.append((end..<end, insertion))
                }
            } else if let first = sections.first {
                let main = ServerEntry(command: entry.command, args: entry.args, env: hasEnv ? [:] : entry.env)
                edits.append((first.range.lowerBound..<first.range.lowerBound, render(main, definition: definition, path: path)))
            }
            for section in sections where section.table.starts(with: envPath) {
                edits.append((section.range, section.table == envPath ? renderEnvironment(entry.env, path: envPath) : ""))
            }
        } else { edits = sections.map { ($0.range, "") } }
        var output = ""
        var cursor = 0
        for edit in edits.sorted(by: { $0.range.lowerBound == $1.range.lowerBound ? $0.range.upperBound < $1.range.upperBound : $0.range.lowerBound < $1.range.lowerBound }) {
            output += String(characters[cursor..<edit.range.lowerBound]) + edit.text
            cursor = edit.range.upperBound
        }
        output += String(characters[cursor...])
        if sections.isEmpty, let entry {
            if !output.isEmpty {
                if !output.hasSuffix("\n") { output += "\n" }
                if !output.hasSuffix("\n\n") { output += "\n" }
            }
            output += render(entry, definition: definition, path: path)
        }
        return Data(output.utf8)
    }

    private func validateLayout(path: [String], keys: AgentDefinition.Entry) throws {
        let ownedKeys = [keys.commandKey, keys.argsKey, keys.envKey] + (keys.typeKey.map { [$0] } ?? [])
        for statement in statements {
            if statement.arrayTable && (path.starts(with: statement.table) || statement.table.starts(with: path + [keys.envKey])) { throw TOMLError.unsupportedLayout }
            guard let key = statement.key else { continue }
            let full = statement.table + key
            if path.starts(with: full) { throw TOMLError.unsupportedLayout }
            if full.starts(with: path) {
                if !statement.table.starts(with: path) { throw TOMLError.unsupportedLayout }
                let ownedField = full.dropFirst(path.count).first.map { ownedKeys.contains($0) } == true
                if ownedField && key.count != 1 { throw TOMLError.unsupportedLayout }
                if statement.table == path && key == [keys.envKey] { throw TOMLError.unsupportedLayout }
            }
        }
    }

    private func render(_ entry: ServerEntry, definition: AgentDefinition, path: [String]) -> String {
        let table = path.map(Self.key).joined(separator: ".")
        let keys = definition.entry
        var text = "[\(table)]\n\(Self.key(keys.commandKey)) = \(Self.quote(entry.command))\n"
        text += "\(Self.key(keys.argsKey)) = [\(entry.args.map(Self.quote).joined(separator: ", "))]\n"
        if !entry.env.isEmpty {
            text += "\n" + renderEnvironment(entry.env, path: path + [keys.envKey])
        }
        return text
    }

    private func renderEnvironment(_ env: [String: String], path: [String]) -> String {
        guard !env.isEmpty else { return "" }
        var text = "[\(path.map(Self.key).joined(separator: "."))]\n"
        for key in env.keys.sorted() { text += "\(Self.key(key)) = \(Self.quote(env[key]!))\n" }
        return text
    }

    private static func key(_ value: String) -> String {
        value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil ? value : quote(value)
    }

    private static func quote(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: result += "\\\""
            case 0x5c: result += "\\\\"
            case 0..<0x20, 0x7f: result += String(format: "\\u%04X", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}

private struct TOMLParser {
    let characters: [Character]
    var index = 0

    var current: Character? { index < characters.count ? characters[index] : nil }
    mutating func take(_ char: Character) -> Bool {
        guard current == char else { return false }
        index += 1
        return true
    }

    mutating func horizontal() { while current == " " || current == "\t" { index += 1 } }
    mutating func comment() { if current == "#" { while let c = current, !c.isNewline { index += 1 } } }
    mutating func whitespace() {
        while let c = current {
            if c == " " || c == "\t" || c.isNewline { index += 1 }
            else if c == "#" { comment() }
            else { break }
        }
    }

    mutating func parse() throws -> [TOMLStatement] {
        var result: [TOMLStatement] = []
        var table: [String] = []
        var tables: Set<[String]> = []
        var values: Set<[String]> = []
        var arrayPaths: [[String]] = []
        while true {
            whitespace()
            guard current != nil else { return result }
            let start = index
            if take("[") {
                let array = take("[")
                table = try path()
                guard take("]"), !array || take("]") else { throw TOMLError.malformed }
                if array { arrayPaths.append(table) }
                let underArray = arrayPaths.contains { table.starts(with: $0) }
                if !underArray && (!tables.insert(table).inserted || values.contains(where: { table.starts(with: $0) })) { throw TOMLError.malformed }
                result.append(TOMLStatement(start: start, end: index, table: table, key: nil, value: nil, valueRange: nil, arrayTable: array))
            } else {
                let key = try path()
                guard take("=") else { throw TOMLError.malformed }
                horizontal()
                let valueStart = index
                let value = try value()
                let valueRange = valueStart..<index
                let full = table + key
                let underArray = arrayPaths.contains { full.starts(with: $0) }
                if !underArray {
                    guard !values.contains(where: { full.starts(with: $0) || $0.starts(with: full) }),
                          !tables.contains(where: { $0.starts(with: full) }) else { throw TOMLError.malformed }
                    values.insert(full)
                }
                result.append(TOMLStatement(start: start, end: index, table: table, key: key, value: value, valueRange: valueRange, arrayTable: false))
            }
            horizontal()
            comment()
            guard current == nil || current?.isNewline == true else { throw TOMLError.malformed }
            if current?.isNewline == true { index += 1 }
            result[result.count - 1].end = index
        }
    }

    mutating func path() throws -> [String] {
        var parts: [String] = []
        repeat {
            horizontal()
            if current == "\"" || current == "'" { parts.append(try string(multiline: false)) }
            else {
                let start = index
                while let c = current, c.isASCII && (c.isLetter || c.isNumber || c == "_" || c == "-") { index += 1 }
                guard index > start else { throw TOMLError.malformed }
                parts.append(String(characters[start..<index]))
            }
            horizontal()
        } while take(".")
        return parts
    }

    mutating func value() throws -> TOMLValue {
        if current == "\"" || current == "'" { return .string(try string(multiline: true)) }
        if take("[") {
            var values: [TOMLValue] = []
            whitespace()
            if take("]") { return .array(values) }
            while true {
                values.append(try value())
                whitespace()
                if take("]") { return .array(values) }
                guard take(",") else { throw TOMLError.malformed }
                whitespace()
                if take("]") { return .array(values) }
            }
        }
        if take("{") {
            var values: [String: TOMLValue] = [:]
            horizontal()
            if take("}") { return .table(values) }
            while true {
                let key = try path().joined(separator: ".")
                guard take("=") else { throw TOMLError.malformed }
                horizontal()
                guard values[key] == nil else { throw TOMLError.malformed }
                values[key] = try value()
                horizontal()
                if take("}") { return .table(values) }
                guard take(",") else { throw TOMLError.malformed }
                horizontal()
            }
        }
        let start = index
        while let c = current, !c.isWhitespace, !["#", ",", "]", "}"].contains(c) { index += 1 }
        let token = String(characters[start..<index])
        let patterns = [
            "^(true|false|[+-]?(inf|nan))$",
            "^[+-]?(0|[1-9](_?[0-9])*)$",
            "^0x[0-9A-Fa-f](_?[0-9A-Fa-f])*$", "^0o[0-7](_?[0-7])*$", "^0b[01](_?[01])*$",
            "^[+-]?(0|[1-9](_?[0-9])*)(\\.[0-9](_?[0-9])*)?([eE][+-]?[0-9](_?[0-9])*)$",
            "^[+-]?(0|[1-9](_?[0-9])*)\\.[0-9](_?[0-9])*$",
            "^[0-9]{4}-[0-9]{2}-[0-9]{2}([Tt][0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?([Zz]|[+-][0-9]{2}:[0-9]{2})?)?$",
            "^[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?$"
        ]
        guard patterns.contains(where: { token.range(of: $0, options: .regularExpression) != nil }) else { throw TOMLError.malformed }
        return .scalar(token)
    }

    mutating func string(multiline: Bool) throws -> String {
        guard let quote = current else { throw TOMLError.malformed }
        index += 1
        let triple = multiline && index + 1 < characters.count && characters[index] == quote && characters[index + 1] == quote
        if triple { index += 2; if current?.isNewline == true { index += 1 } }
        var result = ""
        while let c = current {
            if c == quote {
                index += 1
                if !triple { return result }
                if take(quote) {
                    if take(quote) {
                        if take(quote) { result.append(quote) }
                        if take(quote) { result.append(quote) }
                        return result
                    }
                    result.append(quote)
                }
                result.append(quote)
                continue
            }
            if c.isNewline && !triple { throw TOMLError.malformed }
            if c.unicodeScalars.contains(where: { ($0.value < 0x20 && $0.value != 9 && $0.value != 10 && $0.value != 13) || $0.value == 0x7f }) { throw TOMLError.malformed }
            index += 1
            if c == "\\" && quote == "\"" {
                if triple, current?.isWhitespace == true {
                    horizontal()
                    guard current?.isNewline == true else { throw TOMLError.malformed }
                    while current?.isWhitespace == true { index += 1 }
                    continue
                }
                guard let escape = current else { throw TOMLError.malformed }
                index += 1
                let escapes: [Character: String] = ["b": "\u{8}", "t": "\t", "n": "\n", "f": "\u{c}", "r": "\r", "\"": "\"", "\\": "\\"]
                if let decoded = escapes[escape] { result += decoded }
                else if escape == "u" || escape == "U" {
                    let count = escape == "u" ? 4 : 8
                    guard index + count <= characters.count else { throw TOMLError.malformed }
                    let digits = String(characters[index..<(index + count)])
                    guard digits.allSatisfy(\.isHexDigit), let code = UInt32(digits, radix: 16), let scalar = UnicodeScalar(code) else { throw TOMLError.malformed }
                    result.unicodeScalars.append(scalar)
                    index += count
                } else { throw TOMLError.malformed }
            } else { result.append(c) }
        }
        throw TOMLError.malformed
    }
}
