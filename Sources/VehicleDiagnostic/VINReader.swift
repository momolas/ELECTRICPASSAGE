import Foundation
import VehicleCore
import VehicleTransport

/// Décodeur et lecteur universel de numéro d'identification de véhicule (VIN - Vehicle Identification Number)
public enum VINReader: Sendable {

    /// Lit le numéro VIN via les différents protocoles (OBD-II Mode 09 PID 02, UDS DID F190, KWP2000 LID 81/80/82)
    public static func read(interface: VehicleInterface) async throws -> String? {
        try Task.checkCancellation()

        // 1. Stage A: Standard OBD-II Mode 09 PID 02 (Broadcast 0x7DF -> 0x7E8)
        do {
            try Task.checkCancellation()
            try await interface.setTarget(txID: "7DF", rxID: "7E8")
            let response = try await interface.sendDiagnosticRequest("0902", timeout: 2.0)
            if let vin = parseOBD2VIN(response) {
                return vin
            }
        } catch {
            if error is CancellationError { throw error }
        }

        // 2. Stage B: Standard UDS Read DID F190 (Engine 0x7E0 -> 0x7E8)
        do {
            try Task.checkCancellation()
            try await interface.setTarget(txID: "7E0", rxID: "7E8")
            let response = try await interface.sendDiagnosticRequest("22F190", timeout: 2.0)
            if let vin = parseUDSVIN(response) {
                return vin
            }
        } catch {
            if error is CancellationError { throw error }
        }

        // 3. Stage C: Renault Physical Injection ECU (0x7E0 -> 0x7E8) KWP2000
        do {
            try Task.checkCancellation()
            try await interface.setTarget(txID: "7E0", rxID: "7E8")
            _ = try? await openDiagnosticSession(interface: interface)

            for lidCmd in ["2181", "2180", "2182"] {
                if let response = try? await interface.sendDiagnosticRequest(lidCmd, timeout: 1.5),
                   let vin = parseKWP2000VIN(response) {
                    await closeDiagnosticSession(interface: interface)
                    return vin
                }
            }
            await closeDiagnosticSession(interface: interface)
        } catch {
            if error is CancellationError { throw error }
        }

        // 4. Stage D: Renault Physical UCH / BCM (0x744 / 0x745 -> 0x764 / 0x765) KWP2000
        do {
            try Task.checkCancellation()
            try await interface.setTarget(txID: "744", rxID: "764")
            _ = try? await openDiagnosticSession(interface: interface)

            for lidCmd in ["2181", "2180", "2182"] {
                if let response = try? await interface.sendDiagnosticRequest(lidCmd, timeout: 1.5),
                   let vin = parseKWP2000VIN(response) {
                    await closeDiagnosticSession(interface: interface)
                    return vin
                }
            }
            await closeDiagnosticSession(interface: interface)
        } catch {
            if error is CancellationError { throw error }
        }

        return nil
    }

    // MARK: - Décodage et Parsing des Réponses

    /// Décode une réponse OBD-II Mode 09 PID 02 (49 02 ...)
    public static func parseOBD2VIN(_ response: String) -> String? {
        let lines = response
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map(stripFrameIndex)
        let concatenated = lines.joined().uppercased()
        guard let headerRange = concatenated.range(of: "4902") else { return nil }

        let dataStart = concatenated.index(headerRange.upperBound, offsetBy: 2, limitedBy: concatenated.endIndex) ?? concatenated.endIndex
        let dataHex = String(concatenated[dataStart...])
        let ascii = hexToAscii(dataHex)
        return firstVINMatch(in: ascii)
    }

    /// Décode une réponse UDS Service 22 DID F190 (62 F1 90 ...)
    public static func parseUDSVIN(_ response: String) -> String? {
        let lines = response
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map(stripFrameIndex)
        let concatenated = lines.joined().uppercased()

        guard let range = concatenated.range(of: "62F190") else { return nil }
        let start = range.upperBound
        let dataHex = String(concatenated[start...].prefix(34))
        guard dataHex.count == 34 else { return nil }

        let ascii = hexToAscii(dataHex)
        return firstVINMatch(in: ascii)
    }

    /// Décode une réponse KWP2000 Service 21 LID 81/80 (61 81 ...)
    public static func parseKWP2000VIN(_ response: String) -> String? {
        let lines = response
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map(stripFrameIndex)
        let concatenated = lines.joined().uppercased()

        guard let range = concatenated.range(of: "6181") ?? concatenated.range(of: "6180") ?? concatenated.range(of: "6182") else {
            return nil
        }
        let start = range.upperBound
        let dataHex = String(concatenated[start...].prefix(34))
        guard dataHex.count == 34 else { return nil }

        let ascii = hexToAscii(dataHex)
        return firstVINMatch(in: ascii)
    }

    /// Extrait la première chaîne valide de 17 caractères alphanumériques respectant la norme VIN (sans I, O, Q)
    public static func firstVINMatch(in ascii: String) -> String? {
        let allowed: Set<Character> = Set("ABCDEFGHJKLMNPRSTUVWXYZ0123456789")
        let chars = Array(ascii)
        guard chars.count >= 17 else { return nil }
        for start in 0...(chars.count - 17) {
            let slice = chars[start..<(start + 17)]
            if slice.allSatisfy({ allowed.contains($0) }) {
                return String(slice)
            }
        }
        return nil
    }

    // MARK: - Utilitaires de conversion

    private static func stripFrameIndex(_ line: String) -> String {
        guard let colonIdx = line.firstIndex(of: ":") else { return line }
        let prefix = line[..<colonIdx]
        guard prefix.count <= 2, prefix.allSatisfy({ $0.isHexDigit }) else { return line }
        return String(line[line.index(after: colonIdx)...])
    }

    private static func hexToAscii(_ hex: String) -> String {
        var out = ""
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard hex.distance(from: idx, to: next) == 2 else { break }
            let pair = String(hex[idx..<next])
            if let byte = UInt8(pair, radix: 16) {
                if byte >= 0x20 && byte < 0x7F {
                    out.append(Character(UnicodeScalar(byte)))
                } else {
                    out.append(" ")
                }
            }
            idx = next
        }
        return out
    }

    private static func openDiagnosticSession(interface: VehicleInterface) async throws -> Bool {
        for sessionCmd in ["1085", "1086", "1003", "1001"] {
            if let res = try? await interface.sendDiagnosticRequest(sessionCmd, timeout: 1.0) {
                let normalized = res.uppercased().replacing( " ", with: "")
                if !normalized.starts(with: "7F") && !normalized.isEmpty {
                    return true
                }
            }
        }
        return false
    }

    private static func closeDiagnosticSession(interface: VehicleInterface) async {
        _ = try? await interface.sendDiagnosticRequest("1081", timeout: 1.0)
    }
}
