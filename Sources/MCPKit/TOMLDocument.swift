import Foundation

enum TOMLError: Error { case malformed, unsupportedLayout }

indirect enum TOMLValue {
    case string(String), array([TOMLValue]), table([String: TOMLValue]), scalar(String)

    var string: String? { if case .string(let value) = self { value } else { nil } }
}

struct TOMLStatement {
    let start: Int
    let table: [String]
    let key: [String]?
    let value: TOMLValue?
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
        try validateLayout(path: path, envKey: keys.envKey)
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
        try validateLayout(path: path, envKey: definition.entry.envKey)
        let headers = statements.filter { $0.key == nil }
        let ranges = headers.enumerated().compactMap { index, header -> Range<Int>? in
            guard header.table.starts(with: path) else { return nil }
            return header.start..<(index + 1 < headers.count ? headers[index + 1].start : characters.count)
        }
        let block = entry.map { render($0, definition: definition, path: path) } ?? ""
        var output = ""
        var cursor = 0
        for (index, range) in ranges.enumerated() {
            output += String(characters[cursor..<range.lowerBound])
            if index == 0 { output += block }
            cursor = range.upperBound
        }
        output += String(characters[cursor...])
        if ranges.isEmpty, entry != nil {
            if !output.isEmpty {
                if !output.hasSuffix("\n") { output += "\n" }
                if !output.hasSuffix("\n\n") { output += "\n" }
            }
            output += block
        }
        return Data(output.utf8)
    }

    private func validateLayout(path: [String], envKey: String) throws {
        for statement in statements {
            if statement.arrayTable && (statement.table.starts(with: path) || path.starts(with: statement.table)) { throw TOMLError.unsupportedLayout }
            guard let key = statement.key else { continue }
            let full = statement.table + key
            if path.starts(with: full) { throw TOMLError.unsupportedLayout }
            if full.starts(with: path) {
                if key.count != 1 || !statement.table.starts(with: path) { throw TOMLError.unsupportedLayout }
                if statement.table == path && key == [envKey] { throw TOMLError.unsupportedLayout }
            }
        }
    }

    private func render(_ entry: ServerEntry, definition: AgentDefinition, path: [String]) -> String {
        let table = path.map(Self.key).joined(separator: ".")
        let keys = definition.entry
        var text = "[\(table)]\n\(Self.key(keys.commandKey)) = \(Self.quote(entry.command))\n"
        text += "\(Self.key(keys.argsKey)) = [\(entry.args.map(Self.quote).joined(separator: ", "))]\n"
        if !entry.env.isEmpty {
            text += "\n[\(table).\(Self.key(keys.envKey))]\n"
            for key in entry.env.keys.sorted() { text += "\(Self.key(key)) = \(Self.quote(entry.env[key]!))\n" }
        }
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
                result.append(TOMLStatement(start: start, table: table, key: nil, value: nil, arrayTable: array))
            } else {
                let key = try path()
                guard take("=") else { throw TOMLError.malformed }
                horizontal()
                let value = try value()
                let full = table + key
                let underArray = arrayPaths.contains { full.starts(with: $0) }
                if !underArray {
                    guard !values.contains(where: { full.starts(with: $0) || $0.starts(with: full) }),
                          !tables.contains(where: { $0.starts(with: full) }) else { throw TOMLError.malformed }
                    values.insert(full)
                }
                result.append(TOMLStatement(start: start, table: table, key: key, value: value, arrayTable: false))
            }
            horizontal()
            comment()
            guard current == nil || current?.isNewline == true else { throw TOMLError.malformed }
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
