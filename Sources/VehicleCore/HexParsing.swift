import Foundation

public enum HexParsing: Sendable {

    private static let hexDigits: [UInt8] = Array("0123456789ABCDEF".utf8)

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
        var cleanBytes = [UInt8]()
        cleanBytes.reserveCapacity(utf8.count)

        for b in utf8 {
            if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D {
                continue // Ignore whitespace and newlines without string allocations
            }
            guard hexNibble(b) != nil else { return nil }
            cleanBytes.append(b)
        }

        guard cleanBytes.count % 2 == 0 else { return nil }
        var result = [UInt8]()
        result.reserveCapacity(cleanBytes.count / 2)

        var i = 0
        while i < cleanBytes.count {
            guard let hi = hexNibble(cleanBytes[i]),
                  let lo = hexNibble(cleanBytes[i + 1]) else {
                return nil
            }
            result.append((hi << 4) | lo)
            i += 2
        }
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
}
