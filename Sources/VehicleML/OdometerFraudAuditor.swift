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

        let minKm = allKnownMileages.min() ?? input.clusterMileageKm
        let maxKm = allKnownMileages.max() ?? input.clusterMileageKm
        let spread = maxKm - minKm

        // 1. Contrôle de cohérence Multi-ECU
        if let ecuKm = input.engineECUMileageKm, ecuKm > input.clusterMileageKm + 500.0 {
            let delta = ecuKm - input.clusterMileageKm
            anomalies.append("Calculateur Moteur supérieur au Combiné (+ \(Int(delta)) km)")
            riskScore += 0.45
        }
        if let absKm = input.absMileageKm, absKm > input.clusterMileageKm + 500.0 {
            let delta = absKm - input.clusterMileageKm
            anomalies.append("Calculateur ABS supérieur au Combiné (+ \(Int(delta)) km)")
            riskScore += 0.45
        }
        if let tcuKm = input.transmissionMileageKm, tcuKm > input.clusterMileageKm + 500.0 {
            let delta = tcuKm - input.clusterMileageKm
            anomalies.append("Boîte de vitesses supérieure au Combiné (+ \(Int(delta)) km)")
            riskScore += 0.40
        }

        // 2. Contrôle du FAP / DPF (dernière régénération enregistrée)
        if let dpfKm = input.dpfLastRegenerationKm, dpfKm > input.clusterMileageKm + 50.0 {
            let delta = dpfKm - input.clusterMileageKm
            anomalies.append("Dernière régénération FAP post-date le compteur (+ \(Int(delta)) km)")
            riskScore += 0.50
        }

        // 3. Contrôle des Freeze Frames mémorisées dans les DTCs
        for ffKm in input.freezeFrameMileages where ffKm > input.clusterMileageKm + 20.0 {
            let delta = ffKm - input.clusterMileageKm
            anomalies.append("Freeze Frame de défaut figée à un kilométrage supérieur (+ \(Int(delta)) km)")
            riskScore += 0.60
            break
        }

        // 4. Contrôle Heures Moteur vs Vitesse Moyenne Historique
        var avgSpeed: Double? = nil
        if let hours = input.engineHours, hours > 10.0 {
            let speed = input.clusterMileageKm / hours
            avgSpeed = speed
            if speed < 12.0 {
                anomalies.append("Vitesse moyenne anormalement basse (\(String(format: "%.1f", speed)) km/h sur \(Int(hours)) h), suspicion de recul")
                riskScore += 0.25
            } else if speed > 115.0 {
                anomalies.append("Vitesse moyenne anormalement haute (\(String(format: "%.1f", speed)) km/h sur \(Int(hours)) h)")
                riskScore += 0.20
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
        var candidateRealMileages = allKnownMileages + input.freezeFrameMileages
        if let dpfKm = input.dpfLastRegenerationKm { candidateRealMileages.append(dpfKm) }
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
