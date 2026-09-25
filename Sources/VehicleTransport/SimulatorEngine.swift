import Foundation
import VehicleCore

/// État physique et thermodynamique du moteur simulé.
public struct EnginePhysicsState: Sendable, Equatable {
    public var isRunning: Bool = true
    public var rpm: Double = 750.0
    public var throttlePercent: Double = 0.0
    public var speedKmh: Double = 50.0
    public var coolantTempC: Double = 80.0
    public var oilTempC: Double = 85.0
    public var intakeMapKpa: Double = 35.0
    public var mafGPerSec: Double = 3.5
    public var batteryVoltage: Double = 14.1
    public var fuelLevelPercent: Double = 65.0
    public var runTimeSeconds: Int = 120
    public var milActive: Bool = false
    public var activeDTCs: [String] = ["P0102"]

    public init() {}
}

/// Moteur de transport simulé (Jumeau Numérique Véhicule & Diagnostic).
/// Reproduit fidèlement les protocoles OBD-II (SAE J1979), UDS (ISO 14229) et KWP2000 (ISO 14230),
/// avec physique moteur dynamique, injection de pannes et requêtes multi-PIDs.
public actor SimulatorEngine: VehicleInterface {

    private var currentTx: String = "7E0"
    private var currentRx: String = "7E8"
    private var state = EnginePhysicsState()

    public init() {}

    // MARK: - Pilotage Physique & Injection d'Anomalies

    public func getState() -> EnginePhysicsState {
        state
    }

    public func setThrottle(percent: Double) {
        state.throttlePercent = max(0.0, min(100.0, percent))
        updateDerivedPhysics(deltaSeconds: 0.1)
    }

    public func injectFault(dtc: String) {
        let clean = dtc.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !state.activeDTCs.contains(clean) {
            state.activeDTCs.append(clean)
        }
        state.milActive = true
    }

    public func clearFaults() {
        state.activeDTCs.removeAll()
        state.milActive = false
    }

    public func stepSimulation(deltaSeconds: Double) {
        updateDerivedPhysics(deltaSeconds: deltaSeconds)
    }

    private func updateDerivedPhysics(deltaSeconds: Double) {
        guard state.isRunning else {
            state.rpm = 0.0
            state.speedKmh = 0.0
            state.mafGPerSec = 0.0
            state.intakeMapKpa = 101.3
            state.batteryVoltage = 12.4
            return
        }

        // 1. Régime Moteur (RPM) avec dynamique d'inertie
        let targetRPM = 750.0 + (state.throttlePercent / 100.0) * 5250.0
        let rpmRate = (targetRPM > state.rpm) ? 4.0 : 2.5
        state.rpm += (targetRPM - state.rpm) * min(1.0, deltaSeconds * rpmRate)

        // 2. Vitesse véhicule (km/h) simulée
        let targetSpeed = (state.rpm / 6000.0) * 160.0
        state.speedKmh += (targetSpeed - state.speedKmh) * min(1.0, deltaSeconds * 1.5)

        // 3. Pression d'admission (MAP) & Débitmètre d'air (MAF)
        state.intakeMapKpa = 35.0 + (state.throttlePercent / 100.0) * 65.0
        state.mafGPerSec = max(1.5, (state.rpm * 1.6 * state.intakeMapKpa) / 28700.0)

        // 4. Thermique moteur (Convergence vers température cible sous charge)
        let targetCoolant = 80.0 + (state.throttlePercent / 100.0) * 15.0
        state.coolantTempC += (targetCoolant - state.coolantTempC) * min(1.0, deltaSeconds * 0.05)
        state.oilTempC += (state.coolantTempC + 5.0 - state.oilTempC) * min(1.0, deltaSeconds * 0.03)

        // 5. Batterie et Temps de fonctionnement
        state.batteryVoltage = 14.0 + (state.rpm / 6000.0) * 0.4
        state.runTimeSeconds += max(1, Int(deltaSeconds))
    }

    // MARK: - VehicleInterface Protocol

    public func setTarget(txID: String, rxID: String?) async throws {
        self.currentTx = txID
        if let rxID {
            self.currentRx = rxID
        } else {
            let cleanTx = txID.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
            let txVal = UInt32(cleanTx, radix: 16) ?? 0x7E0
            if (0x740...0x75F).contains(txVal) {
                // Renault KWP2000 offset standard: Tx 0x74X -> Rx 0x76X (+ 0x20)
                self.currentRx = String(format: "%X", txVal + 0x20)
            } else {
                // Standard ISO 15765-4 11-bit: Tx 0x7EX -> Rx 0x7E(X+8)
                self.currentRx = String(format: "%X", txVal + 8)
            }
        }
    }

    public func sendRawCAN(id: UInt32, data: Data, bus: UInt8) async throws {
        // Enregistrement de trame brute virtuelle
    }

    public func sendDiagnosticRequest(_ requestHex: String, timeout: TimeInterval = 2.0) async throws -> String {
        let clean = requestHex.replacingOccurrences(of: " ", with: "").uppercased()

        // 1. Session request (10)
        if clean.hasPrefix("10") {
            return "50" + clean.dropFirst(2) + "003201F4"
        }

        // 2. ECU Reset (11)
        if clean.hasPrefix("11") {
            return "51" + clean.dropFirst(2)
        }

        // 3. Clear DTCs UDS/KWP (14) & OBD-II Mode 04 (04)
        if clean.hasPrefix("14") {
            clearFaults()
            return "54"
        }
        if clean.hasPrefix("04") {
            clearFaults()
            return "44"
        }

        // 4. Read DTC Info UDS (19) & OBD-II Mode 03/07/0A
        if clean.hasPrefix("19") {
            if state.activeDTCs.isEmpty {
                return "5902FF00"
            }
            return "5902FF0102002F"
        }
        if clean.hasPrefix("03") || clean.hasPrefix("07") || clean.hasPrefix("0A") {
            return formatMode03DTCs()
        }

        // 5. OBD-II Mode 09 (Vehicle Information / VIN)
        if clean.hasPrefix("09") {
            if clean.hasPrefix("0902") {
                return "49 02 01 56 46 31 4A 4D 30 47 30 44 31 32 33 34 35 36 37 38" // VIN VF1JM0G0D12345678
            }
            return "49" + clean.dropFirst(2) + "00"
        }

        // 6. Read Data By Identifier UDS (22)
        if clean.hasPrefix("22") {
            let did = String(clean.dropFirst(2).prefix(4))
            if did == "F190" {
                return "62F1905646314A4D304730443132333435363738"
            }
            return "62" + did + "00AA"
        }

        // 7. SecurityAccess (27)
        if clean.hasPrefix("27") {
            let subFn = String(clean.dropFirst(2).prefix(2))
            if subFn == "01" || subFn == "03" || subFn == "05" {
                return "67" + subFn + "1234" // Mock Seed
            } else {
                return "67" + subFn // Key accepted
            }
        }

        // 8. Read Local Identifier KWP2000 (21 XX)
        if clean.hasPrefix("21") {
            let lid = String(clean.dropFirst(2).prefix(2))
            if lid == "00" {
                return "61 00 01 00 00 00 00 00" // UCH config mock
            } else if lid == "01" {
                return "61 01 00 01 01 00 00 00" // TdB config mock
            } else if lid == "0C" {
                let rpmVal = UInt16(min(65535.0, max(0.0, state.rpm * 4.0)))
                return String(format: "61 0C %02X %02X", rpmVal >> 8, rpmVal & 0xFF)
            } else if lid == "A0" {
                let rpmVal = UInt16(min(65535.0, max(0.0, state.rpm * 4.0)))
                return String(format: "61 A0 %02X %02X", rpmVal >> 8, rpmVal & 0xFF)
            }
            return "61" + lid + "0000"
        }

        // 9. Write Local Identifier KWP2000 (3B XX)
        if clean.hasPrefix("3B") {
            let lid = String(clean.dropFirst(2).prefix(2))
            return "7B" + lid
        }

        // 10. Routine Control / Actuators (30 / 31)
        if clean.hasPrefix("30") || clean.hasPrefix("31") {
            return "7101"
        }

        // 11. Tester Present (3E)
        if clean.hasPrefix("3E") {
            return "7E00"
        }

        // 12. OBD-II Mode 01 (Mono-PID ou Multi-PIDs SAE J1979)
        if clean.hasPrefix("01") {
            return handleMode01Request(clean)
        }

        // Service Not Supported (NRC 0x11)
        if clean.count >= 2 {
            return "7F" + String(clean.prefix(2)) + "11"
        }
        return "7F0011"
    }

    // MARK: - Traitement Détaillé Mode 01 & Multi-PIDs

    private func handleMode01Request(_ clean: String) -> String {
        let payload = String(clean.dropFirst(2))
        guard payload.count >= 2 else { return "7F0112" }

        // Découpage en PIDs de 2 caractères (1 octet chacun)
        var pids: [String] = []
        var idx = payload.startIndex
        while idx < payload.endIndex {
            let next = payload.index(idx, offsetBy: 2, limitedBy: payload.endIndex) ?? payload.endIndex
            pids.append(String(payload[idx..<next]))
            idx = next
        }

        // Si requête mono-PID classique
        if pids.count == 1 {
            let pid = pids[0]
            if let formatted = formatSinglePid(pid) {
                return "41 " + pid + " " + formatted
            }
            return "41" + pid + "00"
        }

        // Multi-PIDs SAE J1979: concaténation des réponses
        var pieces: [String] = ["41"]
        for pid in pids {
            if let formatted = formatSinglePid(pid) {
                pieces.append(pid)
                pieces.append(formatted)
            }
        }
        return pieces.joined(separator: " ")
    }

    private func formatSinglePid(_ pid: String) -> String? {
        switch pid {
        case "00":
            return "BE 3E B8 11" // Support 01-20
        case "20":
            return "80 00 00 01" // Support 21-40 avec bit de continuation
        case "40":
            return "00 00 00 00" // Fin de catalogue
        case "04":
            let load = UInt8(min(255.0, max(0.0, state.throttlePercent * 255.0 / 100.0)))
            return String(format: "%02X", load)
        case "05":
            let temp = UInt8(min(255.0, max(0.0, state.coolantTempC + 40.0)))
            return String(format: "%02X", temp)
        case "0B":
            let map = UInt8(min(255.0, max(0.0, state.intakeMapKpa)))
            return String(format: "%02X", map)
        case "0C":
            let rpmVal = UInt16(min(65535.0, max(0.0, state.rpm * 4.0)))
            return String(format: "%02X %02X", rpmVal >> 8, rpmVal & 0xFF)
        case "0D":
            let spd = UInt8(min(255.0, max(0.0, state.speedKmh)))
            return String(format: "%02X", spd)
        case "0E":
            let advance = UInt8(min(255.0, max(0.0, (10.0 + 64.0) * 2.0)))
            return String(format: "%02X", advance)
        case "0F":
            let iat = UInt8(min(255.0, max(0.0, 25.0 + 40.0)))
            return String(format: "%02X", iat)
        case "10":
            let mafVal = UInt16(min(65535.0, max(0.0, state.mafGPerSec * 100.0)))
            return String(format: "%02X %02X", mafVal >> 8, mafVal & 0xFF)
        case "11":
            let throt = UInt8(min(255.0, max(0.0, state.throttlePercent * 255.0 / 100.0)))
            return String(format: "%02X", throt)
        case "1F":
            let rt = UInt16(min(65535, max(0, state.runTimeSeconds)))
            return String(format: "%02X %02X", rt >> 8, rt & 0xFF)
        case "2F":
            let fuel = UInt8(min(255.0, max(0.0, state.fuelLevelPercent * 255.0 / 100.0)))
            return String(format: "%02X", fuel)
        case "42":
            let volt = UInt16(min(65535.0, max(0.0, state.batteryVoltage * 1000.0)))
            return String(format: "%02X %02X", volt >> 8, volt & 0xFF)
        case "5C":
            let oil = UInt8(min(255.0, max(0.0, state.oilTempC + 40.0)))
            return String(format: "%02X", oil)
        default:
            return nil
        }
    }

    private func formatMode03DTCs() -> String {
        guard !state.activeDTCs.isEmpty else {
            return "43 00 00 00 00 00 00"
        }

        var pieces: [String] = ["43"]
        for dtc in state.activeDTCs {
            let bytes = encodeDTC(dtc)
            pieces.append(String(format: "%02X %02X", bytes[0], bytes[1]))
        }
        // Compléter pour un alignement propre de trame CAN standard (43 + 3 codes défauts de 2 octets = 7 octets)
        while pieces.count < 4 {
            pieces.append("00 00")
        }
        return pieces.joined(separator: " ")
    }

    private func encodeDTC(_ dtc: String) -> [UInt8] {
        let clean = dtc.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard clean.count == 5 else { return [0x00, 0x00] }

        let chars = Array(clean)
        let prefixVal: UInt8
        switch chars[0] {
        case "P": prefixVal = 0x0
        case "C": prefixVal = 0x1
        case "B": prefixVal = 0x2
        case "U": prefixVal = 0x3
        default: prefixVal = 0x0
        }

        guard let d1 = UInt8(String(chars[1]), radix: 16),
              let d2 = UInt8(String(chars[2]), radix: 16),
              let d3 = UInt8(String(chars[3]), radix: 16),
              let d4 = UInt8(String(chars[4]), radix: 16) else {
            return [0x00, 0x00]
        }

        let b1 = (prefixVal << 6) | (d1 << 4) | (d2 & 0x0F)
        let b2 = (d3 << 4) | (d4 & 0x0F)
        return [b1, b2]
    }
}
