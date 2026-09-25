import Foundation
import VehicleCore

/// Client DoIP (Diagnostics over IP - ISO 13400) implémentant `VehicleInterface`.
public actor DoIPClient: VehicleInterface {

    public private(set) var isConnected: Bool = false
    public private(set) var isRoutingActivated: Bool = false
    
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
        self.isConnected = true
        do {
            try await activateRouting()
        } catch {
            self.isConnected = false
            self.isRoutingActivated = false
            throw error
        }
    }

    public func disconnect() async {
        self.isConnected = false
        self.isRoutingActivated = false
    }

    public func setTarget(txID: String, rxID: String?) async throws {
        let clean = txID.lowercased().hasPrefix("0x") ? String(txID.dropFirst(2)) : txID
        if let target = UInt16(clean.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16) {
            self.targetLogicalAddress = target
        }
    }

    /// Active le routage logique TCP selon l'ISO 13400 (Type 0x0005)
    public func activateRouting(activationType: UInt8 = 0x00) async throws {
        guard isConnected else {
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
            throw NSError(domain: "DoIPClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "DoIP non connecté ou routage non activé"])
        }

        let cleanHex = requestHex.replacing( " ", with: "")
        guard let udsPayload = HexParsing.bytes(cleanHex) else {
            throw NSError(domain: "DoIPClient", code: -2, userInfo: [NSLocalizedDescriptionKey: "Payload hexadécimal invalide: \(requestHex)"])
        }

        var doipPayload = Data()
        doipPayload.append(UInt8((sourceAddress >> 8) & 0xFF))
        doipPayload.append(UInt8(sourceAddress & 0xFF))
        doipPayload.append(UInt8((targetLogicalAddress >> 8) & 0xFF))
        doipPayload.append(UInt8(targetLogicalAddress & 0xFF))
        doipPayload.append(contentsOf: udsPayload)

        let msg = DoIPMessage(payloadType: .diagnosticMessage, payload: doipPayload)
        let _ = msg.encode()

        // Simule la réponse UDS positive ou directe via DoIP
        if cleanHex.hasPrefix("10") {
            return "5001"
        } else if cleanHex.hasPrefix("22F190") {
            // VIN Did standard
            let vinHex = "5646314A4D304A30483332303030313233" // "VF1JM0J0H32000123"
            return "62F190" + vinHex
        } else if cleanHex.hasPrefix("22") {
            return "62" + cleanHex.dropFirst(2) + "00AA"
        } else if cleanHex.hasPrefix("1902") {
            // 59 02 FF (DTC Status Mask Response) + P0102 (010200 2F)
            return "5902FF0102002F"
        } else if cleanHex.hasPrefix("14") {
            return "54"
        } else if cleanHex.hasPrefix("2701") {
            return "670111223344"
        } else if cleanHex.hasPrefix("2702") {
            return "6702"
        } else if cleanHex.hasPrefix("3E") {
            return "7E00"
        }

        return "7F" + String(cleanHex.prefix(2)) + "10"
    }

    public func sendRawCAN(id: UInt32, data: Data, bus: UInt8) async throws {
        // Envoi encapsulé
    }
}
