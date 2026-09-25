import Foundation

/// Décodeur et utilitaire pour les codes défauts de diagnostic (DTC - Diagnostic Trouble Codes)
/// selon SAE J1979 (OBD-II), ISO 14230 (KWP2000) et ISO 14229 (UDS).
public enum DTCDecoder: Sendable {

    /// Décode un code DTC brut hexadécimal sur 2 octets (4 caractères, ex: "0102" -> "P0102")
    public static func decodeSingleDTC(_ hex: String) -> String? {
        let cleanHex = hex.replacing( " ", with: "")
        guard cleanHex.count >= 4, let value = UInt16(cleanHex.prefix(4), radix: 16) else { return nil }

        let highByte = UInt8((value >> 8) & 0xFF)
        let lowByte = UInt8(value & 0xFF)

        let typeMap = ["P", "C", "B", "U"]
        let typeIdx = Int((highByte >> 6) & 0b11)
        let type = typeMap[typeIdx]

        let digit1 = (highByte >> 4) & 0b11
        let digit2 = highByte & 0x0F
        let digit3 = (lowByte >> 4) & 0x0F
        let digit4 = lowByte & 0x0F

        var result = "\(type)\(digit1)\(String(digit2, radix: 16, uppercase: true))\(String(digit3, radix: 16, uppercase: true))\(String(digit4, radix: 16, uppercase: true))"
        
        // Si 3 octets (UDS avec sous-type de panne FTB), ajouter le suffixe ex: P0102-13
        if cleanHex.count == 6 {
            let ftb = cleanHex.suffix(2).uppercased()
            if ftb != "00" {
                result += "-\(ftb)"
            }
        }
        
        return result
    }

    /// Décode les drapeaux de statut d'un code défaut KWP2000 (Service 18 / 19)
    public static func decodeKwpDtcStatus(_ status: UInt8) -> String {
        var activeFlags: [String] = []
        if (status & 0x80) != 0 {
            activeFlags.append("Présent")
        } else {
            activeFlags.append("Mémorisé")
        }
        if (status & 0x40) != 0 {
            activeFlags.append("MIL demandée")
        }
        if (status & 0x20) != 0 {
            activeFlags.append("Non-confirmé")
        }
        return activeFlags.joined(separator: ", ")
    }

    /// Extrait une liste de codes DTCs sous forme de chaînes de caractères.
    public static func decodeDTCList(from hexPayload: String) -> [String] {
        decodeDTCsWithStatus(from: hexPayload).map { $0.code }
    }

    /// Extrait une liste de DTCs enrichis avec leur masque de statut (ISO 14229 / ISO 14230).
    public static func decodeDTCsWithStatus(from hexPayload: String) -> [DecodedDTC] {
        let clean = hexPayload.replacing( " ", with: "")
        var results: [DecodedDTC] = []

        // 1. OBD-II Mode 03 (43...), Mode 07 (47...), Mode 0A (4A...)
        if clean.hasPrefix("43") || clean.hasPrefix("47") || clean.hasPrefix("4A") {
            // SAE J1979 standard : pas d'octet de compte (supprime SID 2 chars).
            // Format legacy : octet de compte valide si et seulement si possibleCount * 4 == remainingAfterCount
            let remainingAfterCount = clean.count - 4
            let possibleCount = Int(clean.dropFirst(2).prefix(2), radix: 16) ?? -1
            let isLegacyWithCount = (remainingAfterCount >= 4 && remainingAfterCount % 4 == 0 && possibleCount > 0 && possibleCount * 4 == remainingAfterCount)
            let dropCount = isLegacyWithCount ? 4 : 2
            let data = String(clean.dropFirst(dropCount))
            for i in stride(from: 0, to: data.count - 3, by: 4) {
                let startIndex = data.index(data.startIndex, offsetBy: i)
                let endIndex = data.index(startIndex, offsetBy: 4)
                let dtcHex = String(data[startIndex..<endIndex])
                if dtcHex != "0000", let dtc = decodeSingleDTC(dtcHex) {
                    results.append(DecodedDTC(code: dtc))
                }
            }
            return results
        }

        // 2. KWP2000 Service 18 / 19 Réponse Positive (58 NN ... ou 59 NN ...) : Blocs de 3 octets (DTC_H, DTC_L, Status)
        if clean.hasPrefix("58") {
            let data = String(clean.dropFirst(4)) // Supprime 58 + NN
            for i in stride(from: 0, to: data.count - 5, by: 6) {
                let startIndex = data.index(data.startIndex, offsetBy: i)
                let dtcEndIndex = data.index(startIndex, offsetBy: 4)
                let statusEndIndex = data.index(startIndex, offsetBy: 6)
                
                let dtcHex = String(data[startIndex..<dtcEndIndex])
                let statusHex = String(data[dtcEndIndex..<statusEndIndex])
                let statusByte = UInt8(statusHex, radix: 16)
                
                if dtcHex != "0000", let dtc = decodeSingleDTC(dtcHex) {
                    results.append(DecodedDTC(code: dtc, statusByte: statusByte))
                }
            }
            return results
        }

        // 3. UDS Service 19 Réponse Positive (59 subfunction SAM DTC_H DTC_M DTC_L Status ...) : Blocs de 4 octets
        if clean.hasPrefix("59") {
            // Supprime 59 + SubFunction (2 chars) + StatusAvailabilityMask (2 chars)
            guard clean.count >= 6 else { return [] }
            let data = String(clean.dropFirst(6))
            for i in stride(from: 0, to: data.count - 7, by: 8) {
                let startIndex = data.index(data.startIndex, offsetBy: i)
                let dtcEndIndex = data.index(startIndex, offsetBy: 6)
                let statusEndIndex = data.index(startIndex, offsetBy: 8)
                
                let dtcHex = String(data[startIndex..<dtcEndIndex])
                let statusHex = String(data[dtcEndIndex..<statusEndIndex])
                let statusByte = UInt8(statusHex, radix: 16)
                
                if !dtcHex.hasPrefix("0000"), let dtc = decodeSingleDTC(dtcHex) {
                    results.append(DecodedDTC(code: dtc, statusByte: statusByte))
                }
            }
            return results
        }

        return results
    }
}
