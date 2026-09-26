import Foundation
import VehicleCore

/// Rapport d'évaluation de la santé de la batterie (SOH)
public struct BatteryHealthReport: Sendable, Equatable {
    public enum HealthStatus: String, Sendable, Codable {
        case excellent = "Excellente (Capacité > 85%)"
        case good = "Bonne (Capacité 70 - 85%)"
        case weakNeedsRecharge = "Faible (Recharge / Test Requis)"
        case replaceImmediate = "Défaillante (Remplacement Recommandé)"
    }

    public let stateOfHealthPercent: Double
    public let internalResistanceMilliOhms: Double
    public let restingVoltage: Double
    public let minimumCrankingVoltage: Double
    public let status: HealthStatus
    public let diagnosticSummary: String

    public init(
        stateOfHealthPercent: Double,
        internalResistanceMilliOhms: Double,
        restingVoltage: Double,
        minimumCrankingVoltage: Double,
        status: HealthStatus,
        diagnosticSummary: String
    ) {
        self.stateOfHealthPercent = stateOfHealthPercent
        self.internalResistanceMilliOhms = internalResistanceMilliOhms
        self.restingVoltage = restingVoltage
        self.minimumCrankingVoltage = minimumCrankingVoltage
        self.status = status
        self.diagnosticSummary = diagnosticSummary
    }
}

/// Modèle d'évaluation dynamique de la résistance interne et du SOH de la batterie
public enum BatteryHealthEstimator: Sendable {

    /// Évalue la santé de la batterie à partir du profil de chute de tension au démarrage
    /// - Parameters:
    ///   - restingVoltage: Tension de repos avant le coup de démarreur (ex: 12.6V)
    ///   - minimumCrankingVoltage: Tension minimale enregistrée pendant l'entraînement du démarreur (ex: 10.2V)
    ///   - estimatedCrankingAmps: Intensité de courant estimée du démarreur (défaut: 220 A)
    ///   - temperatureCelsius: Température ambiante (défaut: 20°C)
    public static func estimate(
        restingVoltage: Double,
        minimumCrankingVoltage: Double,
        estimatedCrankingAmps: Double = 220.0,
        temperatureCelsius: Double = 20.0
    ) -> BatteryHealthReport {
        guard restingVoltage.isFinite, minimumCrankingVoltage.isFinite,
              restingVoltage > 0.0, minimumCrankingVoltage > 0.0 else {
            return BatteryHealthReport(
                stateOfHealthPercent: 0.0,
                internalResistanceMilliOhms: 999.0,
                restingVoltage: restingVoltage.isFinite ? restingVoltage : 0.0,
                minimumCrankingVoltage: minimumCrankingVoltage.isFinite ? minimumCrankingVoltage : 0.0,
                status: .replaceImmediate,
                diagnosticSummary: "Mesure de tension invalide ou capteur déconnecté."
            )
        }

        if restingVoltage <= minimumCrankingVoltage {
            return BatteryHealthReport(
                stateOfHealthPercent: 0.0,
                internalResistanceMilliOhms: 999.0,
                restingVoltage: restingVoltage,
                minimumCrankingVoltage: minimumCrankingVoltage,
                status: .replaceImmediate,
                diagnosticSummary: "Anomalie : tension sous démarreur supérieure ou égale à la tension de repos."
            )
        }

        let deltaV = max(0.0, restingVoltage - minimumCrankingVoltage)
        let current = max(50.0, estimatedCrankingAmps.isFinite ? estimatedCrankingAmps : 220.0)
        
        // Résistance interne en milli-Ohms : Ri = (V_rest - V_crank) / I * 1000
        let riMilliOhms = (deltaV / current) * 1000.0

        // Correction thermique de résistance interne
        let tempFactor = 1.0 + (20.0 - temperatureCelsius) * 0.005
        let normalizedRi = riMilliOhms / max(0.5, tempFactor)

        // SOH calculé par rapport à une batterie neuve (Ri nominale ≈ 4 à 5 mΩ)
        // Au-delà de 18-20 mΩ, la batterie est considérée en fin de vie
        let baselineRi = 4.5
        let endOfLifeRi = 20.0
        let rawSOH = 100.0 - ((normalizedRi - baselineRi) / (endOfLifeRi - baselineRi) * 100.0)
        let clampedSOH = min(100.0, max(0.0, rawSOH))

        let status: BatteryHealthReport.HealthStatus
        let summary: String

        if minimumCrankingVoltage < 9.0 || clampedSOH < 40.0 {
            status = .replaceImmediate
            summary = "Chute de tension critique au démarrage (\(String(format: "%.1f", minimumCrankingVoltage)) V), risque élevé de panne imminente."
        } else if minimumCrankingVoltage < 9.8 || clampedSOH < 65.0 {
            status = .weakNeedsRecharge
            summary = "Résistance interne élevée (\(String(format: "%.1f", riMilliOhms)) mΩ). Batterie fatiguée ou déchargée."
        } else if clampedSOH < 85.0 {
            status = .good
            summary = "Batterie en état d'usage satisfaisant (SOH: \(Int(clampedSOH))%)."
        } else {
            status = .excellent
            summary = "Batterie en excellente condition (Ri: \(String(format: "%.1f", riMilliOhms)) mΩ, SOH: \(Int(clampedSOH))%)."
        }

        return BatteryHealthReport(
            stateOfHealthPercent: clampedSOH,
            internalResistanceMilliOhms: riMilliOhms,
            restingVoltage: restingVoltage,
            minimumCrankingVoltage: minimumCrankingVoltage,
            status: status,
            diagnosticSummary: summary
        )
    }
}
