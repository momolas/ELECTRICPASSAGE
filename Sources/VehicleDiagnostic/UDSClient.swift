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
        stopTesterPresent()
    }

    public func stopTesterPresent() {
        testerPresentTask?.cancel()
        testerPresentTask = nil
    }

    // MARK: - DiagnosticSessionControl (0x10)

    @discardableResult
    public func startSession(sessionType: UInt8, keepAlive: Bool = true) async throws -> String {
        let hexCmd = String(format: "10%02X", sessionType)
        let response = try await sendRaw(hexCmd)
        try validatePositiveResponse(response, expectedSID: 0x10)

        if keepAlive && sessionType != 0x01 {
            startTesterPresentLoop()
        } else {
            stopTesterPresent()
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
        
        let clean = response.replacing(" ", with: "")
        // Enlève 62 + DID (6 caractères)
        guard clean.count >= 6 else { return "" }
        return String(clean.dropFirst(6))
    }

    // MARK: - WriteDataByIdentifier (0x2E)

    public func writeDataByIdentifier(_ did: UInt16, dataHex: String) async throws {
        let cleanData = dataHex.replacing(" ", with: "")
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
        guard requestLevel < 0xFF else {
            throw UDSError.invalidResponseFormat("Niveau SecurityAccess invalide: 0x\(String(format: "%02X", level))")
        }
        let seedCmd = String(format: "27%02X", requestLevel)
        let seedResponse = try await sendRaw(seedCmd)
        try validatePositiveResponse(seedResponse, expectedSID: 0x27)

        let cleanSeedResp = seedResponse.replacing(" ", with: "")
        guard cleanSeedResp.count >= 4 else {
            throw UDSError.invalidResponseFormat("Graine UDS trop courte: \(seedResponse)")
        }
        let seed = String(cleanSeedResp.dropFirst(4))
        guard !seed.isEmpty else {
            throw UDSError.invalidResponseFormat("Graine UDS vide: \(seedResponse)")
        }

        // Si la graine est déjà zéro, l'accès est déjà déverrouillé
        if seed.allSatisfy({ $0 == "0" }) {
            return
        }

        // 2. Send Key (27 + Even Subfunction)
        let rawKey = try await keyCalculation(seed)
        let key = rawKey.replacing(" ", with: "").uppercased()
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
        let response = try await sendRaw(hexCmd, timeout: 6.0)
        try validatePositiveResponse(response, expectedSID: 0x31)
        return response
    }

    /// Effacement d'une plage mémoire Flash via RoutineControl (0x31 01 FF00).
    @discardableResult
    public func eraseMemory(memoryAddress: UInt32, memorySize: UInt32, addressAndLengthFormatIdentifier: UInt8 = 0x44) async throws -> String {
        let options = String(format: "%02X%08X%08X", addressAndLengthFormatIdentifier, memoryAddress, memorySize)
        return try await startRoutine(routineType: 0x01, routineId: 0xFF00, optionHex: options)
    }

    /// Vérification d'intégrité et du Checksum post-programmation (0x31 01 FF01 / 0202).
    @discardableResult
    public func checkProgrammingDependencies(routineId: UInt16 = 0xFF01, checksumHex: String = "") async throws -> String {
        return try await startRoutine(routineType: 0x01, routineId: routineId, optionHex: checksumHex)
    }

    // MARK: - ReadMemoryByAddress (0x23) & Memory Upload / Download (0x34 / 0x35 / 0x36 / 0x37)

    /// Lecture directe d'une zone mémoire par adresse (Service 0x23).
    /// Par défaut `addressAndLengthFormatIdentifier = 0x24` (adresse 32 bits, longueur 16 bits).
    public func readMemoryByAddress(
        memoryAddress: UInt32,
        memorySize: UInt16,
        addressAndLengthFormatIdentifier: UInt8 = 0x24
    ) async throws -> Data {
        let addrBytes = Int(addressAndLengthFormatIdentifier & 0x0F)
        let sizeBytes = Int((addressAndLengthFormatIdentifier >> 4) & 0x0F)
        let addrHex: String
        switch addrBytes {
        case 3: addrHex = String(format: "%06X", memoryAddress & 0xFFFFFF)
        default: addrHex = String(format: "%08X", memoryAddress)
        }
        let sizeHex: String
        switch sizeBytes {
        case 1: sizeHex = String(format: "%02X", memorySize & 0xFF)
        default: sizeHex = String(format: "%04X", memorySize)
        }
        let hexCmd = String(format: "23%02X%@%@", addressAndLengthFormatIdentifier, addrHex, sizeHex)
        let response = try await sendRaw(hexCmd, timeout: 4.0)
        try validatePositiveResponse(response, expectedSID: 0x23)

        let payloadHex = String(response.dropFirst(2))
        return Data(HexParsing.bytes(payloadHex) ?? [])
    }

    /// Requête d'autorisation d'écriture en mémoire Flash (Service 0x34 - RequestDownload).
    /// Retourne la taille maximale de bloc (`maxNumberOfBlockLength`) négociée avec l'ECU.
    public func requestDownload(
        memoryAddress: UInt32,
        uncompressedSize: UInt32,
        dataFormatIdentifier: UInt8 = 0x00,
        addressAndLengthFormatIdentifier: UInt8 = 0x44
    ) async throws -> Int {
        let hexCmd = String(
            format: "34%02X%02X%08X%08X",
            dataFormatIdentifier,
            addressAndLengthFormatIdentifier,
            memoryAddress,
            uncompressedSize
        )
        let response = try await sendRaw(hexCmd, timeout: 4.0)
        try validatePositiveResponse(response, expectedSID: 0x34)
        return Self.parseMaxBlockLength(from: response, defaultLength: 1024)
    }

    /// Requête d'extraction / lecture de mémoire Flash (Service 0x35 - RequestUpload).
    /// Retourne la taille maximale de bloc (`maxNumberOfBlockLength`) négociée avec l'ECU.
    public func requestUpload(
        memoryAddress: UInt32,
        uncompressedSize: UInt32,
        dataFormatIdentifier: UInt8 = 0x00,
        addressAndLengthFormatIdentifier: UInt8 = 0x44
    ) async throws -> Int {
        let hexCmd = String(
            format: "35%02X%02X%08X%08X",
            dataFormatIdentifier,
            addressAndLengthFormatIdentifier,
            memoryAddress,
            uncompressedSize
        )
        let response = try await sendRaw(hexCmd, timeout: 4.0)
        try validatePositiveResponse(response, expectedSID: 0x35)
        return Self.parseMaxBlockLength(from: response, defaultLength: 1024)
    }

    /// Transfert d'un bloc de données en lecture ou écriture (Service 0x36 - TransferData).
    @discardableResult
    public func transferData(
        blockSequenceCounter: UInt8,
        payload: Data = Data()
    ) async throws -> Data {
        let payloadHex = HexParsing.hex([UInt8](payload))
        let hexCmd = String(format: "36%02X%@", blockSequenceCounter, payloadHex)
        let response = try await sendRaw(hexCmd, timeout: 5.0)
        try validatePositiveResponse(response, expectedSID: 0x36)

        // Réponse 76 [BSC] [Données optionnelles] ou 76 [Données]
        let afterSID = String(response.dropFirst(2))
        let bscHex = String(format: "%02X", blockSequenceCounter)
        let dataHex: String
        if afterSID.hasPrefix(bscHex) {
            dataHex = String(afterSID.dropFirst(2))
        } else {
            dataHex = afterSID
        }
        return Data(HexParsing.bytes(dataHex) ?? [])
    }

    /// Sortie du mode de transfert de blocs (Service 0x37 - RequestTransferExit).
    @discardableResult
    public func requestTransferExit(parameterRecordHex: String = "") async throws -> String {
        let cleanParam = parameterRecordHex.replacing(" ", with: "").uppercased()
        let hexCmd = "37" + cleanParam
        let response = try await sendRaw(hexCmd, timeout: 3.0)
        try validatePositiveResponse(response, expectedSID: 0x37)
        return response
    }

    private static func parseMaxBlockLength(from responseHex: String, defaultLength: Int) -> Int {
        guard let bytes = HexParsing.bytes(responseHex), bytes.count >= 3 else {
            return defaultLength
        }
        let lfid = Int((bytes[1] >> 4) & 0x0F)
        let lengthCount = lfid > 0 ? min(lfid, bytes.count - 2) : (bytes.count - 2)
        guard lengthCount > 0 else { return defaultLength }
        var value = 0
        for i in 0..<lengthCount {
            value = (value << 8) | Int(bytes[2 + i])
        }
        return value > 2 ? value : defaultLength
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

    private func sendRaw(_ hex: String, timeout: TimeInterval = 2.0) async throws -> String {
        do {
            let res = try await interface.sendDiagnosticRequest(hex, timeout: timeout)
            var clean = res
                .replacing(" ", with: "")
                .replacing("\n", with: "")
                .replacing("\r", with: "")
                .uppercased()
            let cleanReq = hex.replacing(" ", with: "").uppercased()
            if cleanReq.count >= 2 {
                let sidPrefix = String(cleanReq.prefix(2))
                let pendingPrefix = "7F\(sidPrefix)78"
                while clean.hasPrefix(pendingPrefix) && clean.count > 6 {
                    clean = String(clean.dropFirst(6))
                }
            }
            return clean
        } catch {
            throw UDSError.transportError(error.localizedDescription)
        }
    }

    private func validatePositiveResponse(_ responseHex: String, expectedSID: UInt8) throws {
        var clean = responseHex
            .replacing(" ", with: "")
            .replacing("\n", with: "")
            .replacing("\r", with: "")
            .uppercased()

        let pendingPrefix = String(format: "7F%02X78", expectedSID)
        while clean.hasPrefix(pendingPrefix) && clean.count > 6 {
            clean = String(clean.dropFirst(6))
        }

        if clean.hasPrefix("7F") {
            guard clean.count >= 6 else {
                throw UDSError.invalidResponseFormat(clean)
            }
            let service = UInt8(clean.dropFirst(2).prefix(2), radix: 16) ?? 0
            let nrc = UInt8(clean.dropFirst(4).prefix(2), radix: 16) ?? 0
            let msg = UDSNRC(rawValue: nrc)?.title ?? UDSNRC.description(for: nrc)
            throw UDSError.negativeResponse(service: service, nrc: nrc, message: msg)
        }

        guard expectedSID <= 0xBF else {
            throw UDSError.invalidResponseFormat("SID invalide pour réponse positive (0x\(String(format: "%02X", expectedSID)))")
        }
        let expectedPositiveSID = String(format: "%02X", expectedSID + 0x40)
        guard clean.hasPrefix(expectedPositiveSID) else {
            throw UDSError.invalidResponseFormat("Réponse inattendue (attendu: \(expectedPositiveSID)..., reçu: \(clean))")
        }
    }
}
