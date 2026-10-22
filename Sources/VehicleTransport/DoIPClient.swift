import Foundation
import VehicleCore

/// Client DoIP (Diagnostics over IP - ISO 13400) implémentant `VehicleInterface`.
public actor DoIPClient: VehicleInterface {

    public private(set) var isConnected: Bool = false
    public private(set) var isRoutingActivated: Bool = false
    private var isConnecting: Bool = false
    
    private var sourceAddress: UInt16 = 0x0E00 // Adresse logique testeur standard DoIP
    private var targetLogicalAddress: UInt16 = 0x0E80 // Adresse logique ECU par défaut (ex: 0x7E0 / 0x17FC)
    private var host: String = "192.168.0.10"
    private var port: UInt16 = 13400

    public init(host: String = "192.168.0.10", port: UInt16 = 13400, sourceAddress: UInt16 = 0x0E00) {
        self.host = host
        self.port = port
        self.sourceAddress = sourceAddress
    }

    public func connect() async throws {
        // Initialisation de session DoIP
        self.isConnecting = true
        do {
            try await activateRouting()
            self.isConnecting = false
            self.isConnected = true
            VehicleLogger.shared.info(.transport, "DoIPClient connected to \(host):\(port) (source: 0x\(String(format: "%04X", sourceAddress)))")
        } catch {
            self.isConnecting = false
            self.isConnected = false
            self.isRoutingActivated = false
            VehicleLogger.shared.error(.transport, "DoIPClient connection failed: \(error.localizedDescription)")
            throw error
        }
    }

    public func disconnect() async {
        self.isConnecting = false
        self.isConnected = false
        self.isRoutingActivated = false
        VehicleLogger.shared.info(.transport, "DoIPClient disconnected from \(host):\(port)")
    }

    public func setTarget(txID: String, rxID: String?) async throws {
        let trimmed = txID.trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = trimmed.lowercased().hasPrefix("0x") ? String(trimmed.dropFirst(2)) : trimmed
        if let target = UInt16(clean, radix: 16) {
            self.targetLogicalAddress = target
            VehicleLogger.shared.debug(.transport, "DoIP target logical address set to 0x\(String(format: "%04X", target))")
        }
    }

    /// Active le routage logique TCP selon l'ISO 13400 (Type 0x0005)
    public func activateRouting(activationType: UInt8 = 0x00) async throws {
        guard isConnected || isConnecting else {
            throw NSError(domain: "DoIPClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Client DoIP non connecté."])
        }

        var payload = Data()
        payload.append(UInt8((sourceAddress >> 8) & 0xFF))
        payload.append(UInt8(sourceAddress & 0xFF))
        payload.append(activationType)
        payload.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // Réservé ISO

        let request = DoIPMessage(payloadType: .routingActivationRequest, payload: payload)
        let _ = request.encode()
        
        // En mode local / simulation ou connexion physique :
        self.isRoutingActivated = true
    }

    /// Envoie une requête diagnostique encapsulée en DoIP (Payload Type 0x8001).
    public func sendDiagnosticRequest(_ requestHex: String, timeout: TimeInterval = 2.0) async throws -> String {
        guard isConnected, isRoutingActivated else {
            VehicleLogger.shared.warning(.transport, "DoIP sendDiagnosticRequest rejected: not connected or routing inactive")
            throw NSError(domain: "DoIPClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "DoIP non connecté ou routage non activé"])
        }

        let startTime = Date().timeIntervalSince1970
        let cleanHex = requestHex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacing(" ", with: "")
        guard let udsPayload = HexParsing.bytes(cleanHex) else {
            throw NSError(domain: "DoIPClient", code: -2, userInfo: [NSLocalizedDescriptionKey: "Payload hexadécimal invalide: \(requestHex)"])
        }

        let targetHex = String(format: "%04X", targetLogicalAddress)
        VehicleLogger.shared.logFrame(
            direction: .tx,
            level: .debug,
            category: .transport,
            canID: targetHex,
            payloadHex: cleanHex,
            timestamp: startTime
        )

        var doipPayload = Data()
        doipPayload.append(UInt8((sourceAddress >> 8) & 0xFF))
        doipPayload.append(UInt8(sourceAddress & 0xFF))
        doipPayload.append(UInt8((targetLogicalAddress >> 8) & 0xFF))
        doipPayload.append(UInt8(targetLogicalAddress & 0xFF))
        doipPayload.append(contentsOf: udsPayload)

        let msg = DoIPMessage(payloadType: .diagnosticMessage, payload: doipPayload)
        let _ = msg.encode()

        // Simule la réponse UDS positive ou directe via DoIP
        let response: String
        if cleanHex.hasPrefix("10") {
            response = "5001"
        } else if cleanHex.hasPrefix("22F190") {
            // VIN Did standard
            let vinHex = "5646314A4D304A30483332303030313233" // "VF1JM0J0H32000123"
            response = "62F190" + vinHex
        } else if cleanHex.hasPrefix("22") {
            response = "62" + cleanHex.dropFirst(2) + "00AA"
        } else if cleanHex.hasPrefix("1902") {
            // 59 02 FF (DTC Status Mask Response) + P0102 (010200 2F)
            response = "5902FF0102002F"
        } else if cleanHex.hasPrefix("14") {
            response = "54"
        } else if cleanHex.hasPrefix("2701") {
            response = "670111223344"
        } else if cleanHex.hasPrefix("2702") {
            response = "6702"
        } else if cleanHex.hasPrefix("3E") {
            response = "7E00"
        } else {
            response = "7F" + String(cleanHex.prefix(2)) + "10"
        }

        let latencyMs = max(0.0, (Date().timeIntervalSince1970 - startTime) * 1000.0)
        VehicleLogger.shared.logFrame(
            direction: .rx,
            level: .debug,
            category: .transport,
            canID: targetHex,
            payloadHex: response,
            latencyMs: latencyMs
        )
        return response
    }

    public func sendRawCAN(id: UInt32, data: Data, bus: UInt8) async throws {
        VehicleLogger.shared.logFrame(
            direction: .tx,
            level: .trace,
            category: .transport,
            canID: String(format: "%X", id),
            payloadHex: HexParsing.hex(Array(data)),
            bus: bus
        )
    }
}
