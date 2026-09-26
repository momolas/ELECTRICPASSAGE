import Foundation
import VehicleCore

/// Rapport d'audit anti-fraude kilométrique multi-calculateurs
public struct FraudAuditReport: Sendable, Equatable {
    public enum RiskLevel: String, Sendable, Codable {
        case genuine = "Intégrité Validée (Sain)"
        case lowSuspicion = "Écart Mineur (Tolérance Normale)"
        case highProbabilityOfRollback = "Forte Probabilité de Recul"
        case confirmedTampering = "Fraude Kilométrique Confirmée"
    }

    public let riskScore: Double // 0.0 (sain) à 1.0 (fraude certaine)
    public let riskLevel: RiskLevel
    public let clusterMileageKm: Double
    public let estimatedRealMileageKm: Double
    public let multiECUSpreadKm: Double
    public let anomalies: [String]
    public let averageSpeedKmH: Double?

    public init(
        riskScore: Double,
        riskLevel: RiskLevel,
        clusterMileageKm: Double,
        estimatedRealMileageKm: Double,
        multiECUSpreadKm: Double,
        anomalies: [String],
        averageSpeedKmH: Double?
    ) {
        self.riskScore = riskScore
        self.riskLevel = riskLevel
        self.clusterMileageKm = clusterMileageKm
        self.estimatedRealMileageKm = estimatedRealMileageKm
        self.multiECUSpreadKm = multiECUSpreadKm
        self.anomalies = anomalies
        self.averageSpeedKmH = averageSpeedKmH
    }
}

/// Moteur d'audit multi-critères pour l'évaluation de la cohérence kilométrique (Used Car AI)
public enum OdometerFraudAuditor: Sendable {

    public struct InputData: Sendable {
        public let clusterMileageKm: Double
        public let engineECUMileageKm: Double?
        public let absMileageKm: Double?
        public let transmissionMileageKm: Double?
        public let engineHours: Double?
        public let dpfLastRegenerationKm: Double?
        public let freezeFrameMileages: [Double]

        public init(
            clusterMileageKm: Double,
            engineECUMileageKm: Double? = nil,
            absMileageKm: Double? = nil,
            transmissionMileageKm: Double? = nil,
            engineHours: Double? = nil,
            dpfLastRegenerationKm: Double? = nil,
            freezeFrameMileages: [Double] = []
        ) {
            self.clusterMileageKm = clusterMileageKm
            self.engineECUMileageKm = engineECUMileageKm
            self.absMileageKm = absMileageKm
            self.transmissionMileageKm = transmissionMileageKm
            self.engineHours = engineHours
            self.dpfLastRegenerationKm = dpfLastRegenerationKm
            self.freezeFrameMileages = freezeFrameMileages
        }
    }

    /// Analyse l'intégrité kilométrique croisée
    public static func audit(input: InputData) -> FraudAuditReport {
        var anomalies: [String] = []
        var riskScore = 0.0

        var allKnownMileages: [Double] = [input.clusterMileageKm]
        if let ecuKm = input.engineECUMileageKm { allKnownMileages.append(ecuKm) }
        if let absKm = input.absMileageKm { allKnownMileages.append(absKm) }
        if let tcuKm = input.transmissionMileageKm { allKnownMileages.append(tcuKm) }

        let validKnownMileages = allKnownMileages.filter { $0.isFinite && $0 >= 0 }
        let minKm = validKnownMileages.min() ?? input.clusterMileageKm
        let maxKm = validKnownMileages.max() ?? input.clusterMileageKm
        let spread = maxKm - minKm

        func formatDelta(_ delta: Double) -> String {
            guard delta.isFinite, delta >= 0, delta <= 10_000_000.0 else { return "N/A" }
            return "\(Int(delta.rounded()))"
        }

        // 1. Contrôle de cohérence Multi-ECU
        if let ecuKm = input.engineECUMileageKm, ecuKm.isFinite, input.clusterMileageKm.isFinite, ecuKm > input.clusterMileageKm + 500.0 {
            let delta = ecuKm - input.clusterMileageKm
            anomalies.append("Calculateur Moteur supérieur au Combiné (+ \(formatDelta(delta)) km)")
            riskScore += 0.45
        }
        if let absKm = input.absMileageKm, absKm.isFinite, input.clusterMileageKm.isFinite, absKm > input.clusterMileageKm + 500.0 {
            let delta = absKm - input.clusterMileageKm
            anomalies.append("Calculateur ABS supérieur au Combiné (+ \(formatDelta(delta)) km)")
            riskScore += 0.45
        }
        if let tcuKm = input.transmissionMileageKm, tcuKm.isFinite, input.clusterMileageKm.isFinite, tcuKm > input.clusterMileageKm + 500.0 {
            let delta = tcuKm - input.clusterMileageKm
            anomalies.append("Boîte de vitesses supérieure au Combiné (+ \(formatDelta(delta)) km)")
            riskScore += 0.40
        }

        // 2. Contrôle du FAP / DPF (dernière régénération enregistrée)
        if let dpfKm = input.dpfLastRegenerationKm, dpfKm.isFinite, input.clusterMileageKm.isFinite, dpfKm > input.clusterMileageKm + 50.0 {
            let delta = dpfKm - input.clusterMileageKm
            anomalies.append("Dernière régénération FAP post-date le compteur (+ \(formatDelta(delta)) km)")
            riskScore += 0.50
        }

        // 3. Contrôle des Freeze Frames mémorisées dans les DTCs
        for ffKm in input.freezeFrameMileages where ffKm.isFinite && input.clusterMileageKm.isFinite && ffKm > input.clusterMileageKm + 20.0 {
            let delta = ffKm - input.clusterMileageKm
            anomalies.append("Freeze Frame de défaut figée à un kilométrage supérieur (+ \(formatDelta(delta)) km)")
            riskScore += 0.60
            break
        }

        // 4. Contrôle Heures Moteur vs Vitesse Moyenne Historique
        var avgSpeed: Double? = nil
        if let hours = input.engineHours, hours.isFinite, hours > 10.0, hours <= 50_000.0, input.clusterMileageKm.isFinite, input.clusterMileageKm >= 0 {
            let speed = input.clusterMileageKm / hours
            if speed.isFinite {
                avgSpeed = speed
                let formattedHours = String(format: "%.0f", hours)
                if speed < 12.0 {
                    anomalies.append("Vitesse moyenne anormalement basse (\(String(format: "%.1f", speed)) km/h sur \(formattedHours) h), suspicion de recul")
                    riskScore += 0.25
                } else if speed > 115.0 {
                    anomalies.append("Vitesse moyenne anormalement haute (\(String(format: "%.1f", speed)) km/h sur \(formattedHours) h)")
                    riskScore += 0.20
                }
            }
        }

        // Normalisation du score entre 0.0 et 1.0
        let normalizedScore = min(1.0, max(0.0, riskScore))
        let level: FraudAuditReport.RiskLevel = {
            if normalizedScore >= 0.70 { return .confirmedTampering }
            if normalizedScore >= 0.40 { return .highProbabilityOfRollback }
            if normalizedScore >= 0.15 { return .lowSuspicion }
            return .genuine
        }()

        // Estimation du kilométrage réel : maximum vérifié entre tous les calculateurs et freeze frames
        var candidateRealMileages = (allKnownMileages + input.freezeFrameMileages).filter { $0.isFinite && $0 >= 0 }
        if let dpfKm = input.dpfLastRegenerationKm, dpfKm.isFinite, dpfKm >= 0 { candidateRealMileages.append(dpfKm) }
        let estimatedReal = candidateRealMileages.max() ?? input.clusterMileageKm

        return FraudAuditReport(
            riskScore: normalizedScore,
            riskLevel: level,
            clusterMileageKm: input.clusterMileageKm,
            estimatedRealMileageKm: estimatedReal,
            multiECUSpreadKm: spread,
            anomalies: anomalies,
            averageSpeedKmH: avgSpeed
        )
    }
}
