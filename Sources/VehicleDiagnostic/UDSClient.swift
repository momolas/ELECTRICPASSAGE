import Foundation
import VehicleCore
import VehicleTransport

/// Client de diagnostic haut niveau pour le protocole UDS (ISO 14229-1).
public actor UDSClient {

    private let interface: VehicleInterface
    private var testerPresentTask: Task<Void, Never>?
    private var atomicTransactionDepth: Int = 0
    private var isAtomicTransactionActive: Bool { atomicTransactionDepth > 0 }

    public enum UDSError: LocalizedError, Sendable {
        case negativeResponse(service: UInt8, nrc: UInt8, message: String)
        case invalidResponseFormat(String)
        case sessionNotStarted
        case timeout
        case transportError(String)

        public var errorDescription: String? {
            switch self {
            case let .negativeResponse(service, nrc, msg):
                let nrcHex = String(format: "%02X", nrc)
                let srvHex = String(format: "%02X", service)
                return "UDS Réponse Négative [Service 0x\(srvHex), NRC 0x\(nrcHex)]: \(msg)"
            case let .invalidResponseFormat(raw):
                return "Format de réponse UDS invalide: \(raw)"
            case .sessionNotStarted:
                return "La session UDS n'est pas ouverte."
            case .timeout:
                return "Délai d'attente de réponse UDS dépassé."
            case let .transportError(msg):
                return "Erreur transport: \(msg)"
            }
        }
    }

    public enum ResetType: UInt8, Sendable {
        case hardReset = 0x01
        case keyOffOnReset = 0x02
        case softReset = 0x03
        case enableRapidPowerShutDown = 0x04
        case disableRapidPowerShutDown = 0x05
    }

    public enum IOControlType: UInt8, Sendable {
        case returnControlToECU = 0x00
        case resetToDefault = 0x01
        case freezeCurrentState = 0x02
        case shortTermAdjustment = 0x03
    }

    public enum DTCReportType: UInt8, Sendable {
        case reportNumberOfDTCByStatusMask = 0x01
        case reportDTCByStatusMask = 0x02
        case reportDTCSnapshotIdentification = 0x03
        case reportDTCSnapshotRecordByDTCNumber = 0x04
        case reportDTCExtendedDataRecordByDTCNumber = 0x06
        case reportSupportedDTC = 0x0A
    }

    public init(interface: VehicleInterface) {
        self.interface = interface
    }

    deinit {
        testerPresentTask?.cancel()
    }

    public func stop() {
        testerPresentTask?.cancel()
        testerPresentTask = nil
    }

    // MARK: - DiagnosticSessionControl (0x10)

    @discardableResult
    public func startSession(sessionType: UInt8, keepAlive: Bool = true) async throws -> String {
        let hexCmd = String(format: "10%02X", sessionType)
        let response = try await sendRaw(hexCmd)
        try validatePositiveResponse(response, expectedSID: 0x10)

        if keepAlive {
            startTesterPresentLoop()
        }
        return response
    }

    // MARK: - ECUReset (0x11)

    public func ecuReset(type: ResetType = .hardReset) async throws {
        let hexCmd = String(format: "11%02X", type.rawValue)
        let response = try await sendRaw(hexCmd)
        try validatePositiveResponse(response, expectedSID: 0x11)
    }

    // MARK: - ClearDiagnosticInformation (0x14)

    public func clearDiagnosticInformation(groupOfDTC: UInt32 = 0xFFFFFF) async throws {
        let hexCmd = String(format: "14%06X", groupOfDTC & 0xFFFFFF)
        let response = try await sendRaw(hexCmd)
        try validatePositiveResponse(response, expectedSID: 0x14)
    }

    // MARK: - ReadDTCInformation (0x19)

    public func readDTCInformation(reportType: DTCReportType = .reportDTCByStatusMask, statusMask: DTCStatusMask = .all) async throws -> [DecodedDTC] {
        let hexCmd = String(format: "19%02X%02X", reportType.rawValue, statusMask.rawValue)
        let response = try await sendRaw(hexCmd)
        try validatePositiveResponse(response, expectedSID: 0x19)
        return DTCDecoder.decodeDTCsWithStatus(from: response)
    }

    // MARK: - ReadDataByIdentifier (0x22)

    public func readDataByIdentifier(_ did: UInt16) async throws -> String {
        let hexCmd = String(format: "22%04X", did)
        let response = try await sendRaw(hexCmd)
        try validatePositiveResponse(response, expectedSID: 0x22)
        
        let clean = response.replacing( " ", with: "")
        // Enlève 62 + DID (6 caractères)
        guard clean.count >= 6 else { return "" }
        return String(clean.dropFirst(6))
    }

    // MARK: - WriteDataByIdentifier (0x2E)

    public func writeDataByIdentifier(_ did: UInt16, dataHex: String) async throws {
        let cleanData = dataHex.replacing( " ", with: "")
        let hexCmd = String(format: "2E%04X%@", did, cleanData)
        let response = try await sendRaw(hexCmd)
        try validatePositiveResponse(response, expectedSID: 0x2E)
    }

    // MARK: - Transactions Atomiques & Isolation de Keepalive

    public func withAtomicTransaction<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        atomicTransactionDepth += 1
        defer { atomicTransactionDepth -= 1 }
        return try await operation()
    }

    // MARK: - SecurityAccess (0x27)

    public func performSecurityAccess(
        level: UInt8,
        keyCalculation: @Sendable (String) async throws -> String
    ) async throws {
        atomicTransactionDepth += 1
        defer { atomicTransactionDepth -= 1 }

        // 1. Request Seed (27 + Odd Subfunction)
        let requestLevel = level % 2 == 0 ? level - 1 : level
        let seedCmd = String(format: "27%02X", requestLevel)
        let seedResponse = try await sendRaw(seedCmd)
        try validatePositiveResponse(seedResponse, expectedSID: 0x27)

        let cleanSeedResp = seedResponse.replacing(" ", with: "")
        guard cleanSeedResp.count >= 4 else {
            throw UDSError.invalidResponseFormat("Graine UDS trop courte: \(seedResponse)")
        }
        let seed = String(cleanSeedResp.dropFirst(4))

        // Si la graine est déjà zéro, l'accès est déjà déverrouillé
        if seed.allSatisfy({ $0 == "0" }) {
            return
        }

        // 2. Send Key (27 + Even Subfunction)
        let key = try await keyCalculation(seed)
        let sendKeyLevel = requestLevel + 1
        let keyCmd = String(format: "27%02X%@", sendKeyLevel, key)
        let keyResponse = try await sendRaw(keyCmd)
        try validatePositiveResponse(keyResponse, expectedSID: 0x27)
    }

    // MARK: - CommunicationControl (0x28)

    public func communicationControl(controlType: UInt8 = 0x00, communicationType: UInt8 = 0x01) async throws {
        let hexCmd = String(format: "28%02X%02X", controlType, communicationType)
        let response = try await sendRaw(hexCmd)
        try validatePositiveResponse(response, expectedSID: 0x28)
    }

    // MARK: - InputOutputControlByIdentifier (0x2F)

    public func inputOutputControl(did: UInt16, controlType: IOControlType, controlState: String = "") async throws -> String {
        let cleanState = controlState.replacing(" ", with: "")
        let hexCmd = String(format: "2F%04X%02X%@", did, controlType.rawValue, cleanState)
        let response = try await sendRaw(hexCmd)
        try validatePositiveResponse(response, expectedSID: 0x2F)
        return response
    }

    // MARK: - RoutineControl (0x31)

    public func startRoutine(routineType: UInt8 = 0x01, routineId: UInt16, optionHex: String = "") async throws -> String {
        let cleanOption = optionHex.replacing(" ", with: "")
        let hexCmd = String(format: "31%02X%04X%@", routineType, routineId, cleanOption)
        let response = try await sendRaw(hexCmd)
        try validatePositiveResponse(response, expectedSID: 0x31)
        return response
    }

    // MARK: - ControlDTCSetting (0x85)

    public func controlDTCSetting(enabled: Bool) async throws {
        let subFunction: UInt8 = enabled ? 0x01 : 0x02 // 01 = on, 02 = off
        let hexCmd = String(format: "85%02X", subFunction)
        let response = try await sendRaw(hexCmd)
        try validatePositiveResponse(response, expectedSID: 0x85)
    }

    // MARK: - TesterPresent Loop (0x3E)

    private func startTesterPresentLoop() {
        testerPresentTask?.cancel()
        testerPresentTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { break }
                await self.sendTesterPresent()
            }
        }
    }

    private func sendTesterPresent() async {
        guard !isAtomicTransactionActive else { return }
        _ = try? await self.interface.sendDiagnosticRequest("3E80", timeout: 0.5)
    }

    // MARK: - Raw Transfer Helpers

    private func sendRaw(_ hex: String) async throws -> String {
        do {
            let res = try await interface.sendDiagnosticRequest(hex, timeout: 2.0)
            return res.replacing( " ", with: "")
        } catch {
            throw UDSError.transportError(error.localizedDescription)
        }
    }

    private func validatePositiveResponse(_ responseHex: String, expectedSID: UInt8) throws {
        let clean = responseHex.replacing( " ", with: "").uppercased()

        if clean.hasPrefix("7F") {
            guard clean.count >= 6 else {
                throw UDSError.invalidResponseFormat(clean)
            }
            let service = UInt8(clean.dropFirst(2).prefix(2), radix: 16) ?? 0
            let nrc = UInt8(clean.dropFirst(4).prefix(2), radix: 16) ?? 0
            let msg = UDSNRC(rawValue: nrc)?.title ?? UDSNRC.description(for: nrc)
            throw UDSError.negativeResponse(service: service, nrc: nrc, message: msg)
        }

        let expectedPositiveSID = String(format: "%02X", expectedSID + 0x40)
        guard clean.hasPrefix(expectedPositiveSID) else {
            throw UDSError.invalidResponseFormat("Réponse inattendue (attendu: \(expectedPositiveSID)..., reçu: \(clean))")
        }
    }
}
