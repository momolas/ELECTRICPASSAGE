import Foundation
import VehicleCore

/// OBD2Analyzer fournit des fonctions utilitaires pour décoder, annoter et traduire
/// les trames de diagnostic automobile OBD-II, UDS (ISO 14229) et KWP2000 (ISO 14230).
public final class OBD2Analyzer: Sendable {

    // MARK: - Tables de Décryptage KWP2000 et UDS

    public static let udsKwpModeDescriptions: [UInt8: String] = [
        0x10: "Diagnostic Session Control",
        0x11: "ECU Reset",
        0x12: "Read ECU Identification / Freeze Frame (KWP2000)",
        0x13: "Read Diagnostic Trouble Codes (KWP2000)",
        0x14: "Clear Diagnostic Information",
        0x17: "Read Status Of Diagnostic Trouble Codes (KWP2000)",
        0x18: "Read Diagnostic Trouble Codes By Status (KWP2000)",
        0x19: "Read DTC Information (UDS)",
        0x1A: "Read ECU Identification (KWP2000)",
        0x20: "Stop Diagnostic Session (KWP2000)",
        0x21: "Read Data By Local Identifier (KWP2000)",
        0x22: "Read Data By Identifier (UDS)",
        0x23: "Read Memory By Address",
        0x27: "Security Access",
        0x28: "Communication Control / Disable Tx-Rx",
        0x29: "Enable Normal Message Transmission (KWP2000)",
        0x2C: "Dynamically Define Local Identifier (KWP2000)",
        0x2E: "Write Data By Identifier (UDS)",
        0x30: "Input Output Control By Local Identifier (KWP2000)",
        0x31: "Routine Control (UDS/KWP2000)",
        0x32: "Stop Routine (KWP2000)",
        0x33: "Request Routine Results (KWP2000)",
        0x34: "Request Download",
        0x35: "Request Upload",
        0x36: "Transfer Data",
        0x37: "Request Transfer Exit",
        0x3B: "Write Data By Local Identifier (KWP2000)",
        0x3E: "Tester Present",
        0x85: "Control DTC Setting"
    ]

    public static let obd2ModeDescriptions: [UInt8: String] = [
        0x01: "Show Current Data",
        0x02: "Show Freeze Frame Data",
        0x03: "Show Stored DTCs",
        0x04: "Clear DTCs",
        0x09: "Request Vehicle Information"
    ]

    public static let udsSubFunctions: [UInt8: [UInt8: String]] = [
        0x10: [
            0x01: "Default Session (UDS)",
            0x02: "Programming Session (UDS)",
            0x03: "Extended Diagnostic Session (UDS)",
            0x81: "Standard Session (KWP2000)",
            0x85: "ECU Programming Session (KWP2000)",
            0x86: "ECU Adjustment Session (KWP2000)",
            0x87: "Diagnostic Session (KWP2000)"
        ],
        0x11: [
            0x01: "Hard Reset",
            0x02: "Key Off/On Reset",
            0x03: "Soft Reset"
        ],
        0x19: [
            0x01: "Report number of DTC by status mask",
            0x02: "Report DTC by status mask",
            0x03: "Report DTC snapshot identification",
            0x04: "Report DTC snapshot record by DTC number",
            0x06: "Report DTC extended data record by DTC number",
            0x0A: "Report supported DTCs"
        ],
        0x28: [
            0x00: "Enable Rx and Tx",
            0x01: "Enable Rx, disable Tx",
            0x02: "Disable Rx, enable Tx",
            0x03: "Disable Rx and Tx"
        ],
        0x31: [
            0x01: "Start Routine",
            0x02: "Stop Routine",
            0x03: "Request Routine Results"
        ],
        0x3E: [
            0x00: "Zero Sub-function"
        ],
        0x85: [
            0x01: "On",
            0x02: "Off"
        ]
    ]

    public static let didDescriptions: [UInt16: String] = [
        0xF180: "Boot Software Identification",
        0xF186: "Active Diagnostic Session",
        0xF187: "Spare Part Number",
        0xF188: "ECU Software Number",
        0xF189: "ECU Software Version Number",
        0xF18A: "System Supplier Identifier",
        0xF18B: "ECU Manufacturing Date",
        0xF18C: "ECU Serial Number",
        0xF190: "VIN",
        0xF191: "ECU Hardware Number",
        0xF192: "System Supplier ECU Hardware Number",
        0xF193: "System Supplier ECU Hardware Version",
        0xF194: "System Supplier ECU Software Number",
        0xF195: "System supplier ECU software version",
        0xF197: "System name or engine type",
        0xF199: "Programming Date",
        0xF1A0: "Diagnostic Version"
    ]

    public static let kwpECUIdentifications: [UInt8: String] = [
        0x80: "ECU Identification / Reference",
        0x81: "ECU Software Number",
        0x82: "ECU Software Version Number",
        0x83: "ECU Boot Software Number",
        0x84: "ECU Hardware Number",
        0x85: "System Supplier Identifier",
        0x86: "System Supplier ECU Hardware Version",
        0x87: "Spare Part Number",
        0x88: "System Supplier ECU Software Number",
        0x89: "System Supplier ECU Software Version",
        0x8A: "System Supplier Identifier",
        0x8B: "ECU Manufacturing Date",
        0x8C: "ECU Serial Number",
        0x90: "VIN (Vehicle Identification Number)",
        0x97: "System Name / Engine Type",
        0x9B: "Calibration Identification"
    ]

    public static let renaultLidDescriptions: [UInt8: String] = [
        0x01: "ECU Identification / Basic States",
        0x02: "System Parameters",
        0x04: "Vehicle Speed / ABS Wheel Speeds",
        0x05: "Airbag Passenger Safety Impedance",
        0x06: "Airbag Power Supply Voltage",
        0x07: "Yaw Rate / Lateral Acceleration",
        0x61: "Private Parameter Set 1",
        0x62: "Private Parameter Set 2",
        0x64: "EGR Valve Offsets",
        0x90: "VIN (Vehicle Identification Number)",
        0x97: "System Name / Engine Type",
        0xA0: "Air Temperature / Climate Control Sensor",
        0xA1: "Engine Coolant Temp / Intake Air Temp / Battery Voltage",
        0xA3: "Boost Pressure / Boost Target / EGR Valve Position",
        0xA4: "Refrigerant Fluid Pressure / AC Status",
        0xA5: "Fuel Flow / Cylinder Fuel Correction",
        0xA6: "Rail Pressure / Rail Pressure Target / Engine Torque",
        0xA8: "Rail Pressure Regulator Current / Turbo Duty Cycle",
        0xD1: "Cruise Control Target Speed"
    ]

    public static let nrcDescriptions: [UInt8: String] = [
        0x10: "General reject",
        0x11: "Service not supported",
        0x12: "Sub-function not supported / Invalid format",
        0x13: "Incorrect message length or invalid format (UDS)",
        0x14: "Response too long",
        0x21: "Busy repeat request",
        0x22: "Conditions not correct or request sequence error",
        0x23: "Routine not complete (KWP2000)",
        0x24: "Request sequence error",
        0x25: "No response from sub-bus component",
        0x26: "Failure prevents execution of requested action",
        0x31: "Request out of range",
        0x33: "Security access denied",
        0x35: "Invalid key",
        0x36: "Exceeded number of attempts",
        0x37: "Required time delay not expired",
        0x40: "Download not accepted (KWP2000)",
        0x41: "Improper download type (KWP2000)",
        0x42: "Can't download to specified address (KWP2000)",
        0x43: "Can't download number of bytes requested (KWP2000)",
        0x50: "Upload not accepted (KWP2000)",
        0x51: "Improper upload type (KWP2000)",
        0x52: "Can't upload from specified address (KWP2000)",
        0x53: "Can't upload number of bytes requested (KWP2000)",
        0x70: "Upload/download not accepted (UDS)",
        0x71: "Transfer data suspended",
        0x72: "General programming failure",
        0x73: "Wrong block sequence counter",
        0x78: "Request correctly received - response pending",
        0x7E: "Sub-function not supported in active session",
        0x7F: "Service not supported in active session"
    ]

    // MARK: - Analyseurs et Formateurs Statiques

    /// Décrit une requête de diagnostic à partir de son format hexadécimal (ex: "2190" -> "Read Data By Local Identifier (KWP2000) · VIN (Vehicle Identification Number) (LID 90)")
    public static func describeRequest(_ hex: String) -> String {
        let cleanHex = hex.replacing( " ", with: "").uppercased()

        // Détection et nettoyage des commandes hybrides de fuzzing LID
        var bytes: [UInt8] = []
        if cleanHex.contains("LID") {
            let parts = cleanHex.components(separatedBy: "LID")
            if parts.count > 1, let lidVal = UInt8(parts[1], radix: 16) {
                bytes = [0x21, lidVal]
            }
        }

        if bytes.isEmpty {
            guard let parsedBytes = HexParsing.bytes(cleanHex) else {
                return "Commande brute: \(hex)"
            }
            bytes = parsedBytes
        }

        guard let mode = bytes.first else {
            return "Commande brute: \(hex)"
        }

        let isOBD2 = mode <= 0x0F
        let modeName = isOBD2 ? obd2ModeDescriptions[mode] : udsKwpModeDescriptions[mode]
        let fallback = isOBD2 ? "OBD-II Mode \(String(format: "%02X", mode))" : "Service diagnostic \(String(format: "%02X", mode))"
        let displayMode = modeName ?? fallback

        var details: [String] = [displayMode]

        if isOBD2 {
            if bytes.count > 1 {
                let pid = bytes[1]
                let pidHex = String(format: "%02X", pid)
                if let standardPid = StandardPids.get(pidHex) {
                    details.append("\(standardPid.displayName) (PID \(pidHex))")
                } else {
                    details.append("PID \(pidHex)")
                }
            }
        } else {
            switch mode {
            case 0x1A: // Read ECU Identification (KWP2000)
                if bytes.count >= 2 {
                    let id = bytes[1]
                    let idHex = String(format: "%02X", id)
                    if let desc = kwpECUIdentifications[id] {
                        details.append("\(desc) (ID \(idHex))")
                    } else {
                        details.append("Identifiant \(idHex)")
                    }
                }
            case 0x21, 0x3B: // Read / Write by Local Identifier (KWP2000)
                if bytes.count >= 2 {
                    let lid = bytes[1]
                    let lidHex = String(format: "%02X", lid)
                    if let desc = renaultLidDescriptions[lid] {
                        details.append("\(desc) (LID \(lidHex))")
                    } else {
                        details.append("LID \(lidHex)")
                    }
                }
            case 0x22, 0x2E: // Read / Write by Identifier
                if bytes.count >= 3 {
                    let did = UInt16(bytes[1]) << 8 | UInt16(bytes[2])
                    let didHex = String(format: "%04X", did)
                    if let name = didDescriptions[did] {
                        details.append("\(name) (DID \(didHex))")
                    } else {
                        details.append("DID \(didHex)")
                    }
                }
            case 0x27: // Security Access
                if bytes.count >= 2 {
                    let subFn = bytes[1] & 0x7F
                    let step = subFn.isMultiple(of: 2) ? "Send Key" : "Request Seed"
                    let level = (subFn + 1) / 2
                    details.append("\(step) (Niveau \(level))")
                }
            default:
                if bytes.count >= 2, let subs = udsSubFunctions[mode], let subName = subs[bytes[1]] {
                    details.append(subName)
                }
            }
        }

        return details.joined(separator: " · ")
    }

    /// Tente de décoder et formater de manière exhaustive les résultats de diagnostic KWP2000 et UDS.
    public static func decodeResponse(request: String, response: String) -> String? {
        let cleanReq = request.replacing( " ", with: "").uppercased()
        let cleanResp = response.replacing( " ", with: "").uppercased()

        // Redirection intelligente des commandes contenant "LID"
        var reqBytes: [UInt8] = []
        if cleanReq.contains("LID") {
            let parts = cleanReq.components(separatedBy: "LID")
            if parts.count > 1, let lidVal = UInt8(parts[1], radix: 16) {
                reqBytes = [0x21, lidVal]
            }
        }

        if reqBytes.isEmpty {
            guard let parsedReq = HexParsing.bytes(cleanReq) else { return nil }
            reqBytes = parsedReq
        }

        guard let reqMode = reqBytes.first, let respBytes = HexParsing.bytes(cleanResp) else {
            return nil
        }

        // 1. Détection des trames NRC (Negative Response) : Format "7F [Service] [Code NRC]"
        if respBytes.first == 0x7F {
            guard respBytes.count >= 3 else {
                return "❌ Erreur de réponse négative incomplète (7F)"
            }
            let service = respBytes[1]
            let nrc = respBytes[2]
            let nrcResp = UDSNRCResponse(requestedServiceID: service, rawHexByte: nrc)
            let serviceName = udsKwpModeDescriptions[service] ?? "0x\(String(format: "%02X", service))"
            return "❌ Rejet Service \(serviceName) : \(nrcResp.title) (0x\(nrcResp.rawHexCode)) — \(nrcResp.actionAdvice)"
        }

        let isOBD2 = reqMode <= 0x0F

        if isOBD2 {
            // OBD-II Response positive : reqMode + 0x40
            let expectedPositive = reqMode + 0x40
            guard respBytes.first == expectedPositive else { return nil }

            if reqBytes.count > 1, respBytes.count > 2 {
                let pidHex = String(format: "%02X", reqBytes[1])
                // Si la trame est du texte (ex: Mode 09 PID 02 -> VIN)
                if reqMode == 0x09 && reqBytes[1] == 0x02 {
                    let payload = Array(respBytes.dropFirst(2))
                    if let text = asciiDecode(HexParsing.hex(payload)) {
                        return "VIN: \(text)"
                    }
                }
                
                // Formater selon la base de PIDs
                if let standard = StandardPids.get(pidHex), standard.formula != "0" {
                    let payload = Array(respBytes.dropFirst(2))
                    if let value = applyFormula(standard.formula, bytes: payload) {
                        return "\(value) \(standard.unit)"
                    }
                }
            }
        } else {
            // UDS/KWP2000 Response positive : reqMode + 0x40
            let expectedPositive = reqMode + 0x40
            guard respBytes.first == expectedPositive else { return nil }

            switch reqMode {
            case 0x10: // Diagnostic Session Control (KWP2000/UDS)
                if respBytes.count >= 2 {
                    let sessionType = respBytes[1]
                    let sessionHex = String(format: "%02X", sessionType)
                    let subFnDesc = udsSubFunctions[0x10]?[sessionType] ?? "Session \(sessionHex)"
                    return "✅ Session ouverte : \(subFnDesc)"
                }
                return "✅ Session ouverte avec succès"
                
            case 0x11: // ECU Reset (KWP2000/UDS)
                if respBytes.count >= 2 {
                    let resetType = respBytes[1]
                    let resetHex = String(format: "%02X", resetType)
                    let subFnDesc = udsSubFunctions[0x11]?[resetType] ?? "Reset \(resetHex)"
                    return "✅ ECU Reset effectué : \(subFnDesc)"
                }
                return "✅ ECU Reset effectué avec succès"
                
            case 0x13, 0x17, 0x18: // Read DTCs KWP2000
                guard respBytes.count >= 2 else {
                    return "✅ Lecture DTC KWP2000 réussie (aucun code)"
                }
                let count = Int(respBytes[1])
                var dtcs: [String] = []
                let payload = Array(respBytes.dropFirst(2))
                var index = 0
                
                if payload.count >= count * 3 {
                    // Format KWP2000 3 octets : [Code High, Code Low, Statut]
                    while index + 2 < payload.count && dtcs.count < count {
                        let high = payload[index]
                        let low = payload[index + 1]
                        let status = payload[index + 2]
                        let hexCode = String(format: "%02X%02X", high, low)
                        let standardCode = DTCDecoder.decodeSingleDTC(hexCode) ?? hexCode
                        let statusDesc = DTCDecoder.decodeKwpDtcStatus(status)
                        dtcs.append("\(standardCode) [Statut: \(statusDesc)]")
                        index += 3
                    }
                } else if payload.count >= count * 2 {
                    // Format KWP2000 2 octets : [Code High, Code Low]
                    while index + 1 < payload.count && dtcs.count < count {
                        let high = payload[index]
                        let low = payload[index + 1]
                        let hexCode = String(format: "%02X%02X", high, low)
                        let standardCode = DTCDecoder.decodeSingleDTC(hexCode) ?? hexCode
                        dtcs.append(standardCode)
                        index += 2
                    }
                }
                
                if dtcs.isEmpty {
                    return "✅ Aucun code défaut (DTC) actif détecté"
                } else {
                    return "⚠️ \(count) défaut(s) détecté(s) :\n" + dtcs.joined(separator: "\n")
                }
                
            case 0x14: // Clear DTCs KWP2000
                return "✅ Codes défauts (DTC) effacés avec succès"
                
            case 0x1A: // Read ECU Identification (KWP2000)
                if respBytes.count > 2 {
                    let id = respBytes[1]
                    let idHex = String(format: "%02X", id)
                    let payload = Array(respBytes.dropFirst(2))
                    let payloadHex = HexParsing.hex(payload)
                    
                    if id == 0x90 || id == 0x97 {
                        if let text = asciiDecode(payloadHex) {
                            return "Identification: \(text)"
                        }
                    }
                    
                    let label = kwpECUIdentifications[id] ?? "Identifiant \(idHex)"
                    return "\(label) : " + payload.map { String(format: "%02X", $0) }.joined(separator: " ")
                }
                return "✅ Identification ECU lue avec succès"
                
            case 0x21: // Read Data By Local Identifier (KWP2000)
                if respBytes.count > 2 {
                    let lid = respBytes[1]
                    let lidHex = String(format: "%02X", lid)
                    let payload = Array(respBytes.dropFirst(2))
                    let payloadHex = HexParsing.hex(payload)
                    
                    // Conversion ASCII auto pour VIN/Désignation Renault
                    if lid == 0x90 || lid == 0x97 {
                        if let text = asciiDecode(payloadHex) {
                            return "VIN/Désignation: \(text)"
                        }
                    }
                    
                    let label = renaultLidDescriptions[lid] ?? "LID \(lidHex)"
                    return "\(label) : " + payload.map { String(format: "%02X", $0) }.joined(separator: " ")
                }
                return "✅ Lecture LID réussie"
                
            case 0x22: // Read Data By Identifier
                if reqBytes.count >= 3, respBytes.count > 3 {
                    let did = UInt16(reqBytes[1]) << 8 | UInt16(reqBytes[2])
                    let payload = Array(respBytes.dropFirst(3))
                    let payloadHex = HexParsing.hex(payload)
                    
                    if did == 0xF190 || did == 0xF187 || did == 0xF18C || did == 0xF188 || did == 0xF197 {
                        if let text = asciiDecode(payloadHex) {
                            return text
                        }
                    }
                    return "Hex: " + payload.map { String(format: "%02X", $0) }.joined(separator: " ")
                }
                return "✅ Lecture DID réussie"
                
            case 0x27: // Security Access
                if respBytes.count >= 2 {
                    let subFn = respBytes[1]
                    if !subFn.isMultiple(of: 2) {
                        let seed = Array(respBytes.dropFirst(2))
                        return "Seed reçue: " + seed.map { String(format: "%02X", $0) }.joined(separator: " ")
                    } else {
                        return "🔓 Clé validée, ECU déverrouillé"
                    }
                }
                return "🔓 Accès sécurité négocié"
                
            case 0x31: // Routine Control (KWP2000/UDS)
                if respBytes.count >= 2 {
                    let routineType = respBytes[1]
                    let action = routineType == 0x01 ? "démarrée" : (routineType == 0x02 ? "arrêtée" : "résultat disponible")
                    return "✅ Routine \(action) avec succès"
                }
                return "✅ Routine de contrôle exécutée"
                
            case 0x34: // Request Download (KWP2000/UDS)
                return "✅ Autorisation de download (écriture) accordée par l'ECU"
                
            case 0x35: // Request Upload (KWP2000/UDS)
                return "✅ Autorisation d'upload (lecture) accordée par l'ECU"
                
            case 0x36: // Transfer Data (KWP2000/UDS)
                return "✅ Transfert de bloc de données réussi"
                
            case 0x37: // Request Transfer Exit (KWP2000/UDS)
                return "✅ Fin de transfert acceptée, liaison fermée"
                
            case 0x3B: // Write Data By Local Identifier (KWP2000)
                if respBytes.count > 1 {
                    let lidHex = String(format: "%02X", respBytes[1])
                    return "✅ LID \(lidHex) écrit avec succès"
                }
                return "✅ Écriture LID réussie"
                
            case 0x3E: // Tester Present (KWP2000/UDS)
                return "✅ Tester Present: ECU en ligne"
                
            default:
                break
            }
        }

        return nil
    }

    /// Décrit le nom en clair d'un LID KWP2000 Renault
    public static func describeLID(_ lidHex: String) -> String? {
        guard let bytes = HexParsing.bytes(lidHex), let lid = bytes.first else { return nil }
        return renaultLidDescriptions[lid]
    }

    /// Décode une trame hexadécimale brute en chaîne ASCII imprimable, en filtrant les caractères non imprimables
    public static func asciiDecode(_ hex: String) -> String? {
        guard let bytes = HexParsing.bytes(hex) else { return nil }
        var chars: [Character] = []
        for b in bytes {
            // Filtrer les caractères ASCII imprimables standard (32 à 126)
            if b >= 32 && b <= 126 {
                chars.append(Character(UnicodeScalar(b)))
            } else if b == 0 || b == 0xFF {
                // Ignorer les zéros de remplissage ou les FF
                continue
            } else {
                // Remplacer les autres caractères par un point pour la lisibilité
                chars.append(".")
            }
        }
        let cleaned = String(chars).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    // MARK: - Formules Mathématiques Internes

    private static let formulaEvaluator = FormulaEvaluator()

    private static func applyFormula(_ formula: String, bytes: [UInt8]) -> String? {
        guard !bytes.isEmpty else { return nil }
        guard let value = formulaEvaluator.evaluate(formula: formula, bytes: bytes) else { return nil }

        if value.rounded() == value && abs(value) < 1e9 {
            return String(Int(value))
        } else {
            return value.formatted(.number.precision(.fractionLength(1...2)))
        }
    }

    // MARK: - Classification de Protocole & SAE J1939

    /// Détecte et classifie automatiquement le protocole d'une trame CAN (OBD-II, J1939, KWP2000, UDS, Générique)
    public static func classifyCANFrame(canID: UInt32, data: Data? = nil) -> CANProtocolClassification {
        return CANProtocolDetector.detect(canID: canID, payload: data)
    }

    /// Décode les signaux physiques d'une trame SAE J1939 (29 bits) à partir de son PGN
    public static func decodeJ1939Signals(canID: UInt32, data: Data) -> [J1939Signal] {
        let header = J1939Header(canID: canID)
        return J1939Decoder.decode(pgn: header.pgn, data: data)
    }
}
