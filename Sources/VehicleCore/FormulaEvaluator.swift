import Foundation
import os

/// Évaluateur haute performance, pré-compilé et thread-safe pour les formules de conversion de signaux automobiles.
/// Conforme Swift 6 strict concurrency (`Sendable`) avec compilation en AST, cache thread-safe et vectorisation par lot.
public final class FormulaEvaluator: Sendable {

    private let cache: OSAllocatedUnfairLock<[String: CompiledFormula]>

    public init() {
        self.cache = OSAllocatedUnfairLock(initialState: [:])
    }

    /// Compile une formule textuelle en un arbre syntaxique abstrait (AST) immuable.
    public func compile(formula: String) -> CompiledFormula? {
        let trimmed = formula.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        return cache.withLock { dict in
            if let existing = dict[trimmed] {
                return existing
            }
            guard let node = ASTCompiler.compile(expression: trimmed) else {
                return nil
            }
            let compiled = CompiledFormula(source: trimmed, root: node)
            dict[trimmed] = compiled
            return compiled
        }
    }

    /// Évalue une formule sur un buffer d'octets.
    public func evaluate(formula: String, bytes: [UInt8]) -> Double? {
        guard !formula.isEmpty else { return nil }

        let trimmed = formula.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Chemins ultra-rapides sans compilation pour les formules les plus courantes
        if trimmed == "A" && !bytes.isEmpty {
            return Double(bytes[0])
        }
        if trimmed == "(A*256+B)/4" && bytes.count >= 2 {
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1])) / 4.0
        }
        if trimmed == "A-40" && !bytes.isEmpty {
            return Double(bytes[0]) - 40.0
        }
        if (trimmed == "A AND 15" || trimmed == "A & 15" || trimmed == "A&15") && !bytes.isEmpty {
            return Double(bytes[0] & 0x0F)
        }
        if trimmed == "A*100/255" && !bytes.isEmpty {
            return (Double(bytes[0]) * 100.0) / 255.0
        }
        if trimmed == "A*256+B" && bytes.count >= 2 {
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
        }

        // 2. Compilation ou récupération depuis le cache AST
        guard let compiled = compile(formula: trimmed) else {
            return nil
        }
        guard let result = compiled.evaluate(bytes: bytes), result.isFinite else {
            return nil
        }
        return result
    }

    /// Évalue une formule sur une série de trames d'octets (Batch Evaluation).
    public func evaluateBatch(formula: String, frames: [[UInt8]]) -> [Double] {
        guard let compiled = compile(formula: formula) else { return [] }
        var results = [Double]()
        results.reserveCapacity(frames.count)

        for frame in frames {
            if let val = compiled.evaluate(bytes: frame) {
                results.append(val)
            }
        }
        return results
    }
}

// MARK: - Arbre Syntaxique Abstrait & Formule Compilée

public struct CompiledFormula: Sendable {
    public let source: String
    public let root: ASTNode

    public init(source: String, root: ASTNode) {
        self.source = source
        self.root = root
    }

    public func evaluate(bytes: [UInt8]) -> Double? {
        guard let val = root.evaluate(bytes: bytes), val.isFinite else {
            return nil
        }
        return val
    }
}

public indirect enum ASTNode: Sendable, Equatable {
    case number(Double)
    case variable(Int) // 0 pour A, 1 pour B, 2 pour C...
    case unary(UnaryOp, ASTNode)
    case binary(BinaryOp, ASTNode, ASTNode)
    case function(FunctionOp, [ASTNode])
    case conditional(condition: ASTNode, trueBranch: ASTNode, falseBranch: ASTNode)

    public enum UnaryOp: Sendable, Equatable {
        case positive
        case negate
        case bitwiseNot
        case logicalNot
    }

    public enum BinaryOp: Sendable, Equatable {
        case add
        case subtract
        case multiply
        case divide
        case modulo
        case bitwiseAnd
        case bitwiseOr
        case bitwiseXor
        case shiftLeft
        case shiftRight
        case equal
        case notEqual
        case greaterThan
        case greaterThanOrEqual
        case lessThan
        case lessThanOrEqual
        case logicalAnd
        case logicalOr
    }

    public enum FunctionOp: String, Sendable, Equatable {
        case min
        case max
        case sqrt
        case abs
        case round
    }

    public func evaluate(bytes: [UInt8]) -> Double? {
        switch self {
        case .number(let val):
            return val.isFinite ? val : nil

        case .variable(let index):
            guard index >= 0 && index < bytes.count else { return nil }
            return Double(bytes[index])

        case .unary(let op, let child):
            guard let val = child.evaluate(bytes: bytes), val.isFinite else { return nil }
            switch op {
            case .positive:
                return val
            case .negate:
                return -val
            case .bitwiseNot:
                guard val >= Double(Int64.min), val <= Double(Int64.max) else { return nil }
                return Double(~Int64(val))
            case .logicalNot:
                return (abs(val) < 1e-9) ? 1.0 : 0.0
            }

        case .binary(let op, let leftNode, let rightNode):
            guard let left = leftNode.evaluate(bytes: bytes),
                  let right = rightNode.evaluate(bytes: bytes),
                  left.isFinite, right.isFinite else {
                return nil
            }
            switch op {
            case .add:
                let res = left + right
                return res.isFinite ? res : nil
            case .subtract:
                let res = left - right
                return res.isFinite ? res : nil
            case .multiply:
                let res = left * right
                return res.isFinite ? res : nil
            case .divide:
                guard abs(right) > 1e-15 else { return nil }
                let res = left / right
                return res.isFinite ? res : nil
            case .modulo:
                guard abs(right) > 1e-15 else { return nil }
                let res = left.truncatingRemainder(dividingBy: right)
                return res.isFinite ? res : nil
            case .bitwiseAnd:
                guard left >= Double(Int64.min), left <= Double(Int64.max),
                      right >= Double(Int64.min), right <= Double(Int64.max) else { return nil }
                return Double(Int64(left) & Int64(right))
            case .bitwiseOr:
                guard left >= Double(Int64.min), left <= Double(Int64.max),
                      right >= Double(Int64.min), right <= Double(Int64.max) else { return nil }
                return Double(Int64(left) | Int64(right))
            case .bitwiseXor:
                guard left >= Double(Int64.min), left <= Double(Int64.max),
                      right >= Double(Int64.min), right <= Double(Int64.max) else { return nil }
                return Double(Int64(left) ^ Int64(right))
            case .shiftLeft:
                guard left >= Double(Int64.min), left <= Double(Int64.max) else { return nil }
                let shift = Int(right) & 63
                return Double(Int64(left) &<< shift)
            case .shiftRight:
                guard left >= Double(Int64.min), left <= Double(Int64.max) else { return nil }
                let shift = Int(right) & 63
                return Double(Int64(left) &>> shift)
            case .equal:
                return abs(left - right) < 1e-9 ? 1.0 : 0.0
            case .notEqual:
                return abs(left - right) >= 1e-9 ? 1.0 : 0.0
            case .greaterThan:
                return left > right ? 1.0 : 0.0
            case .greaterThanOrEqual:
                return left >= right ? 1.0 : 0.0
            case .lessThan:
                return left < right ? 1.0 : 0.0
            case .lessThanOrEqual:
                return left <= right ? 1.0 : 0.0
            case .logicalAnd:
                // Sémantique duale : booléenne pure si les deux opérandes sont {0, 1},
                // sinon bitwise masking pour compatibilité DDT2000 ("A AND 15")
                let isLeftBool = (abs(left) < 1e-9 || abs(left - 1.0) < 1e-9)
                let isRightBool = (abs(right) < 1e-9 || abs(right - 1.0) < 1e-9)
                if isLeftBool && isRightBool {
                    return (abs(left) > 1e-9 && abs(right) > 1e-9) ? 1.0 : 0.0
                }
                guard left >= Double(Int64.min), left <= Double(Int64.max),
                      right >= Double(Int64.min), right <= Double(Int64.max) else { return nil }
                return Double(Int64(left) & Int64(right))
            case .logicalOr:
                let isLeftBool = (abs(left) < 1e-9 || abs(left - 1.0) < 1e-9)
                let isRightBool = (abs(right) < 1e-9 || abs(right - 1.0) < 1e-9)
                if isLeftBool && isRightBool {
                    return (abs(left) > 1e-9 || abs(right) > 1e-9) ? 1.0 : 0.0
                }
                guard left >= Double(Int64.min), left <= Double(Int64.max),
                      right >= Double(Int64.min), right <= Double(Int64.max) else { return nil }
                return Double(Int64(left) | Int64(right))
            }

        case .function(let fn, let args):
            let evaluatedArgs = args.compactMap { $0.evaluate(bytes: bytes) }
            guard evaluatedArgs.count == args.count else { return nil }

            switch fn {
            case .min:
                guard !evaluatedArgs.isEmpty else { return nil }
                let res = evaluatedArgs.reduce(Double.infinity, min)
                return res.isFinite ? res : nil
            case .max:
                guard !evaluatedArgs.isEmpty else { return nil }
                let res = evaluatedArgs.reduce(-Double.infinity, max)
                return res.isFinite ? res : nil
            case .sqrt:
                guard let arg = evaluatedArgs.first, arg >= 0 else { return nil }
                let res = sqrt(arg)
                return res.isFinite ? res : nil
            case .abs:
                guard let arg = evaluatedArgs.first else { return nil }
                let res = abs(arg)
                return res.isFinite ? res : nil
            case .round:
                guard let arg = evaluatedArgs.first else { return nil }
                let res = round(arg)
                return res.isFinite ? res : nil
            }

        case .conditional(let condNode, let trueNode, let falseNode):
            guard let cond = condNode.evaluate(bytes: bytes), cond.isFinite else { return nil }
            return (abs(cond) > 1e-9) ? trueNode.evaluate(bytes: bytes) : falseNode.evaluate(bytes: bytes)
        }
    }
}

// MARK: - Compilateur AST Déterministe

private enum ASTCompiler {

    enum Token: Equatable {
        case number(Double)
        case variable(Int)
        case identifier(String)
        case plus
        case minus
        case multiply
        case divide
        case modulo
        case bitwiseAnd
        case bitwiseOr
        case bitwiseXor
        case bitwiseNot
        case logicalAnd
        case logicalOr
        case logicalNot
        case shiftLeft
        case shiftRight
        case equal
        case notEqual
        case greaterThan
        case greaterThanOrEqual
        case lessThan
        case lessThanOrEqual
        case questionMark
        case colon
        case comma
        case openParen
        case closeParen
    }

    static func compile(expression: String) -> ASTNode? {
        guard let tokens = tokenize(expression) else { return nil }
        var index = 0
        guard let node = parseConditional(tokens: tokens, index: &index),
              index == tokens.count else {
            return nil
        }
        return node
    }

    private static func tokenize(_ expr: String) -> [Token]? {
        var tokens: [Token] = []
        let chars = Array(expr)
        var i = 0

        while i < chars.count {
            let c = chars[i]

            if c.isWhitespace {
                i += 1
                continue
            }

            // Nombres hexadécimaux ou décimaux
            if c.isNumber || c == "." {
                if c == "0" && i + 1 < chars.count && (chars[i + 1] == "x" || chars[i + 1] == "X") {
                    i += 2
                    var hexStr = ""
                    while i < chars.count && chars[i].isHexDigit {
                        hexStr.append(chars[i])
                        i += 1
                    }
                    guard let val = UInt64(hexStr, radix: 16) else { return nil }
                    tokens.append(.number(Double(val)))
                    continue
                }

                var numStr = ""
                while i < chars.count && (chars[i].isNumber || chars[i] == ".") {
                    numStr.append(chars[i])
                    i += 1
                }
                guard let val = Double(numStr) else { return nil }
                tokens.append(.number(val))
                continue
            }

            // Identifiants, variables A..Z, fonctions (min, max, sqrt, abs, round), opérateurs textuels
            if c.isLetter {
                var word = ""
                while i < chars.count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") {
                    word.append(chars[i])
                    i += 1
                }
                let upper = word.uppercased()
                switch upper {
                case "AND":
                    tokens.append(.logicalAnd)
                case "OR":
                    tokens.append(.logicalOr)
                case "XOR":
                    tokens.append(.bitwiseXor)
                case "NOT":
                    tokens.append(.logicalNot)
                default:
                    if word.count == 1, let scalar = upper.unicodeScalars.first, scalar.value >= 65 && scalar.value <= 90 {
                        tokens.append(.variable(Int(scalar.value - 65)))
                    } else {
                        tokens.append(.identifier(word.lowercased()))
                    }
                }
                continue
            }

            // Opérateurs composés et symboles
            switch c {
            case "+":
                tokens.append(.plus)
                i += 1
            case "-":
                tokens.append(.minus)
                i += 1
            case "*":
                tokens.append(.multiply)
                i += 1
            case "/":
                tokens.append(.divide)
                i += 1
            case "%":
                tokens.append(.modulo)
                i += 1
            case "?":
                tokens.append(.questionMark)
                i += 1
            case ":":
                tokens.append(.colon)
                i += 1
            case ",":
                tokens.append(.comma)
                i += 1
            case "(":
                tokens.append(.openParen)
                i += 1
            case ")":
                tokens.append(.closeParen)
                i += 1
            case "&":
                if i + 1 < chars.count && chars[i + 1] == "&" {
                    tokens.append(.logicalAnd)
                    i += 2
                } else {
                    tokens.append(.bitwiseAnd)
                    i += 1
                }
            case "|":
                if i + 1 < chars.count && chars[i + 1] == "|" {
                    tokens.append(.logicalOr)
                    i += 2
                } else {
                    tokens.append(.bitwiseOr)
                    i += 1
                }
            case "^":
                tokens.append(.bitwiseXor)
                i += 1
            case "~":
                tokens.append(.bitwiseNot)
                i += 1
            case "=":
                if i + 1 < chars.count && chars[i + 1] == "=" {
                    tokens.append(.equal)
                    i += 2
                } else {
                    tokens.append(.equal)
                    i += 1
                }
            case "!":
                if i + 1 < chars.count && chars[i + 1] == "=" {
                    tokens.append(.notEqual)
                    i += 2
                } else {
                    tokens.append(.logicalNot)
                    i += 1
                }
            case "<":
                if i + 1 < chars.count && chars[i + 1] == "<" {
                    tokens.append(.shiftLeft)
                    i += 2
                } else if i + 1 < chars.count && chars[i + 1] == "=" {
                    tokens.append(.lessThanOrEqual)
                    i += 2
                } else {
                    tokens.append(.lessThan)
                    i += 1
                }
            case ">":
                if i + 1 < chars.count && chars[i + 1] == ">" {
                    tokens.append(.shiftRight)
                    i += 2
                } else if i + 1 < chars.count && chars[i + 1] == "=" {
                    tokens.append(.greaterThanOrEqual)
                    i += 2
                } else {
                    tokens.append(.greaterThan)
                    i += 1
                }
            default:
                return nil
            }
        }
        return tokens
    }

    // Grammar Precedence (du plus faible au plus fort):
    // Conditional -> LogicalOr ('?' Conditional ':' Conditional)?
    // LogicalOr -> LogicalAnd (('||' | 'OR') LogicalAnd)*
    // LogicalAnd -> Comparison (('&&' | 'AND') Comparison)*
    // Comparison -> BitwiseOr (('==' | '!=' | '>' | '>=' | '<' | '<=') BitwiseOr)*
    // BitwiseOr -> BitwiseXor ('|' BitwiseXor)*
    // BitwiseXor -> BitwiseAnd (('^' | 'XOR') BitwiseAnd)*
    // BitwiseAnd -> Shift ('&' Shift)*
    // Shift -> Additive (('<<' | '>>') Additive)*
    // Additive -> Multiplicative (('+' | '-') Multiplicative)*
    // Multiplicative -> Unary (('*' | '/' | '%') Unary)*
    // Unary -> ('+' | '-' | '~' | '!' | 'NOT') Unary | Primary
    // Primary -> Number | Variable | FunctionCall | '(' Conditional ')'

    private static func parseConditional(tokens: [Token], index: inout Int) -> ASTNode? {
        guard let cond = parseLogicalOr(tokens: tokens, index: &index) else { return nil }

        if index < tokens.count && tokens[index] == .questionMark {
            index += 1
            guard let trueBranch = parseConditional(tokens: tokens, index: &index) else { return nil }
            guard index < tokens.count && tokens[index] == .colon else { return nil }
            index += 1
            guard let falseBranch = parseConditional(tokens: tokens, index: &index) else { return nil }
            return .conditional(condition: cond, trueBranch: trueBranch, falseBranch: falseBranch)
        }
        return cond
    }

    private static func parseLogicalOr(tokens: [Token], index: inout Int) -> ASTNode? {
        guard var left = parseLogicalAnd(tokens: tokens, index: &index) else { return nil }
        while index < tokens.count && tokens[index] == .logicalOr {
            index += 1
            guard let right = parseLogicalAnd(tokens: tokens, index: &index) else { return nil }
            left = .binary(.logicalOr, left, right)
        }
        return left
    }

    private static func parseLogicalAnd(tokens: [Token], index: inout Int) -> ASTNode? {
        guard var left = parseComparison(tokens: tokens, index: &index) else { return nil }
        while index < tokens.count && tokens[index] == .logicalAnd {
            index += 1
            guard let right = parseComparison(tokens: tokens, index: &index) else { return nil }
            left = .binary(.logicalAnd, left, right)
        }
        return left
    }

    private static func parseComparison(tokens: [Token], index: inout Int) -> ASTNode? {
        guard var left = parseBitwiseOr(tokens: tokens, index: &index) else { return nil }

        while index < tokens.count {
            let tok = tokens[index]
            let op: ASTNode.BinaryOp
            switch tok {
            case .equal: op = .equal
            case .notEqual: op = .notEqual
            case .greaterThan: op = .greaterThan
            case .greaterThanOrEqual: op = .greaterThanOrEqual
            case .lessThan: op = .lessThan
            case .lessThanOrEqual: op = .lessThanOrEqual
            default: return left
            }
            index += 1
            guard let right = parseBitwiseOr(tokens: tokens, index: &index) else { return nil }
            left = .binary(op, left, right)
        }
        return left
    }

    private static func parseBitwiseOr(tokens: [Token], index: inout Int) -> ASTNode? {
        guard var left = parseBitwiseXor(tokens: tokens, index: &index) else { return nil }
        while index < tokens.count && tokens[index] == .bitwiseOr {
            index += 1
            guard let right = parseBitwiseXor(tokens: tokens, index: &index) else { return nil }
            left = .binary(.bitwiseOr, left, right)
        }
        return left
    }

    private static func parseBitwiseXor(tokens: [Token], index: inout Int) -> ASTNode? {
        guard var left = parseBitwiseAnd(tokens: tokens, index: &index) else { return nil }
        while index < tokens.count && tokens[index] == .bitwiseXor {
            index += 1
            guard let right = parseBitwiseAnd(tokens: tokens, index: &index) else { return nil }
            left = .binary(.bitwiseXor, left, right)
        }
        return left
    }

    private static func parseBitwiseAnd(tokens: [Token], index: inout Int) -> ASTNode? {
        guard var left = parseShift(tokens: tokens, index: &index) else { return nil }
        while index < tokens.count && tokens[index] == .bitwiseAnd {
            index += 1
            guard let right = parseShift(tokens: tokens, index: &index) else { return nil }
            left = .binary(.bitwiseAnd, left, right)
        }
        return left
    }

    private static func parseShift(tokens: [Token], index: inout Int) -> ASTNode? {
        guard var left = parseAdditive(tokens: tokens, index: &index) else { return nil }
        while index < tokens.count && (tokens[index] == .shiftLeft || tokens[index] == .shiftRight) {
            let op: ASTNode.BinaryOp = (tokens[index] == .shiftLeft) ? .shiftLeft : .shiftRight
            index += 1
            guard let right = parseAdditive(tokens: tokens, index: &index) else { return nil }
            left = .binary(op, left, right)
        }
        return left
    }

    private static func parseAdditive(tokens: [Token], index: inout Int) -> ASTNode? {
        guard var left = parseMultiplicative(tokens: tokens, index: &index) else { return nil }
        while index < tokens.count && (tokens[index] == .plus || tokens[index] == .minus) {
            let op: ASTNode.BinaryOp = (tokens[index] == .plus) ? .add : .subtract
            index += 1
            guard let right = parseMultiplicative(tokens: tokens, index: &index) else { return nil }
            left = .binary(op, left, right)
        }
        return left
    }

    private static func parseMultiplicative(tokens: [Token], index: inout Int) -> ASTNode? {
        guard var left = parseUnary(tokens: tokens, index: &index) else { return nil }
        while index < tokens.count && (tokens[index] == .multiply || tokens[index] == .divide || tokens[index] == .modulo) {
            let op: ASTNode.BinaryOp
            if tokens[index] == .multiply {
                op = .multiply
            } else if tokens[index] == .divide {
                op = .divide
            } else {
                op = .modulo
            }
            index += 1
            guard let right = parseUnary(tokens: tokens, index: &index) else { return nil }
            left = .binary(op, left, right)
        }
        return left
    }

    private static func parseUnary(tokens: [Token], index: inout Int) -> ASTNode? {
        guard index < tokens.count else { return nil }
        let tok = tokens[index]

        switch tok {
        case .plus:
            index += 1
            guard let child = parseUnary(tokens: tokens, index: &index) else { return nil }
            return .unary(.positive, child)
        case .minus:
            index += 1
            guard let child = parseUnary(tokens: tokens, index: &index) else { return nil }
            return .unary(.negate, child)
        case .bitwiseNot:
            index += 1
            guard let child = parseUnary(tokens: tokens, index: &index) else { return nil }
            return .unary(.bitwiseNot, child)
        case .logicalNot:
            index += 1
            guard let child = parseUnary(tokens: tokens, index: &index) else { return nil }
            return .unary(.logicalNot, child)
        default:
            return parsePrimary(tokens: tokens, index: &index)
        }
    }

    private static func parsePrimary(tokens: [Token], index: inout Int) -> ASTNode? {
        guard index < tokens.count else { return nil }
        let tok = tokens[index]

        switch tok {
        case .number(let val):
            index += 1
            return .number(val)

        case .variable(let varIdx):
            index += 1
            return .variable(varIdx)

        case .identifier(let name):
            index += 1
            guard let fn = ASTNode.FunctionOp(rawValue: name.lowercased()) else {
                return nil
            }
            guard index < tokens.count && tokens[index] == .openParen else { return nil }
            index += 1
            var args: [ASTNode] = []
            if index < tokens.count && tokens[index] != .closeParen {
                guard let firstArg = parseConditional(tokens: tokens, index: &index) else { return nil }
                args.append(firstArg)
                while index < tokens.count && tokens[index] == .comma {
                    index += 1
                    guard let nextArg = parseConditional(tokens: tokens, index: &index) else { return nil }
                    args.append(nextArg)
                }
            }
            guard index < tokens.count && tokens[index] == .closeParen else { return nil }
            index += 1
            return .function(fn, args)

        case .openParen:
            index += 1
            guard let inner = parseConditional(tokens: tokens, index: &index) else { return nil }
            guard index < tokens.count && tokens[index] == .closeParen else { return nil }
            index += 1
            return inner

        default:
            return nil
        }
    }
}
