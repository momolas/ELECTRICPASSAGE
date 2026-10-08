import Foundation
import VehicleCore

public enum ISOTPResult: Equatable, Sendable {
    case pending
    case completed(Data)
    case needsFlowControl
    case error(String)
}

public actor ISOTPReassembler {
    private struct ReassemblyState: Sendable {
        var totalLength: Int
        var buffer: Data
        var nextSequence: UInt8
        var lastActivity: ContinuousClock.Instant = .now
    }

    private var states: [UInt32: ReassemblyState] = [:]

    public init() {}

    public func reset(address: UInt32? = nil) {
        if let address {
            states.removeValue(forKey: address)
        } else {
            states.removeAll()
        }
    }

    private func purgeStaleStates() {
        let now = ContinuousClock.Instant.now
        states = states.filter { _, state in
            now.duration(to: state.lastActivity) > .seconds(-1.5)
        }
    }

    public func processFrame(address: UInt32, data: Data) -> ISOTPResult {
        purgeStaleStates()
        
        guard !data.isEmpty else {
            return .error("Trame vide")
        }

        // Ré-ancre le buffer pour garantir startIndex == 0 même si un Data slice (SubSequence) est fourni
        let frame = data.startIndex == 0 ? data : Data(data)
        let pci = frame[0] >> 4

        switch pci {
        case 0: // Single Frame (SF)
            let rawLength = Int(frame[0] & 0x0F)
            let length: Int
            let payload: Data.SubSequence

            if rawLength > 0 {
                // Classic CAN Single Frame (1 à 7 octets)
                length = rawLength
                guard frame.count >= length + 1 else {
                    return .error("Trame Single Frame trop courte pour la longueur déclarée (\(length))")
                }
                payload = frame[1...length]
            } else {
                // ISO 15765-2:2016 CAN-FD Single Frame (8 à 62 octets)
                guard frame.count >= 2 else {
                    return .error("Trame CAN-FD Single Frame incomplète")
                }
                length = Int(frame[1])
                guard length > 0 else {
                    return .error("Longueur CAN-FD Single Frame invalide (0)")
                }
                guard frame.count >= length + 2 else {
                    return .error("Trame CAN-FD Single Frame trop courte pour la longueur déclarée (\(length))")
                }
                payload = frame[2..<(2 + length)]
            }

            states.removeValue(forKey: address)
            return .completed(Data(payload))

        case 1: // First Frame (FF)
            guard frame.count >= 2 else {
                return .error("Trame First Frame incomplète")
            }
            let rawLength = Int((UInt16(frame[0] & 0x0F) << 8) | UInt16(frame[1]))
            let length: Int
            let payload: Data.SubSequence

            if rawLength == 0 {
                // ISO 15765-2:2016 CAN-FD First Frame avec longueur étendue sur 32 bits (DL > 4095)
                guard frame.count >= 6 else {
                    return .error("Trame CAN-FD First Frame 32-bit incomplète")
                }
                let len32 = (UInt32(frame[2]) << 24) | (UInt32(frame[3]) << 16) | (UInt32(frame[4]) << 8) | UInt32(frame[5])
                length = Int(len32)
                guard length > 4095 else {
                    return .error("Longueur CAN-FD First Frame 32-bit invalide (\(length))")
                }
                payload = frame[6...]
            } else {
                // Classic CAN First Frame (DL <= 4095)
                length = rawLength
                guard length > 7 else {
                    return .error("Longueur First Frame invalide (\(length))")
                }
                payload = frame[2...]
            }

            states[address] = ReassemblyState(
                totalLength: length,
                buffer: Data(payload),
                nextSequence: 1
            )
            return .needsFlowControl

        case 2: // Consecutive Frame (CF)
            guard var state = states[address] else {
                return .error("Trame Consecutive Frame orpheline sur 0x\(String(format: "%X", address))")
            }

            let sequence = frame[0] & 0x0F
            guard sequence == state.nextSequence else {
                states.removeValue(forKey: address)
                return .error("Erreur séquence ISO-TP : reçu \(sequence), attendu \(state.nextSequence)")
            }

            let payload = frame[1...]
            state.buffer.append(payload)
            state.nextSequence = (state.nextSequence + 1) & 0x0F
            state.lastActivity = .now

            if state.buffer.count >= state.totalLength {
                states.removeValue(forKey: address)
                let completedData = state.buffer.prefix(state.totalLength)
                return .completed(Data(completedData))
            } else {
                states[address] = state
                return .pending
            }

        case 3: // Flow Control (FC)
            return .pending

        default:
            return .error("Type de trame ISO-TP non supporté: \(pci)")
        }
    }
}
