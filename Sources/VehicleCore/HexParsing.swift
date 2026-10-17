import Foundation

public enum HexParsing: Sendable {

    @usableFromInline
    internal static let hexDigits: [UInt8] = Array("0123456789ABCDEF".utf8)

    @inlinable
    public static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30        // '0'...'9'
        case 0x41...0x46: return byte - 0x41 + 10   // 'A'...'F'
        case 0x61...0x66: return byte - 0x61 + 10   // 'a'...'f'
        default: return nil
        }
    }

    public static func bytes(_ hexString: String) -> [UInt8]? {
        let utf8 = hexString.utf8
        var result = [UInt8]()
        result.reserveCapacity(utf8.count / 2)
        var pendingHighNibble: UInt8? = nil

        for b in utf8 {
            if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D {
                continue // Ignore whitespace and newlines without string allocations
            }
            guard let nibble = hexNibble(b) else { return nil }
            if let hi = pendingHighNibble {
                result.append((hi << 4) | nibble)
                pendingHighNibble = nil
            } else {
                pendingHighNibble = nibble
            }
        }

        guard pendingHighNibble == nil else { return nil }
        return result
    }

    public static func hex(_ bytes: [UInt8]) -> String {
        guard !bytes.isEmpty else { return "" }
        return String(unsafeUninitializedCapacity: bytes.count * 2) { buffer in
            var ptr = buffer.baseAddress!
            for b in bytes {
                ptr.pointee = hexDigits[Int(b >> 4)]
                ptr += 1
                ptr.pointee = hexDigits[Int(b & 0x0F)]
                ptr += 1
            }
            return bytes.count * 2
        }
    }

    @inlinable
    public static func hex(byte: UInt8) -> String {
        String(unsafeUninitializedCapacity: 2) { buffer in
            buffer[0] = hexDigits[Int(byte >> 4)]
            buffer[1] = hexDigits[Int(byte & 0x0F)]
            return 2
        }
    }

    @inlinable
    public static func hex(uint16: UInt16) -> String {
        String(unsafeUninitializedCapacity: 4) { buffer in
            buffer[0] = hexDigits[Int((uint16 >> 12) & 0x0F)]
            buffer[1] = hexDigits[Int((uint16 >> 8) & 0x0F)]
            buffer[2] = hexDigits[Int((uint16 >> 4) & 0x0F)]
            buffer[3] = hexDigits[Int(uint16 & 0x0F)]
            return 4
        }
    }

    public static func stripISOTPFraming(_ response: String) -> String {
        let rawTokens = response
            .replacing(">", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        var cleaned: [String] = []
        cleaned.reserveCapacity(rawTokens.count)

        for i in 0..<rawTokens.count {
            let token = rawTokens[i]
            // Skip 3-hex-char length header (e.g. "014") when followed by "0:"
            if token.count == 3,
               token.allSatisfy(\.isHexDigit),
               i + 1 < rawTokens.count,
               rawTokens[i + 1].hasPrefix("0:") {
                continue
            }

            if let colonIdx = token.firstIndex(of: ":") {
                let prefix = token[..<colonIdx]
                if !prefix.isEmpty && prefix.count <= 2 && prefix.allSatisfy(\.isHexDigit) {
                    let remainder = String(token[token.index(after: colonIdx)...])
                    if !remainder.isEmpty {
                        cleaned.append(remainder)
                    }
                    continue
                }
            }

            cleaned.append(token)
        }

        return cleaned.joined().uppercased()
    }

    public static func printableASCII(from hex: String) -> String {
        var out = String()
        out.reserveCapacity(hex.utf8.count / 2)
        var pendingHighNibble: UInt8? = nil

        for b in hex.utf8 {
            if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D {
                continue
            }
            guard let nibble = hexNibble(b) else {
                pendingHighNibble = nil
                continue
            }
            if let hi = pendingHighNibble {
                let byte = (hi << 4) | nibble
                pendingHighNibble = nil
                if byte >= 0x20 && byte < 0x7F {
                    out.append(Character(UnicodeScalar(byte)))
                }
            } else {
                pendingHighNibble = nibble
            }
        }
        return out
    }
}
