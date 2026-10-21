import Foundation
import VehicleCore
import VehicleTransport
import VehicleDiagnostic
import VehicleAnalytics

/// Dossier forensique et de conformité cyber-automobile (ISO/SAE 21434 & UNECE R155 CSMS)
/// Regroupe les preuves actives UDS, l'intégrité de calibration, la boîte noire EDR, le profilage CAN passif
/// et l'évaluation HEAVENS/DREAD scellés par une empreinte déterministe FNV-1a 64-bits.
public struct VehicleForensicDossier: Sendable, Equatable, Codable {
    public let ecuName: String
    public let udsScanReport: UDSSecurityScanReport
    public let calibrationInfo: ECUCalibrationInfo?
    public let edrCrashSnapshot: EDRCrashSnapshot?
    public let canFingerprint: CANBusFingerprint?
    public let busAnomalyReport: BusAnomalyReport?
    public let riskReport: AutomotiveRiskReport
    public let evidenceDigestHex: String

    public init(
        ecuName: String,
        udsScanReport: UDSSecurityScanReport,
        calibrationInfo: ECUCalibrationInfo?,
        edrCrashSnapshot: EDRCrashSnapshot?,
        canFingerprint: CANBusFingerprint?,
        busAnomalyReport: BusAnomalyReport?,
        riskReport: AutomotiveRiskReport,
        evidenceDigestHex: String? = nil
    ) {
        self.ecuName = ecuName
        self.udsScanReport = udsScanReport
        self.calibrationInfo = calibrationInfo
        self.edrCrashSnapshot = edrCrashSnapshot
        self.canFingerprint = canFingerprint
        self.busAnomalyReport = busAnomalyReport
        self.riskReport = riskReport
        self.evidenceDigestHex = evidenceDigestHex ?? Self.computeDigestHex(
            ecuName: ecuName,
            udsScanReport: udsScanReport,
            calibrationInfo: calibrationInfo,
            edrCrashSnapshot: edrCrashSnapshot,
            canFingerprint: canFingerprint,
            busAnomalyReport: busAnomalyReport,
            riskReport: riskReport
        )
    }

    /// Vérifie que l'empreinte d'intégrité `evidenceDigestHex` correspond exactement aux preuves du dossier.
    public func verifyIntegrity() -> Bool {
        let expected = Self.computeDigestHex(
            ecuName: ecuName,
            udsScanReport: udsScanReport,
            calibrationInfo: calibrationInfo,
            edrCrashSnapshot: edrCrashSnapshot,
            canFingerprint: canFingerprint,
            busAnomalyReport: busAnomalyReport,
            riskReport: riskReport
        )
        return expected == evidenceDigestHex
    }

    /// Calcule une empreinte FNV-1a 64-bits déterministe sur la représentation canonique des preuves.
    public static func computeDigestHex(
        ecuName: String,
        udsScanReport: UDSSecurityScanReport,
        calibrationInfo: ECUCalibrationInfo?,
        edrCrashSnapshot: EDRCrashSnapshot?,
        canFingerprint: CANBusFingerprint?,
        busAnomalyReport: BusAnomalyReport?,
        riskReport: AutomotiveRiskReport
    ) -> String {
        var canonical = "ECU:\(ecuName)|"
        canonical += "SESSIONS:" + udsScanReport.sessions.map { "\($0.sessionType):\($0.isSupported)" }.joined(separator: ",") + "|"
        canonical += "SERVICES:" + udsScanReport.services.map { "\($0.serviceID):\($0.availability.rawValue)" }.joined(separator: ",") + "|"
        canonical += "SEEDS:" + udsScanReport.seedAudits.map { "\($0.level):\($0.posture.rawValue)" }.joined(separator: ",") + "|"
        canonical += "CAL:\(calibrationInfo?.primaryCalID ?? "NONE"):\(calibrationInfo?.primaryCVN ?? "NONE")|"
        canonical += "EDR:\(edrCrashSnapshot?.triggerDTC ?? "NONE"):\(Int((edrCrashSnapshot?.totalDeltaVMagnitudeKmh ?? 0.0) * 100.0))|"
        canonical += "C0F:\(canFingerprint?.mainID ?? 0):\(canFingerprint?.idStatistics.count ?? 0)|"
        canonical += "IDS:\(busAnomalyReport?.status.rawValue ?? "NONE"):\(Int((busAnomalyReport?.anomalyScore ?? 0.0) * 1000.0))|"
        canonical += "RISK:\(riskReport.securityLevel.rawValue):\(Int(riskReport.dreadScore * 100.0))"

        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for byte in canonical.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(format: "%016llX", hash)
    }
}

/// Orchestrateur autonome de collecte forensique et d'audit cyber-automobile de bout en bout.
/// Chaîne automatiquement le scan UDS non-destructif, l'intégrité des calibrations, la boîte noire EDR,
/// le profilage passif CAN (`c0f` + IDS) et la cotation normative ISO/SAE 21434 (HEAVENS / DREAD / STRIDE).
public actor VehicleForensicOrchestrator {
    private let interface: VehicleInterface

    public init(interface: VehicleInterface) {
        self.interface = interface
    }

    /// Exécute la collecte forensique complète et génère un `VehicleForensicDossier` scellé.
    public func collectDossier(
        ecuName: String,
        isSafetyCriticalDomain: Bool = true,
        gatewayIsolationPresent: Bool = true,
        capturedCANFrames: [CANSampleFrame] = [],
        timeout: TimeInterval = 2.0
    ) async throws -> VehicleForensicDossier {
        try Task.checkCancellation()

        // 1. Scan non-destructif de surface UDS (Sessions, Services, Graines SecurityAccess 0x27)
        let udsScanner = UDSSecurityScanner(interface: interface)
        let udsReport = try await udsScanner.runFullScan()
        try Task.checkCancellation()

        // 2. Lecture multi-protocoles des identifiants de calibration (CalID, CVN, détection Stage1/Tuning)
        let calibration = try? await CalibrationReader.read(interface: interface)
        try Task.checkCancellation()

        // 3. Extraction de l'instantané boîte noire EDR (UDS 0x19 04 + repli OBD-II Mode 0x02)
        let edrSnapshot = try? await EDRCrashDecoder.readCrashSnapshot(using: interface, timeout: timeout)
        try Task.checkCancellation()

        // 4. Profilage passif c0f et détection d'intrusion IDS sur les trames CAN capturées
        let canFingerprint: CANBusFingerprint?
        let anomalyReport: BusAnomalyReport?
        if !capturedCANFrames.isEmpty {
            canFingerprint = CANBusFingerprinter.fingerprint(frames: capturedCANFrames)
            let detector = CANIntrusionDetector(windowSize: max(20, capturedCANFrames.count))
            var lastReport: BusAnomalyReport?
            for frame in capturedCANFrames {
                lastReport = await detector.ingest(frame: frame)
            }
            anomalyReport = lastReport
        } else {
            canFingerprint = nil
            anomalyReport = nil
        }

        // 5. Synthèse automatique des observations de sécurité pour AutomotiveRiskAssessor
        let unlockedByDefault = udsReport.seedAudits.contains { $0.posture == .unlockedByDefault }
        let staticSeed = udsReport.seedAudits.contains { $0.posture == .staticSeedVulnerability }
        let programmingSupported = udsReport.sessions.contains { $0.sessionType == 0x02 && $0.isSupported }
        let programmingInMotion = programmingSupported && ((edrSnapshot?.vehicleSpeedKmh ?? 0.0) > 0.0)

        var combinedAnomalyScore = anomalyReport?.anomalyScore ?? 0.0
        if calibration?.isSuspiciousTuningDetected == true {
            combinedAnomalyScore = min(1.0, combinedAnomalyScore + 0.40)
        }

        let observations = ECUSecurityObservations(
            ecuName: ecuName,
            isSafetyCriticalDomain: isSafetyCriticalDomain,
            securityAccessUnlockedByDefault: unlockedByDefault,
            staticSeedDetected: staticSeed,
            programmingSessionAllowedInMotion: programmingInMotion,
            gatewayIsolationPresent: gatewayIsolationPresent,
            busAnomalyScore: combinedAnomalyScore
        )

        let riskReport = AutomotiveRiskAssessor.evaluateECUPosture(observations)

        return VehicleForensicDossier(
            ecuName: ecuName,
            udsScanReport: udsReport,
            calibrationInfo: calibration,
            edrCrashSnapshot: edrSnapshot,
            canFingerprint: canFingerprint,
            busAnomalyReport: anomalyReport,
            riskReport: riskReport
        )
    }
}
