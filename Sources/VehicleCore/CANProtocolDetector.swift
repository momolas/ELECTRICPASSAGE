import Foundation

/// Type de protocole de communication automobile détecté sur le bus CAN
public enum CANProtocolType: String, Sendable, CaseIterable, Identifiable {
    case j1939 = "SAE J1939"
    case obd2 = "OBD-II (ISO 15765-4)"
    case kwp2000 = "KWP2000 (ISO 14230)"
    case uds = "UDS (ISO 14229)"
    case generic = "CAN Générique"

    public var id: String { rawValue }
}

/// Résultat de la classification automatique d'une trame ou d'un identifiant CAN
public struct CANProtocolClassification: Sendable, Equatable {
    public let protocolType: CANProtocolType
    public let standardName: String
    public let descriptionText: String
    public let is29BitExtended: Bool
    public let details: [String: String]

    public init(
        protocolType: CANProtocolType,
        standardName: String,
        descriptionText: String,
        is29BitExtended: Bool,
        details: [String: String] = [:]
    ) {
        self.protocolType = protocolType
        self.standardName = standardName
        self.descriptionText = descriptionText
        self.is29BitExtended = is29BitExtended
        self.details = details
    }
}

/// Détecteur et classificateur heuristique de protocoles CAN par plage d'identifiants et signatures de trame
public enum CANProtocolDetector {

    /// Analyse un identifiant CAN et sa charge utile pour identifier le protocole sous-jacent
    public static func detect(canID: UInt32, payload: Data? = nil) -> CANProtocolClassification {
        // 1. Identifiants étendus 29 bits (> 0x7FF) -> SAE J1939 (ISO 11783)
        if canID > 0x7FF {
            let header = J1939Header(canID: canID)
            var details: [String: String] = [
                "PGN": String(format: "0x%04X (%d)", header.pgn, header.pgn),
                "Priority": "\(header.priority)",
                "SourceAddress": String(format: "0x%02X (%d)", header.sourceAddress, header.sourceAddress),
                "PDUFormat": String(format: "0x%02X", header.pduFormat),
                "Type": header.isBroadcast ? "Broadcast (PDU2)" : "Peer-to-Peer (PDU1)"
            ]
            if let da = header.destinationAddress {
                details["DestinationAddress"] = String(format: "0x%02X (%d)", da, da)
            }

            return CANProtocolClassification(
                protocolType: .j1939,
                standardName: "SAE J1939 / ISO 11783",
                descriptionText: "Bus de communication poids lourds / agricole / maritime (PGN \(header.pgn))",
                is29BitExtended: true,
                details: details
            )
        }

        // 2. OBD-II Broadcast Request (0x7DF)
        if canID == 0x7DF {
            return CANProtocolClassification(
                protocolType: .obd2,
                standardName: "ISO 15765-4 / SAE J1979",
                descriptionText: "Requête fonctionnelle globale OBD-II (Broadcast à tous les calculateurs)",
                is29BitExtended: false,
                details: ["Target": "Broadcast (All ECUs)", "Address": "0x7DF"]
            )
        }

        // 3. OBD-II / UDS Physical Requests (0x7E0 ... 0x7E7)
        if (0x7E0...0x7E7).contains(canID) {
            let ecuIndex = canID - 0x7E0
            let ecuName = ecuIndex == 0 ? "Moteur (ECM/PCM)" : (ecuIndex == 1 ? "Transmission (TCM)" : "ECU #\(ecuIndex)")
            return CANProtocolClassification(
                protocolType: .obd2,
                standardName: "ISO 15765-4 / ISO 14229",
                descriptionText: "Requête physique diagnostique vers \(ecuName)",
                is29BitExtended: false,
                details: ["Type": "Physical Request", "ECU": "\(ecuIndex)", "Address": String(format: "0x%03X", canID)]
            )
        }

        // 4. OBD-II / UDS Physical Responses (0x7E8 ... 0x7EF)
        if (0x7E8...0x7EF).contains(canID) {
            let ecuIndex = canID - 0x7E8
            let ecuName = ecuIndex == 0 ? "Moteur (ECM/PCM)" : (ecuIndex == 1 ? "Transmission (TCM)" : "ECU #\(ecuIndex)")
            return CANProtocolClassification(
                protocolType: .obd2,
                standardName: "ISO 15765-4 / ISO 14229",
                descriptionText: "Réponse diagnostique de \(ecuName)",
                is29BitExtended: false,
                details: ["Type": "Physical Response", "ECU": "\(ecuIndex)", "Address": String(format: "0x%03X", canID)]
            )
        }

        // 5. KWP2000 Diagnostic Ranges (0x600...0x607, 0x640...0x67F, 0x740...0x77F)
        if (0x600...0x607).contains(canID) || (0x640...0x67F).contains(canID) || (0x740...0x77F).contains(canID) {
            return CANProtocolClassification(
                protocolType: .kwp2000,
                standardName: "ISO 14230 (KWP2000)",
                descriptionText: "Plage de diagnostic constructeur KWP2000 Legacy",
                is29BitExtended: false,
                details: ["Range": "KWP Legacy", "Address": String(format: "0x%03X", canID)]
            )
        }

        // 6. UDS Extended Diagnostics Ranges (0x700...0x7DF)
        if (0x700...0x7DF).contains(canID) {
            return CANProtocolClassification(
                protocolType: .uds,
                standardName: "ISO 14229 (UDS)",
                descriptionText: "Diagnostic étendu UDS / Télécodage constructeur",
                is29BitExtended: false,
                details: ["Range": "UDS Diagnostic", "Address": String(format: "0x%03X", canID)]
            )
        }

        // 7. Generic 11-bit CAN frame
        return CANProtocolClassification(
            protocolType: .generic,
            standardName: "CAN 2.0A (11-bit)",
            descriptionText: "Trame CAN standard (Télémétrie inter-calculateurs)",
            is29BitExtended: false,
            details: ["Address": String(format: "0x%03X", canID)]
        )
    }
}
