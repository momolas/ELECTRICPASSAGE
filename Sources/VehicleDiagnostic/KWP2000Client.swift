import Foundation
import VehicleCore
import VehicleTransport

/// Paramètres temporels de communication selon ISO 14230-3 (KWP2000)
public struct KWP2000TimingParameters: Sendable, Equatable {
    public var p2MinMs: Int
    public var p2MaxMs: Int
    public var p3MinMs: Int
    public var p3MaxMs: Int
    public var p4MinMs: Int

    public init(
        p2MinMs: Int = 25,
        p2MaxMs: Int = 50,
        p3MinMs: Int = 55,
        p3MaxMs: Int = 5000,
        p4MinMs: Int = 0
    ) {
        self.p2MinMs = p2MinMs
        self.p2MaxMs = p2MaxMs
        self.p3MinMs = p3MinMs
        self.p3MaxMs = p3MaxMs
        self.p4MinMs = p4MinMs
    }

    public static func decode(from hexString: String) -> KWP2000TimingParameters? {
        guard let bytes = HexParsing.bytes(hexString), bytes.count >= 6 else { return nil }
        let p2Min = Int(bytes[1]) * 1
        let p2Max = Int(bytes[2]) * 10
        let p3Min = Int(bytes[3]) * 1
        let p3Max = Int(bytes[4]) * 250
        let p4Min = Int(bytes[5]) * 1

        return KWP2000TimingParameters(
            p2MinMs: p2Min,
            p2MaxMs: p2Max,
            p3MinMs: p3Min,
            p3MaxMs: p3Max,
            p4MinMs: p4Min
        )
    }

    public func encode() -> String {
        let b1 = UInt8(clamping: p2MinMs / 1)
        let b2 = UInt8(clamping: p2MaxMs / 10)
        let b3 = UInt8(clamping: p3MinMs / 1)
        let b4 = UInt8(clamping: p3MaxMs / 250)
        let b5 = UInt8(clamping: p4MinMs / 1)
        return HexParsing.hex([0x03, b1, b2, b3, b4, b5])
    }
}

/// Erreurs KWP2000 (ISO 14230)
public enum KWP2000Error: Error, LocalizedError, Sendable {
    case negativeResponse(service: UInt8, nrc: UInt8)
    case unexpectedResponse(expected: String, received: String)
    case invalidSeedFormat
    case noResponse
    case timeout

    public var errorDescription: String? {
        switch self {
        case .negativeResponse(let service, let nrc):
            let nrcInfo = UDSNRC.parse(from: String(format: "7F%02X%02X", service, nrc))
            let title = nrcInfo?.title ?? "Erreur inconnue"
            return "Réponse négative KWP2000 pour le service 0x\(String(format: "%02X", service)) (NRC 0x\(String(format: "%02X", nrc)) : \(title))"
        case .unexpectedResponse(let expected, let received):
            return "Réponse inattendue de l'ECU. Attendu: \(expected), Reçu: \(received)"
        case .invalidSeedFormat:
            return "Format du Seed de sécurité invalide reçu de l'ECU"
        case .noResponse:
            return "Aucune réponse de l'ECU"
        case .timeout:
            return "Délai d'attente dépassé pour la réponse KWP2000"
        }
    }
}

/// Gère les opérations de diagnostic avancées via le protocole KWP2000 (ISO 14230).
public actor KWP2000Client {
    private let interface: VehicleInterface
    private var testerPresentTask: Task<Void, Never>?
    private var atomicTransactionDepth: Int = 0
    private var isAtomicTransactionActive: Bool { atomicTransactionDepth > 0 }

    deinit {
        testerPresentTask?.cancel()
    }

    public init(interface: VehicleInterface) {
        self.interface = interface
    }

    /// Démarre une session de diagnostic KWP2000 (Service 10)
    public func startSession(mode: UInt8) async throws -> String {
        stopTesterPresent()
        let hexMode = String(format: "%02X", mode)
        let command = "10" + hexMode
        let response = try await sendRequest(command, timeout: 2.0)
        let cleanResponse = normalizeResponse(response, service: 0x10)

        if cleanResponse.hasPrefix("7F10") {
            let nrcByte = UInt8(cleanResponse.dropFirst(4).prefix(2), radix: 16) ?? 0
            throw KWP2000Error.negativeResponse(service: 0x10, nrc: nrcByte)
        }

        let expectedResponse = String(format: "50%02X", mode)
        guard cleanResponse.hasPrefix(expectedResponse) else {
            throw KWP2000Error.unexpectedResponse(expected: expectedResponse, received: response)
        }

        if mode != 0x81 && !Task.isCancelled {
            startTesterPresent()
        } else {
            stopTesterPresent()
        }

        VehicleLogger.shared.info(.diagnostic, "KWP2000 StartDiagnosticSession (0x10) active: mode 0x\(hexMode)")
        return cleanResponse
    }

    /// Lit un paramètre local (LID) via le Service 21 (Read Data By Local Identifier)
    public func readLocalIdentifier(lid: UInt8) async throws -> String {
        let hexLid = String(format: "%02X", lid)
        let command = "21" + hexLid
        let response = try await sendRequest(command, timeout: 1.5)
        let cleanResponse = normalizeResponse(response, service: 0x21)

        if cleanResponse.hasPrefix("7F21") {
            let nrcByte = UInt8(cleanResponse.dropFirst(4).prefix(2), radix: 16) ?? 0
            throw KWP2000Error.negativeResponse(service: 0x21, nrc: nrcByte)
        }

        let expectedResponse = "61" + hexLid
        guard cleanResponse.hasPrefix(expectedResponse) else {
            throw KWP2000Error.unexpectedResponse(expected: expectedResponse, received: response)
        }

        return String(cleanResponse.dropFirst(4))
    }

    /// Écrit un paramètre local (LID) via le Service 3B (Write Data By Local Identifier)
    public func writeLocalIdentifier(lid: UInt8, data: String) async throws -> String {
        let hexLid = String(format: "%02X", lid)
        let cleanData = data.replacing(" ", with: "")
        let command = "3B" + hexLid + cleanData
        let response = try await sendRequest(command, timeout: 2.0)
        let cleanResponse = normalizeResponse(response, service: 0x3B)

        if cleanResponse.hasPrefix("7F3B") {
            let nrcByte = UInt8(cleanResponse.dropFirst(4).prefix(2), radix: 16) ?? 0
            throw KWP2000Error.negativeResponse(service: 0x3B, nrc: nrcByte)
        }

        let expectedResponse = "7B" + hexLid
        guard cleanResponse.hasPrefix(expectedResponse) else {
            throw KWP2000Error.unexpectedResponse(expected: expectedResponse, received: response)
        }

        return cleanResponse
    }

    /// Effectue la routine SecurityAccess (Service 27) de manière atomique sans interférence TesterPresent.
    public func performSecurityAccess(level: UInt8, keyCalculator: @Sendable (String) -> String) async throws {
        guard level >= 1 && level < 0xFF else {
            throw KWP2000Error.invalidSeedFormat
        }
        atomicTransactionDepth += 1
        defer { atomicTransactionDepth = max(0, atomicTransactionDepth - 1) }

        let requestSeedCmd = String(format: "27%02X", level)
        let seedResponse = try await sendRequest(requestSeedCmd, timeout: 2.0)
        let cleanSeedResp = normalizeResponse(seedResponse, service: 0x27)

        if cleanSeedResp.hasPrefix("7F27") {
            let nrcByte = UInt8(cleanSeedResp.dropFirst(4).prefix(2), radix: 16) ?? 0
            throw KWP2000Error.negativeResponse(service: 0x27, nrc: nrcByte)
        }

        let expectedSeedHeader = String(format: "67%02X", level)
        guard cleanSeedResp.hasPrefix(expectedSeedHeader) else {
            throw KWP2000Error.unexpectedResponse(expected: expectedSeedHeader, received: seedResponse)
        }

        let seed = String(cleanSeedResp.dropFirst(4))
        guard !seed.isEmpty else {
            throw KWP2000Error.invalidSeedFormat
        }
        if seed.allSatisfy({ $0 == "0" }) {
            return
        }

        let calculatedKey = keyCalculator(seed).replacing(" ", with: "").uppercased()
        let sendKeyCmd = String(format: "27%02X", level + 1) + calculatedKey
        let keyResponse = try await sendRequest(sendKeyCmd, timeout: 2.0)
        let cleanKeyResp = normalizeResponse(keyResponse, service: 0x27)

        if cleanKeyResp.hasPrefix("7F27") {
            let nrcByte = UInt8(cleanKeyResp.dropFirst(4).prefix(2), radix: 16) ?? 0
            throw KWP2000Error.negativeResponse(service: 0x27, nrc: nrcByte)
        }

        let expectedKeyHeader = String(format: "67%02X", level + 1)
        guard cleanKeyResp.hasPrefix(expectedKeyHeader) else {
            throw KWP2000Error.unexpectedResponse(expected: expectedKeyHeader, received: keyResponse)
        }
    }

    /// Exécute une opération atomique sur le bus KWP2000 (ex: upload/download mémoire)
    /// en suspendant l'envoi de trames TesterPresent susceptibles de polluer la séquence.
    public func withAtomicTransaction<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        atomicTransactionDepth += 1
        defer { atomicTransactionDepth = max(0, atomicTransactionDepth - 1) }
        return try await operation()
    }

    /// Lit l'identification ECU (Service 1A)
    public func readECUIdentification(option: UInt8 = 0x80) async throws -> String {
        let command = String(format: "1A%02X", option)
        let response = try await sendRequest(command, timeout: 2.0)
        let clean = normalizeResponse(response, service: 0x1A)

        if clean.hasPrefix("7F1A") {
            let nrc = UInt8(clean.dropFirst(4).prefix(2), radix: 16) ?? 0
            throw KWP2000Error.negativeResponse(service: 0x1A, nrc: nrc)
        }

        let expected = String(format: "5A%02X", option)
        guard clean.hasPrefix(expected) else {
            throw KWP2000Error.unexpectedResponse(expected: expected, received: response)
        }

        return String(clean.dropFirst(4))
    }

    /// Efface la mémoire des défauts (Service 14) selon ISO 14230 (groupe 2 octets, ex: "FF00")
    public func clearDiagnosticInformation(group: String = "FF00") async throws {
        let command = "14" + group.replacing(" ", with: "").uppercased()
        let response = try await sendRequest(command, timeout: 3.0)
        let clean = normalizeResponse(response, service: 0x14)

        if clean.hasPrefix("7F14") {
            let nrc = UInt8(clean.dropFirst(4).prefix(2), radix: 16) ?? 0
            throw KWP2000Error.negativeResponse(service: 0x14, nrc: nrc)
        }

        guard clean.hasPrefix("54") else {
            throw KWP2000Error.unexpectedResponse(expected: "54", received: response)
        }
    }

    /// Lit les DTCs par masque de statut (Service 18)
    public func readDTCByStatus(statusMask: UInt8 = 0x02, group: String = "FF00") async throws -> String {
        let command = String(format: "18%02X", statusMask) + group.replacing(" ", with: "").uppercased()
        let response = try await sendRequest(command, timeout: 3.0)
        let clean = normalizeResponse(response, service: 0x18)

        if clean.hasPrefix("7F18") {
            let nrc = UInt8(clean.dropFirst(4).prefix(2), radix: 16) ?? 0
            throw KWP2000Error.negativeResponse(service: 0x18, nrc: nrc)
        }

        guard clean.hasPrefix("58") else {
            throw KWP2000Error.unexpectedResponse(expected: "58", received: response)
        }

        return clean
    }

    /// Maintien de session (Service 3E - Tester Present)
    public func sendTesterPresent(suppressResponse: Bool = false) async throws {
        guard !isAtomicTransactionActive else { return }
        let command = suppressResponse ? "3E80" : "3E00"
        let response = try await interface.sendDiagnosticRequest(command, timeout: 1.0)
        let clean = normalizeResponse(response, service: 0x3E)

        if !suppressResponse {
            if clean.hasPrefix("7F3E") {
                let nrc = UInt8(clean.dropFirst(4).prefix(2), radix: 16) ?? 0
                throw KWP2000Error.negativeResponse(service: 0x3E, nrc: nrc)
            }
            guard clean.hasPrefix("7E") else {
                throw KWP2000Error.unexpectedResponse(expected: "7E00", received: response)
            }
        }
    }

    private func startTesterPresent() {
        stopTesterPresent()
        testerPresentTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self = self, !Task.isCancelled else { break }
                try? await self.sendTesterPresent(suppressResponse: true)
            }
        }
    }

    public func stopTesterPresent() {
        testerPresentTask?.cancel()
        testerPresentTask = nil
    }

    /// Requête d'upload de mémoire (Service 35 - Request Upload)
    public func requestUpload(
        memoryAddress: UInt32,
        uncompressedSize: UInt32,
        dataFormatIdentifier: UInt8? = nil
    ) async throws -> String {
        let addrHex = String(format: "%06X", memoryAddress & 0xFFFFFF)
        let dfiHex = dataFormatIdentifier.map { String(format: "%02X", $0) } ?? ""
        let sizeHex = String(format: "%06X", uncompressedSize & 0xFFFFFF)
        let command = "35" + addrHex + dfiHex + sizeHex
        let response = try await sendRequest(command, timeout: 3.0)
        let clean = normalizeResponse(response, service: 0x35)

        if clean.hasPrefix("7F35") {
            let nrc = UInt8(clean.dropFirst(4).prefix(2), radix: 16) ?? 0
            throw KWP2000Error.negativeResponse(service: 0x35, nrc: nrc)
        }
        guard clean.hasPrefix("75") else {
            throw KWP2000Error.unexpectedResponse(expected: "75", received: response)
        }
        return clean
    }

    /// Requête de téléchargement / flash de mémoire (Service 34 - Request Download)
    public func requestDownload(
        memoryAddress: UInt32,
        uncompressedSize: UInt32,
        dataFormatIdentifier: UInt8? = nil
    ) async throws -> String {
        let addrHex = String(format: "%06X", memoryAddress & 0xFFFFFF)
        let dfiHex = dataFormatIdentifier.map { String(format: "%02X", $0) } ?? ""
        let sizeHex = String(format: "%06X", uncompressedSize & 0xFFFFFF)
        let command = "34" + addrHex + dfiHex + sizeHex
        let response = try await sendRequest(command, timeout: 3.0)
        let clean = normalizeResponse(response, service: 0x34)

        if clean.hasPrefix("7F34") {
            let nrc = UInt8(clean.dropFirst(4).prefix(2), radix: 16) ?? 0
            throw KWP2000Error.negativeResponse(service: 0x34, nrc: nrc)
        }
        guard clean.hasPrefix("74") else {
            throw KWP2000Error.unexpectedResponse(expected: "74", received: response)
        }
        return clean
    }

    /// Lecture directe d'une plage mémoire par adresse (Service 23 - ReadMemoryByAddress KWP2000)
    public func readMemoryByAddress(memoryAddress: UInt32, memorySize: UInt8) async throws -> Data {
        let addrHex = String(format: "%06X", memoryAddress & 0xFFFFFF)
        let sizeHex = String(format: "%02X", memorySize)
        let command = "23" + addrHex + sizeHex
        let response = try await sendRequest(command, timeout: 3.0)
        let clean = normalizeResponse(response, service: 0x23)

        if clean.hasPrefix("7F23") {
            let nrc = UInt8(clean.dropFirst(4).prefix(2), radix: 16) ?? 0
            throw KWP2000Error.negativeResponse(service: 0x23, nrc: nrc)
        }
        guard clean.hasPrefix("63") else {
            throw KWP2000Error.unexpectedResponse(expected: "63", received: response)
        }
        let payloadHex = String(clean.dropFirst(2))
        return Data(HexParsing.bytes(payloadHex) ?? [])
    }

    /// Transfert d'un bloc de données (Service 36 - Transfer Data)
    public func transferData(blockSequenceCounter: UInt8, payload: String = "") async throws -> String {
        let blockHex = String(format: "%02X", blockSequenceCounter)
        let cleanPayload = payload.replacing(" ", with: "").uppercased()
        let command = "36" + blockHex + cleanPayload
        let response = try await sendRequest(command, timeout: 4.0)
        let clean = normalizeResponse(response, service: 0x36)

        if clean.hasPrefix("7F36") {
            let nrc = UInt8(clean.dropFirst(4).prefix(2), radix: 16) ?? 0
            throw KWP2000Error.negativeResponse(service: 0x36, nrc: nrc)
        }
        guard clean.hasPrefix("76") else {
            throw KWP2000Error.unexpectedResponse(expected: "76", received: response)
        }
        return clean
    }

    /// Transfert d'un bloc binaire typé `Data` (Service 36 - Transfer Data) avec extraction automatique des octets reçus.
    @discardableResult
    public func transferDataBytes(blockSequenceCounter: UInt8, payload: Data = Data()) async throws -> Data {
        let payloadHex = HexParsing.hex([UInt8](payload))
        let clean = try await transferData(blockSequenceCounter: blockSequenceCounter, payload: payloadHex)
        let afterSID = String(clean.dropFirst(2))
        let bscHex = String(format: "%02X", blockSequenceCounter)
        let dataHex: String
        if afterSID.hasPrefix(bscHex) {
            dataHex = String(afterSID.dropFirst(2))
        } else {
            dataHex = afterSID
        }
        return Data(HexParsing.bytes(dataHex) ?? [])
    }

    /// Sortie du mode transfert (Service 37 - Request Transfer Exit)
    public func requestTransferExit() async throws -> String {
        let response = try await sendRequest("37", timeout: 2.0)
        let clean = normalizeResponse(response, service: 0x37)

        if clean.hasPrefix("7F37") {
            let nrc = UInt8(clean.dropFirst(4).prefix(2), radix: 16) ?? 0
            throw KWP2000Error.negativeResponse(service: 0x37, nrc: nrc)
        }
        guard clean.hasPrefix("77") else {
            throw KWP2000Error.unexpectedResponse(expected: "77", received: response)
        }
        return clean
    }

    /// Exécute une routine de diagnostic (Service 31 - Routine Control)
    public func startRoutine(routineType: UInt8 = 0x01, routineId: UInt16, options: String = "") async throws -> String {
        let cmdType = String(format: "%02X", routineType)
        let cmdId = String(format: "%04X", routineId)
        let cleanOptions = options.replacing(" ", with: "").uppercased()
        let command = "31" + cmdType + cmdId + cleanOptions
        let response = try await sendRequest(command, timeout: 4.0)
        let clean = normalizeResponse(response, service: 0x31)

        if clean.hasPrefix("7F31") {
            let nrc = UInt8(clean.dropFirst(4).prefix(2), radix: 16) ?? 0
            throw KWP2000Error.negativeResponse(service: 0x31, nrc: nrc)
        }
        guard clean.hasPrefix("71") else {
            throw KWP2000Error.unexpectedResponse(expected: "71", received: response)
        }
        return clean
    }

    /// Redémarrage du calculateur (Service 11 - ECU Reset)
    public func ecuReset(resetType: UInt8 = 0x01) async throws {
        let command = String(format: "11%02X", resetType)
        let response = try await sendRequest(command, timeout: 2.0)
        let clean = normalizeResponse(response, service: 0x11)

        if clean.hasPrefix("7F11") {
            let nrc = UInt8(clean.dropFirst(4).prefix(2), radix: 16) ?? 0
            throw KWP2000Error.negativeResponse(service: 0x11, nrc: nrc)
        }
        guard clean.hasPrefix("51") else {
            throw KWP2000Error.unexpectedResponse(expected: "51", received: response)
        }
    }

    private func sendRequest(_ command: String, timeout: TimeInterval) async throws -> String {
        atomicTransactionDepth += 1
        defer { atomicTransactionDepth = max(0, atomicTransactionDepth - 1) }
        return try await interface.sendDiagnosticRequest(command, timeout: timeout)
    }

    private func normalizeResponse(_ response: String, service: UInt8) -> String {
        var clean = HexParsing.stripISOTPFraming(response)
            .replacing(" ", with: "")
            .replacing("\n", with: "")
            .replacing("\r", with: "")
            .uppercased()
        let pendingPrefix = String(format: "7F%02X78", service)
        while clean.hasPrefix(pendingPrefix) && clean.count > 6 {
            clean = String(clean.dropFirst(6))
        }
        return clean
    }

    nonisolated public func stop() {
        Task {
            await stopTesterPresent()
        }
    }
}
