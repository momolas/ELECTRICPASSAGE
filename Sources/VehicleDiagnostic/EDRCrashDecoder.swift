import Foundation
import VehicleCore
import VehicleTransport

/// Instantané de boîte noire / Event Data Recorder (SAE J1698 / UDS `0x19 04` / OBD-II Mode `0x02`)
/// Inspiré de Craig Smith, *The Car Hacker's Handbook*, Chapitre 4 (Event Data Recorder Logging, p. 111–114).
public struct EDRCrashSnapshot: Sendable, Equatable, Codable {
    public enum ImpactSeverity: String, Sendable, Codable {
        case none = "Aucun impact significatif"
        case minor = "Impact mineur (Seuil pré-prétensionneur)"
        case moderate = "Impact modéré (Déclenchement prétensionneur)"
        case severeAirbagDeployment = "Impact sévère (Déploiement Airbag SRS)"
    }

    public let triggerDTC: String
    public let snapshotRecordNumber: UInt8
    public let vehicleSpeedKmh: Double
    public let engineRPM: Double
    public let throttlePositionPercent: Double
    public let brakeSwitchActive: Bool
    public let seatbeltBuckled: Bool
    public let airbagDeployed: Bool
    /// Variation de vitesse longitudinale $\Delta V_x$ en km/h (négative lors d'un choc frontal)
    public let longitudinalDeltaVKmh: Double
    /// Variation de vitesse latérale $\Delta V_y$ en km/h
    public let lateralDeltaVKmh: Double
    public let batteryVoltage: Double
    public let severity: ImpactSeverity

    public init(
        triggerDTC: String,
        snapshotRecordNumber: UInt8,
        vehicleSpeedKmh: Double,
        engineRPM: Double,
        throttlePositionPercent: Double,
        brakeSwitchActive: Bool,
        seatbeltBuckled: Bool,
        airbagDeployed: Bool,
        longitudinalDeltaVKmh: Double,
        lateralDeltaVKmh: Double,
        batteryVoltage: Double,
        severity: ImpactSeverity
    ) {
        self.triggerDTC = triggerDTC
        self.snapshotRecordNumber = snapshotRecordNumber
        self.vehicleSpeedKmh = vehicleSpeedKmh
        self.engineRPM = engineRPM
        self.throttlePositionPercent = throttlePositionPercent
        self.brakeSwitchActive = brakeSwitchActive
        self.seatbeltBuckled = seatbeltBuckled
        self.airbagDeployed = airbagDeployed
        self.longitudinalDeltaVKmh = longitudinalDeltaVKmh
        self.lateralDeltaVKmh = lateralDeltaVKmh
        self.batteryVoltage = batteryVoltage
        self.severity = severity
    }

    /// Module vectoriel de la variation de vitesse totale $|\Delta \vec{V}| = \sqrt{\Delta V_x^2 + \Delta V_y^2}$ en km/h
    public var totalDeltaVMagnitudeKmh: Double {
        hypot(longitudinalDeltaVKmh, lateralDeltaVKmh)
    }

    /// Énergie cinétique dissipée estimée (en kJ) pour une masse de référence du véhicule (par défaut 1450 kg)
    public func dissipatedKineticEnergyKJ(vehicleMassKg: Double = 1450.0) -> Double {
        guard vehicleMassKg > 0 && vehicleMassKg.isFinite else { return 0.0 }
        let deltaVms = totalDeltaVMagnitudeKmh / 3.6
        guard deltaVms.isFinite else { return 0.0 }
        return 0.5 * vehicleMassKg * deltaVms * deltaVms / 1000.0
    }
}

/// Décodeur d'instantanés d'événements EDR (SAE J1698 / UDS `0x19 04` / OBD-II Mode `0x02` Freeze Frame)
public enum EDRCrashDecoder {

    /// Décode une réponse UDS `0x59 0x04` (`ReadDTCInformation - reportDTCSnapshotRecordByDTCNumber`)
    /// Format d'enregistrement :
    /// `59 04 <DTC_H> <DTC_M> <DTC_L> <DTC_Status> <RecordNum> <Speed> <RPM_H> <RPM_L> <Throttle> <Flags> <DeltaVx_Int8> <DeltaVy_Int8> <Voltage_0.1V>`
    /// - Flags bitmask : bit 0 = brakeSwitchActive, bit 1 = seatbeltBuckled, bit 2 = airbagDeployed
    public static func decodeUDSSnapshot(from responseHex: String) -> EDRCrashSnapshot? {
        let stripped = HexParsing.stripISOTPFraming(responseHex)
        let bytes = HexParsing.bytes(stripped) ?? []
        guard bytes.count >= 15, bytes[0] == 0x59, bytes[1] == 0x04 else {
            return nil
        }

        let dtcString = DTCDecoder.decodeSingleDTC(String(format: "%02X%02X", bytes[2], bytes[3])) ?? "P0000"
        let recordNum = bytes[6]
        let speedKmh = Double(bytes[7])
        let rpmRaw = (UInt16(bytes[8]) << 8) | UInt16(bytes[9])
        let rpm = Double(rpmRaw) / 4.0
        let throttle = (Double(bytes[10]) * 100.0) / 255.0

        let flags = bytes[11]
        let brakeActive = (flags & 0x01) != 0
        let seatbeltBuckled = (flags & 0x02) != 0
        let airbagDeployed = (flags & 0x04) != 0

        let deltaVx = Double(Int8(bitPattern: bytes[12]))
        let deltaVy = Double(Int8(bitPattern: bytes[13]))
        let voltage = Double(bytes[14]) / 10.0

        let severity = classifySeverity(
            airbagDeployed: airbagDeployed,
            longitudinalDeltaV: deltaVx,
            lateralDeltaV: deltaVy
        )

        return EDRCrashSnapshot(
            triggerDTC: dtcString,
            snapshotRecordNumber: recordNum,
            vehicleSpeedKmh: speedKmh,
            engineRPM: rpm,
            throttlePositionPercent: throttle,
            brakeSwitchActive: brakeActive,
            seatbeltBuckled: seatbeltBuckled,
            airbagDeployed: airbagDeployed,
            longitudinalDeltaVKmh: deltaVx,
            lateralDeltaVKmh: deltaVy,
            batteryVoltage: voltage,
            severity: severity
        )
    }

    /// Décode une trame OBD-II Mode `0x02` Freeze Frame combinée (`42 ...`)
    /// Prend en charge les PIDs de trame figée SAE J1979 :
    /// - `02` (DTC ayant déclenché la capture, 2 octets)
    /// - `0C` (Régime moteur RPM, 2 octets `(256*A + B)/4`)
    /// - `0D` (Vitesse véhicule km/h, 1 octet `A`)
    /// - `11` (Position papillon %, 1 octet `A * 100 / 255`)
    /// - `42` (Tension module de contrôle V, 2 octets `(256*A + B)/1000`)
    public static func decodeOBD2FreezeFrame(from responseHex: String) -> EDRCrashSnapshot? {
        let stripped = HexParsing.stripISOTPFraming(responseHex)
        let bytes = HexParsing.bytes(stripped) ?? []
        guard bytes.count >= 4, bytes[0] == 0x42 else {
            return nil
        }

        var triggerDTC = "P0000"
        var frameNumber: UInt8 = 0x00
        var speedKmh = 0.0
        var rpm = 0.0
        var throttle = 0.0
        var voltage = 12.6
        var parsedAny = false

        var idx = 1
        while idx + 1 < bytes.count {
            let pid = bytes[idx]
            let frameNo = bytes[idx + 1]
            frameNumber = frameNo
            idx += 2

            switch pid {
            case 0x02:
                guard idx + 1 < bytes.count else { break }
                triggerDTC = DTCDecoder.decodeSingleDTC(String(format: "%02X%02X", bytes[idx], bytes[idx + 1])) ?? "P0000"
                idx += 2
                parsedAny = true
            case 0x0C:
                guard idx + 1 < bytes.count else { break }
                let raw = (UInt16(bytes[idx]) << 8) | UInt16(bytes[idx + 1])
                rpm = Double(raw) / 4.0
                idx += 2
                parsedAny = true
            case 0x0D:
                guard idx < bytes.count else { break }
                speedKmh = Double(bytes[idx])
                idx += 1
                parsedAny = true
            case 0x11:
                guard idx < bytes.count else { break }
                throttle = (Double(bytes[idx]) * 100.0) / 255.0
                idx += 1
                parsedAny = true
            case 0x42:
                guard idx + 1 < bytes.count else { break }
                let raw = (UInt16(bytes[idx]) << 8) | UInt16(bytes[idx + 1])
                voltage = Double(raw) / 1000.0
                idx += 2
                parsedAny = true
            default:
                // Fin d'analyse si PID inconnu de longueur variable
                idx = bytes.count
            }
        }

        guard parsedAny else { return nil }

        return EDRCrashSnapshot(
            triggerDTC: triggerDTC,
            snapshotRecordNumber: frameNumber,
            vehicleSpeedKmh: speedKmh,
            engineRPM: rpm,
            throttlePositionPercent: throttle,
            brakeSwitchActive: false,
            seatbeltBuckled: true,
            airbagDeployed: triggerDTC.hasPrefix("B00"),
            longitudinalDeltaVKmh: 0.0,
            lateralDeltaVKmh: 0.0,
            batteryVoltage: voltage,
            severity: triggerDTC.hasPrefix("B00") ? .severeAirbagDeployment : .none
        )
    }

    /// Interroge l'ECU via UDS `0x19 04` (avec repli automatique sur OBD-II Mode `0x02`) pour extraire l'instantané EDR.
    public static func readCrashSnapshot(
        using interface: VehicleInterface,
        dtcMaskHex: String = "FFFFFF",
        recordNumber: UInt8 = 0x01,
        timeout: TimeInterval = 2.0
    ) async throws -> EDRCrashSnapshot? {
        try Task.checkCancellation()
        let udsCmd = String(format: "1904%@%02X", dtcMaskHex, recordNumber)
        let udsResp = try await interface.sendDiagnosticRequest(udsCmd, timeout: timeout)
        if let snapshot = decodeUDSSnapshot(from: udsResp) {
            return snapshot
        }

        try Task.checkCancellation()
        let obdResp = try await interface.sendDiagnosticRequest("020200", timeout: timeout)
        return decodeOBD2FreezeFrame(from: obdResp)
    }

    /// Classifie la sévérité d'impact selon les seuils cinématiques SAE J1698 / NHTSA EDR
    public static func classifySeverity(
        airbagDeployed: Bool,
        longitudinalDeltaV: Double,
        lateralDeltaV: Double
    ) -> EDRCrashSnapshot.ImpactSeverity {
        let totalDV = hypot(longitudinalDeltaV, lateralDeltaV)
        if airbagDeployed || totalDV >= 24.0 {
            return .severeAirbagDeployment
        } else if totalDV >= 14.0 {
            return .moderate
        } else if totalDV >= 8.0 {
            return .minor
        } else {
            return .none
        }
    }
}
