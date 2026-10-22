import Foundation
import VehicleCore
import VehicleAnalytics

/// Catégories sémantiques reconnues lors du reverse-engineering automatique de signaux
public enum InferredSignalCategory: String, Sendable, CaseIterable, Identifiable, Codable {
    case engineRPM = "Régime Moteur (RPM)"
    case vehicleSpeed = "Vitesse Véhicule (km/h)"
    case throttleOrPedal = "Position Pédale / Papillon (%)"
    case brakePedalOrPressure = "Pression Frein / Contact Stop"
    case steeringAngle = "Angle Volant Direction"
    case thermalSlow = "Température / Niveau Fluide"
    case counterOrCRC = "Compteur de Trame / Checksum"
    case constantMarker = "Marqueur Statique / Configuration"
    case unknown = "Signal Non Classifié"

    public var id: String { rawValue }

    public var badgeIcon: String {
        switch self {
        case .engineRPM: return "gauge.with.needle.fill"
        case .vehicleSpeed: return "speedometer"
        case .throttleOrPedal: return "bolt.fill"
        case .brakePedalOrPressure: return "exclamationmark.octagon.fill"
        case .steeringAngle: return "steeringwheel"
        case .thermalSlow: return "thermometer.medium"
        case .counterOrCRC: return "number.circle.fill"
        case .constantMarker: return "lock.fill"
        case .unknown: return "questionmark.circle"
        }
    }
}

/// Résultat de classification sémantique
public struct SemanticClassificationResult: Sendable, Equatable, Identifiable, Codable {
    public var id: String { sliceName }
    public let sliceName: String
    public let category: InferredSignalCategory
    public let confidence: Double // 0.0 à 1.0
    public let suggestedUnit: String
    public let dynamicRange: Double
    public let rationale: String

    public init(
        sliceName: String,
        category: InferredSignalCategory,
        confidence: Double,
        suggestedUnit: String,
        dynamicRange: Double,
        rationale: String
    ) {
        self.sliceName = sliceName
        self.category = category
        self.confidence = confidence
        self.suggestedUnit = suggestedUnit
        self.dynamicRange = dynamicRange
        self.rationale = rationale
    }
}

/// Classifieur sémantique de signaux télémétriques et de tranches CAN
public enum SemanticSignalClassifier: Sendable {

    /// Classifie une séquence temporelle de valeurs d'un octet ou mot de données
    public static func classify(sliceName: String, values: [Double]) -> SemanticClassificationResult {
        guard values.count >= 4, values.allSatisfy(\.isFinite) else {
            return SemanticClassificationResult(
                sliceName: sliceName,
                category: .unknown,
                confidence: 0.0,
                suggestedUnit: "raw",
                dynamicRange: 0.0,
                rationale: "Échantillons insuffisants (< 4 points) ou valeurs non finies"
            )
        }

        let minVal = values.min() ?? 0.0
        let maxVal = values.max() ?? 0.0
        let range = maxVal - minVal

        // 1. Marqueur Constant
        if range == 0.0 {
            let hexStr = (minVal.isFinite && minVal >= 0 && minVal <= Double(UInt64.max))
                ? String(UInt64(minVal), radix: 16, uppercase: true)
                : "\((minVal * 10.0).rounded() / 10.0)"
            return SemanticClassificationResult(
                sliceName: sliceName,
                category: .constantMarker,
                confidence: 0.99,
                suggestedUnit: "const",
                dynamicRange: 0.0,
                rationale: "Valeur invariante (0x\(hexStr))"
            )
        }

        // 2. Compteur incrémental (Rolling counter: dérive +1 avec tolérance aux doublons d'échantillonnage)
        let totalSteps = values.count - 1
        var incrementSteps = 0
        var duplicateSteps = 0
        for i in 1..<values.count {
            let diff = values[i] - values[i - 1]
            if diff == 1.0 || (values[i - 1] > values[i] && (diff == -15.0 || diff == -255.0)) {
                incrementSteps += 1
            } else if diff == 0.0 {
                duplicateSteps += 1
            }
        }
        if incrementSteps + duplicateSteps == totalSteps &&
           Double(incrementSteps) / Double(totalSteps) >= 0.80 &&
           range > 0 {
            return SemanticClassificationResult(
                sliceName: sliceName,
                category: .counterOrCRC,
                confidence: 0.95,
                suggestedUnit: "tick",
                dynamicRange: range,
                rationale: "Incrément pas-à-pas périodique caractéristique (modulo 16 ou 256)"
            )
        }

        // 3. Détection Angle Volant Direction (signal bipolaire centré autour de zéro)
        let mean = values.reduce(0.0, +) / Double(values.count)
        if minVal < -10.0 && maxVal > 10.0 && abs(mean) < range * 0.35 {
            return SemanticClassificationResult(
                sliceName: sliceName,
                category: .steeringAngle,
                confidence: 0.86,
                suggestedUnit: "°",
                dynamicRange: range,
                rationale: "Oscillation bipolaire autour du point milieu zéro compatible avec un angle de volant"
            )
        }

        // 4. Détection Dérive Thermique Lente
        var totalAbsDelta = 0.0
        var isMonotonicNonDecreasing = true
        for i in 1..<values.count {
            let step = values[i] - values[i - 1]
            totalAbsDelta += abs(step)
            if step < 0.0 {
                isMonotonicNonDecreasing = false
            }
        }
        let avgDelta = totalAbsDelta / Double(totalSteps)
        if avgDelta < 0.2 && range < 15.0 && minVal > 20.0 {
            return SemanticClassificationResult(
                sliceName: sliceName,
                category: .thermalSlow,
                confidence: 0.82,
                suggestedUnit: "°C",
                dynamicRange: range,
                rationale: "Signal quasi-statique à évolution monotone très lente"
            )
        }

        // 5. Détection Régime Moteur (RPM 16-bit)
        if minVal >= 500.0 && maxVal <= 9000.0 && range > 100.0 {
            return SemanticClassificationResult(
                sliceName: sliceName,
                category: .engineRPM,
                confidence: 0.88,
                suggestedUnit: "tr/min",
                dynamicRange: range,
                rationale: "Valeurs caractéristiques de rotation vilebrequin (plage ralenti-régime haut)"
            )
        }

        let nameLower = sliceName.lowercased()
        let isSpeedHint = nameLower.contains("speed") || nameLower.contains("vitesse") || nameLower.contains("kmh")
        let isThrottleHint = nameLower.contains("throttle") || nameLower.contains("pedal") || nameLower.contains("papillon")

        // 6. Détection Contacteur / Pression Frein (Base à zéro avec pics transitoires)
        let zerosCount = values.filter { $0 == 0.0 }.count
        let zeroRatio = Double(zerosCount) / Double(values.count)
        if !isSpeedHint && zeroRatio >= 0.50 && range > 5.0 {
            return SemanticClassificationResult(
                sliceName: sliceName,
                category: .brakePedalOrPressure,
                confidence: 0.85,
                suggestedUnit: "bar",
                dynamicRange: range,
                rationale: "Signal au repos à 0 avec impulsions positives d'amplitude significative"
            )
        }

        // 7. Détection Vitesse Véhicule (plage > 100 km/h, indice sémantique ou rampe d'accélération fluide)
        if minVal >= 0.0 && maxVal <= 350.0 && range > 5.0 {
            let isHighSpeedRange = maxVal > 100.0 && avgDelta <= 25.0
            let isSmoothAcceleration = !isThrottleHint && isMonotonicNonDecreasing && values.count >= 6 && avgDelta <= 8.0
            if isSpeedHint || isHighSpeedRange || isSmoothAcceleration {
                return SemanticClassificationResult(
                    sliceName: sliceName,
                    category: .vehicleSpeed,
                    confidence: 0.80,
                    suggestedUnit: "km/h",
                    dynamicRange: range,
                    rationale: "Variation continue sans ruptures violentes, compatible vitesse véhicule"
                )
            }
        }

        // 8. Détection Pédale / Papillon 0-100%
        if minVal >= 0.0 && maxVal <= 100.0 && range >= 20.0 {
            return SemanticClassificationResult(
                sliceName: sliceName,
                category: .throttleOrPedal,
                confidence: 0.78,
                suggestedUnit: "%",
                dynamicRange: range,
                rationale: "Plage dynamique normalisée comprise entre 0% et 100%"
            )
        }

        // 9. Détection Vitesse Véhicule basse vitesse (plage < 20 km/h)
        if minVal >= 0.0 && maxVal <= 260.0 && range > 5.0 && avgDelta > 0.05 && avgDelta < 10.0 {
            return SemanticClassificationResult(
                sliceName: sliceName,
                category: .vehicleSpeed,
                confidence: 0.75,
                suggestedUnit: "km/h",
                dynamicRange: range,
                rationale: "Variation continue sans ruptures violentes, compatible vitesse véhicule"
            )
        }

        return SemanticClassificationResult(
            sliceName: sliceName,
            category: .unknown,
            confidence: 0.30,
            suggestedUnit: "raw",
            dynamicRange: range,
            rationale: "Signal dynamique non discriminé par les heuristiques de base"
        )
    }
}
