import Foundation
import VehicleCore
import VehicleTransport

/// Informations d'identification logicielle et d'intégrité de calibration (cartographie) d'un calculateur moteur (ECU).
public nonisolated struct ECUCalibrationInfo: Sendable, Equatable, Codable {
    /// Identifiants de calibration (CalID - OBD-II Mode 09 PID 04, UDS DID F198 ou KWP2000 2180)
    public let calibrationIDs: [String]
    /// Sommes de contrôle de vérification de calibration (CVN 32 bits - OBD-II Mode 09 PID 06 ou UDS DID F199)
    public let calibrationVerificationNumbers: [String]
    /// Référence matérielle du calculateur (HW Number)
    public let hardwareNumber: String?
    /// Référence logicielle du calculateur (SW Number / Version)
    public let softwareNumber: String?
    /// Protocole ayant fourni l'identification (`OBD2-Mode09`, `UDS-Service22`, `KWP2000-2180`)
    public let protocolSource: String

    public nonisolated init(
        calibrationIDs: [String],
        calibrationVerificationNumbers: [String] = [],
        hardwareNumber: String? = nil,
        softwareNumber: String? = nil,
        protocolSource: String
    ) {
        self.calibrationIDs = calibrationIDs
        self.calibrationVerificationNumbers = calibrationVerificationNumbers
        self.hardwareNumber = hardwareNumber
        self.softwareNumber = softwareNumber
        self.protocolSource = protocolSource
    }

    /// Identifiant de calibration principal
    public var primaryCalID: String? {
        calibrationIDs.first
    }

    /// Checksum CVN principal
    public var primaryCVN: String? {
        calibrationVerificationNumbers.first
    }

    /// Indique si une signature de reprogrammation (Stage 1, EGR/DPF off, CVN invalidé) est détectée
    public var isSuspiciousTuningDetected: Bool {
        let exactSubstringMarkers = [
            "STAGE1", "STAGE 1", "STAGE2", "STAGE 2", "STAGE3",
            "TUNED", "EGR_OFF", "EGROFF", "DPF_OFF", "DPFOFF",
            "FAP_OFF", "FAPOFF", "POPBANG", "NOREAD", "BFLASH",
            "AUTOTUNER", "WINOLS"
        ]
        let standaloneTokenMarkers: Set<String> = [
            "STAGE", "MOD", "EGR", "DPF", "FAP"
        ]

        let allText = (calibrationIDs + [hardwareNumber, softwareNumber].compactMap { $0 })
            .joined(separator: " ")
            .uppercased()

        if exactSubstringMarkers.contains(where: { allText.contains($0) }) {
            return true
        }

        let tokens = allText.components(separatedBy: CharacterSet.alphanumerics.inverted)
        if tokens.contains(where: { standaloneTokenMarkers.contains($0) }) {
            return true
        }

        for cal in calibrationIDs {
            let upper = cal.uppercased()
            if upper == "CAL-0000" || upper == "CAL-FFFF" || upper == "00000000" {
                return true
            }
        }

        for cvn in calibrationVerificationNumbers {
            let clean = cvn.uppercased().replacing(" ", with: "")
            if clean == "00000000" || clean == "FFFFFFFF" {
                return true
            }
        }

        return false
    }
}

/// Lecteur et décodeur multi-protocoles des identifiants de cartographie moteur (CalID, CVN, HW/SW).
public enum CalibrationReader: Sendable {

    /// Interroge le calculateur moteur pour extraire les identifiants de calibration (OBD-II Mode 09, UDS 0x22, KWP2000 0x2180).
    public static func read(interface: VehicleInterface) async throws -> ECUCalibrationInfo? {
        try Task.checkCancellation()

        // 1. Stage A : OBD-II Standard Mode 09 (PID 04 CalID + PID 06 CVN sur 0x7E0 -> 0x7E8)
        do {
            try Task.checkCancellation()
            try await interface.setTarget(txID: "7E0", rxID: "7E8")
            let rawCal = try? await interface.sendDiagnosticRequest("0904", timeout: 2.0)
            let calIDs = rawCal.map(parseOBD2CalID) ?? []

            let rawCVN = try? await interface.sendDiagnosticRequest("0906", timeout: 2.0)
            let cvns = rawCVN.map(parseOBD2CVN) ?? []

            if !calIDs.isEmpty || !cvns.isEmpty {
                return ECUCalibrationInfo(
                    calibrationIDs: calIDs,
                    calibrationVerificationNumbers: cvns,
                    hardwareNumber: nil,
                    softwareNumber: calIDs.first,
                    protocolSource: "OBD2-Mode09"
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {}

        // 2. Stage B : UDS ISO 14229 Service 0x22 (DID F198 / F182 CalID, F188 SW, F191 HW)
        do {
            try Task.checkCancellation()
            try await interface.setTarget(txID: "7E0", rxID: "7E8")
            let rawCal = try? await interface.sendDiagnosticRequest("22F198", timeout: 1.5)
            var calID = rawCal.flatMap { parseUDSIdentifier($0, did: "F198") }
            if calID == nil {
                let rawAppCal = try? await interface.sendDiagnosticRequest("22F182", timeout: 1.5)
                calID = rawAppCal.flatMap { parseUDSIdentifier($0, did: "F182") }
            }

            let rawSW = try? await interface.sendDiagnosticRequest("22F188", timeout: 1.5)
            let swNum = rawSW.flatMap { parseUDSIdentifier($0, did: "F188") }

            let rawHW = try? await interface.sendDiagnosticRequest("22F191", timeout: 1.5)
            let hwNum = rawHW.flatMap { parseUDSIdentifier($0, did: "F191") }

            let rawCVN = try? await interface.sendDiagnosticRequest("22F199", timeout: 1.5)
            let cvnHex = rawCVN.flatMap { parseUDSHexPayload($0, did: "F199") }

            var uniqueCals: [String] = []
            for candidate in [calID, swNum].compactMap({ $0 }) {
                if !uniqueCals.contains(candidate) {
                    uniqueCals.append(candidate)
                }
            }
            if !uniqueCals.isEmpty || hwNum != nil {
                return ECUCalibrationInfo(
                    calibrationIDs: uniqueCals,
                    calibrationVerificationNumbers: cvnHex.map { [$0] } ?? [],
                    hardwareNumber: hwNum,
                    softwareNumber: swNum,
                    protocolSource: "UDS-Service22"
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {}

        // 3. Stage C : Renault KWP2000 Service 21 LID 80 (Bloc d'identification constructeur 2180 sur 0x7E0 -> 0x7E8)
        do {
            try Task.checkCancellation()
            try await interface.setTarget(txID: "7E0", rxID: "7E8")
            _ = try? await openDiagnosticSession(interface: interface)
            if let raw2180 = try? await interface.sendDiagnosticRequest("2180", timeout: 2.0),
               let info = parseKWP2000Identification2180(raw2180) {
                await closeDiagnosticSession(interface: interface)
                return info
            }
            await closeDiagnosticSession(interface: interface)
        } catch is CancellationError {
            throw CancellationError()
        } catch {}

        return nil
    }

    // MARK: - Parsers Déterministes

    /// Décode une réponse OBD-II Mode 09 PID 04 (`49 04 <count> <16-byte ASCII blocks>`).
    public static func parseOBD2CalID(_ response: String) -> [String] {
        let concatenated = normalizeHexResponse(response)
        guard let headerRange = concatenated.range(of: "4904") else { return [] }

        let afterHeader = concatenated[headerRange.upperBound...]
        guard afterHeader.count >= 4 else { return [] }

        // Le premier octet après 4904 est le nombre d'éléments (ex: 01 ou 02)
        let dataStart = afterHeader.index(afterHeader.startIndex, offsetBy: 2)
        let dataHex = String(afterHeader[dataStart...])

        var results: [String] = []
        var idx = dataHex.startIndex
        while idx < dataHex.endIndex {
            let end = dataHex.index(idx, offsetBy: 32, limitedBy: dataHex.endIndex) ?? dataHex.endIndex
            let chunkHex = String(dataHex[idx..<end])
            let ascii = hexToPrintableAscii(chunkHex).trimmingCharacters(in: .whitespacesAndNewlines)
            if ascii.count >= 4 {
                results.append(ascii)
            }
            idx = end
        }
        return results
    }

    /// Décode une réponse OBD-II Mode 09 PID 06 (`49 06 <count> <4-byte CVN blocks>`).
    public static func parseOBD2CVN(_ response: String) -> [String] {
        let concatenated = normalizeHexResponse(response)
        guard let headerRange = concatenated.range(of: "4906") else { return [] }

        let afterHeader = concatenated[headerRange.upperBound...]
        guard afterHeader.count >= 10 else { return [] }

        let countHex = String(afterHeader.prefix(2))
        let expectedCount = Int(countHex, radix: 16) ?? 1

        let dataStart = afterHeader.index(afterHeader.startIndex, offsetBy: 2)
        let dataHex = String(afterHeader[dataStart...])

        var cvns: [String] = []
        var idx = dataHex.startIndex
        while idx < dataHex.endIndex, cvns.count < max(1, expectedCount) {
            guard let end = dataHex.index(idx, offsetBy: 8, limitedBy: dataHex.endIndex),
                  dataHex.distance(from: idx, to: end) == 8 else {
                break
            }
            let cvn = String(dataHex[idx..<end])
            if cvn.allSatisfy({ $0.isHexDigit }) {
                cvns.append(cvn)
            }
            idx = end
        }
        return cvns
    }

    /// Décode une réponse UDS Service 22 ASCII (`62 <DID> <ASCII bytes>`).
    public static func parseUDSIdentifier(_ response: String, did: String) -> String? {
        guard let payloadHex = parseUDSHexPayload(response, did: did) else { return nil }
        let ascii = hexToPrintableAscii(payloadHex).trimmingCharacters(in: .whitespacesAndNewlines)
        return ascii.count >= 3 ? ascii : nil
    }

    /// Extrait le payload hexadécimal brut d'une réponse UDS Service 22 (`62 <DID> ...`).
    public static func parseUDSHexPayload(_ response: String, did: String) -> String? {
        let concatenated = normalizeHexResponse(response)
        let cleanDID = did.uppercased().replacing(" ", with: "")
        guard let range = concatenated.range(of: "62" + cleanDID) else { return nil }
        let payload = String(concatenated[range.upperBound...])
        return payload.count >= 4 ? payload : nil
    }

    /// Décode le bloc d'identification constructeur Renault KWP2000 Service `21 80` (`61 80` + 20..24 octets).
    ///
    /// Structure officielle DDT2000 (Scénic II J84 / Modus J77 / Clio III / Mégane II) :
    /// - Octets 0..4 (10 hex) : Référence MPR Renault calculateur (ex: `8200592611`)
    /// - Octet 5 (2 hex) : Version diagnostic (`VDiag`)
    /// - Octets 6..8 (6 hex) : Code fournisseur (ex: Bosch / Siemens / Delphi)
    /// - Octets 9..13 (10 hex) : Numéro Hardware (`HW`)
    /// - Octets 14..15 (4 hex) : Numéro de programme (`Program`)
    /// - Octets 16..17 (4 hex) : Version logiciel (`SW Version`)
    /// - Octets 18..19 (4 hex) : Numéro de calibration (`CalID`)
    public static func parseKWP2000Identification2180(_ response: String) -> ECUCalibrationInfo? {
        let concatenated = normalizeHexResponse(response)
        guard let range = concatenated.range(of: "6180") else { return nil }

        let payload = String(concatenated[range.upperBound...])
        // Minimum 20 octets (40 caractères hex) pour couvrir jusqu'au numéro de calibration (bits 144..159)
        guard payload.count >= 40 else { return nil }

        let chars = Array(payload)
        let mprRef = String(chars[0..<10])
        let hwRef = String(chars[18..<28])
        let progNum = String(chars[28..<32])
        let swVer = String(chars[32..<36])
        let calNum = String(chars[36..<40])

        return ECUCalibrationInfo(
            calibrationIDs: ["CAL-\(calNum)"],
            calibrationVerificationNumbers: [],
            hardwareNumber: "HW-\(hwRef) (MPR \(mprRef))",
            softwareNumber: "SW-\(progNum)-V\(swVer)",
            protocolSource: "KWP2000-2180"
        )
    }

    // MARK: - Helpers Privés

    private static func normalizeHexResponse(_ response: String) -> String {
        response
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map(stripFrameIndex)
            .joined()
            .uppercased()
    }

    private static func stripFrameIndex(_ line: String) -> String {
        guard let colonIdx = line.firstIndex(of: ":") else { return line }
        let prefix = line[..<colonIdx]
        guard prefix.count <= 2, prefix.allSatisfy({ $0.isHexDigit }) else { return line }
        return String(line[line.index(after: colonIdx)...])
    }

    private static func hexToPrintableAscii(_ hex: String) -> String {
        var out = ""
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard hex.distance(from: idx, to: next) == 2 else { break }
            let pair = String(hex[idx..<next])
            if let byte = UInt8(pair, radix: 16), byte >= 0x20, byte < 0x7F {
                out.append(Character(UnicodeScalar(byte)))
            }
            idx = next
        }
        return out
    }

    private static func openDiagnosticSession(interface: VehicleInterface) async throws -> Bool {
        for sessionCmd in ["1085", "1086", "1003"] {
            if let res = try? await interface.sendDiagnosticRequest(sessionCmd, timeout: 1.0) {
                let normalized = res.uppercased().replacing(" ", with: "")
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
