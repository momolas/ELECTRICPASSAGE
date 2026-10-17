import Foundation

/// Modélisation et décodage du standard SAE J1939 (ISO 11783) pour véhicules industriels, poids lourds et bus.
public struct J1939Header: Sendable, Equatable {
    public let rawID: UInt32
    public let priority: UInt8
    public let dataPage: UInt8
    public let extendedDataPage: UInt8
    public let pduFormat: UInt8
    public let pduSpecific: UInt8
    public let sourceAddress: UInt8
    public let pgn: UInt32
    public let isBroadcast: Bool
    public let destinationAddress: UInt8?

    public init(canID: UInt32) {
        self.rawID = canID
        self.priority = UInt8((canID >> 26) & 0x07)
        self.extendedDataPage = UInt8((canID >> 25) & 0x01)
        self.dataPage = UInt8((canID >> 24) & 0x01)
        self.pduFormat = UInt8((canID >> 16) & 0xFF)
        self.pduSpecific = UInt8((canID >> 8) & 0xFF)
        self.sourceAddress = UInt8(canID & 0xFF)

        // PDU1 (Peer-to-Peer, PF < 240) : PS = Destination Address
        // PDU2 (Broadcast, PF >= 240) : PS fait partie du PGN
        if self.pduFormat < 240 {
            self.pgn = (UInt32(self.extendedDataPage) << 17) | (UInt32(self.dataPage) << 16) | (UInt32(self.pduFormat) << 8)
            self.isBroadcast = false
            self.destinationAddress = self.pduSpecific
        } else {
            self.pgn = (UInt32(self.extendedDataPage) << 17) | (UInt32(self.dataPage) << 16) | (UInt32(self.pduFormat) << 8) | UInt32(self.pduSpecific)
            self.isBroadcast = true
            self.destinationAddress = nil
        }
    }
}

/// Définition d'un Suspect Parameter Number (SPN) SAE J1939
public struct J1939Signal: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let spn: UInt32
    public let value: Double
    public let unit: String
    public let formattedValue: String
    
    public init(name: String, spn: UInt32, value: Double, unit: String, formattedValue: String) {
        self.name = name
        self.spn = spn
        self.value = value
        self.unit = unit
        self.formattedValue = formattedValue
    }
}

/// Décodeur de trames J1939 de base pour les PGNs les plus fréquents
public enum J1939Decoder {
    
    /// Décode les signaux physiques d'une charge utile J1939 pour un PGN donné
    public static func decode(pgn: UInt32, data: Data) -> [J1939Signal] {
        var signals: [J1939Signal] = []
        let bytes = [UInt8](data)
        
        switch pgn {
        case 0xF004: // 61444 - EEC1 (Electronic Engine Controller 1)
            if bytes.count >= 5 {
                // SPN 190: Engine Speed (bytes 3-4, 0.125 rpm/bit)
                let rawRpm = UInt16(bytes[3]) | (UInt16(bytes[4]) << 8)
                if rawRpm < 0xFE00 {
                    let rpm = Double(rawRpm) * 0.125
                    signals.append(J1939Signal(name: "Régime Moteur (Engine Speed)", spn: 190, value: rpm, unit: "rpm", formattedValue: String(format: "%.1f rpm", rpm)))
                }
            }
            if bytes.count >= 3 {
                // SPN 513: Actual Engine Percent Torque (byte 2, 1 %/bit, offset -125%)
                if bytes[2] < 0xFE {
                    let rawTorque = Int(bytes[2]) - 125
                    signals.append(J1939Signal(name: "Couple Moteur Réel", spn: 513, value: Double(rawTorque), unit: "%", formattedValue: "\(rawTorque) %"))
                }
            }
            
        case 0xFEF1: // 65265 - CCVS (Cruise Control / Vehicle Speed)
            if bytes.count >= 3 {
                // SPN 84: Wheel-Based Vehicle Speed (bytes 1-2, 1/256 km/h / bit)
                let rawSpeed = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
                if rawSpeed < 0xFE00 {
                    let speed = Double(rawSpeed) / 256.0
                    signals.append(J1939Signal(name: "Vitesse Véhicule (Wheel Speed)", spn: 84, value: speed, unit: "km/h", formattedValue: String(format: "%.1f km/h", speed)))
                }
            }
            
        case 0xFEEE: // 65262 - ET1 (Engine Temperature 1)
            if !bytes.isEmpty, bytes[0] < 0xFE {
                // SPN 110: Engine Coolant Temperature (byte 0, 1 °C/bit, offset -40 °C)
                let temp = Int(bytes[0]) - 40
                signals.append(J1939Signal(name: "Température Liquide Refroidissement", spn: 110, value: Double(temp), unit: "°C", formattedValue: "\(temp) °C"))
            }
            
        case 0xFEFC: // 65276 - DD (Dash Display)
            if bytes.count >= 2, bytes[1] < 0xFE {
                // SPN 96: Fuel Level 1 (byte 1, 0.4 %/bit)
                let level = Double(bytes[1]) * 0.4
                signals.append(J1939Signal(name: "Niveau Carburant", spn: 96, value: level, unit: "%", formattedValue: String(format: "%.1f %%", level)))
            }
            
        default:
            break
        }
        
        return signals
    }
}
