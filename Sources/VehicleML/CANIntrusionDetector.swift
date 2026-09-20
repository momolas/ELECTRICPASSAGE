import Foundation
import VehicleCore

/// Rapport d'anomalie et d'évaluation de la sécurité du bus CAN
public struct BusAnomalyReport: Sendable, Equatable {
    public enum BusSecurityStatus: String, Sendable, Codable {
        case nominal = "Nominal (Trafic Sain)"
        case suspiciousJitter = "Gigue Anormale Détectée"
        case injectionDetected = "Injection Suspecte / Fuzzing"
        case busFlood = "Saturation / Flood Attaque"
    }

    public let status: BusSecurityStatus
    public let anomalyScore: Double // 0.0 (sain) à 1.0 (critique)
    public let flaggedIDs: [UInt32]
    public let payloadEntropy: Double
    public let averageInterArrivalMs: Double
    public let messageCount: Int
    public let rationale: String

    public init(
        status: BusSecurityStatus,
        anomalyScore: Double,
        flaggedIDs: [UInt32],
        payloadEntropy: Double,
        averageInterArrivalMs: Double,
        messageCount: Int,
        rationale: String
    ) {
        self.status = status
        self.anomalyScore = anomalyScore
        self.flaggedIDs = flaggedIDs
        self.payloadEntropy = payloadEntropy
        self.averageInterArrivalMs = averageInterArrivalMs
        self.messageCount = messageCount
        self.rationale = rationale
    }
}

/// Trame CAN brute pour l'analyse de flux IDS
public struct CANSampleFrame: Sendable {
    public let canID: UInt32
    public let payload: [UInt8]
    public let timestampSeconds: Double

    public init(canID: UInt32, payload: [UInt8], timestampSeconds: Double) {
        self.canID = canID
        self.payload = payload
        self.timestampSeconds = timestampSeconds
    }
}

/// Détecteur d'intrusion et d'anomalies de bus CAN temps réel (Automotive IDS)
public actor CANIntrusionDetector {
    private var frameBuffer: [CANSampleFrame] = []
    private let windowSize: Int
    private var idLastTimestamp: [UInt32: Double] = [:]
    private var idIntervals: [UInt32: [Double]] = [:]

    public init(windowSize: Int = 100) {
        self.windowSize = windowSize
    }

    /// Réinitialise l'historique d'acquisition
    public func reset() {
        frameBuffer.removeAll()
        idLastTimestamp.removeAll()
        idIntervals.removeAll()
    }

    /// Enregistre une trame CAN et évalue la sécurité du bus
    public func ingest(frame: CANSampleFrame) -> BusAnomalyReport {
        frameBuffer.append(frame)
        if frameBuffer.count > windowSize {
            frameBuffer.removeFirst()
        }

        // Calcul des intervalles inter-trames par ID
        if let lastT = idLastTimestamp[frame.canID] {
            let dt = frame.timestampSeconds - lastT
            if dt > 0 {
                idIntervals[frame.canID, default: []].append(dt)
                if (idIntervals[frame.canID]?.count ?? 0) > 20 {
                    idIntervals[frame.canID]?.removeFirst()
                }
            }
        }
        idLastTimestamp[frame.canID] = frame.timestampSeconds

        return evaluateSecurity()
    }

    /// Évalue l'ensemble des métriques de la fenêtre glissante
    public func evaluateSecurity() -> BusAnomalyReport {
        guard frameBuffer.count >= 10 else {
            return BusAnomalyReport(
                status: .nominal,
                anomalyScore: 0.0,
                flaggedIDs: [],
                payloadEntropy: 0.0,
                averageInterArrivalMs: 0.0,
                messageCount: frameBuffer.count,
                rationale: "Acquisition initiale en cours..."
            )
        }

        // 1. Calcul de l'entropie de Shannon globale des octets
        var byteFrequencies = [UInt8: Int]()
        var totalBytes = 0
        for f in frameBuffer {
            for b in f.payload {
                byteFrequencies[b, default: 0] += 1
                totalBytes += 1
            }
        }

        var entropy = 0.0
        if totalBytes > 0 {
            for (_, count) in byteFrequencies {
                let p = Double(count) / Double(totalBytes)
                entropy -= p * log2(p)
            }
        }

        // 2. Calcul du débit récent (dernières trames) et global
        let recentCount = min(12, frameBuffer.count)
        let recentSlice = frameBuffer.suffix(recentCount)
        var recentDtSum = 0.0
        var recentPairs = 0
        var prevT: Double? = nil
        for f in recentSlice {
            if let pt = prevT {
                let dt = (f.timestampSeconds - pt) * 1000.0
                if dt >= 0 {
                    recentDtSum += dt
                    recentPairs += 1
                }
            }
            prevT = f.timestampSeconds
        }
        let recentAvgDtMs = recentPairs > 0 ? (recentDtSum / Double(recentPairs)) : 10.0

        // 3. Détection de gigue anormale sur les IDs périodiques
        var suspiciousIDs: [UInt32] = []
        for (id, intervals) in idIntervals where intervals.count >= 5 {
            let mean = intervals.reduce(0, +) / Double(intervals.count)
            let variance = intervals.reduce(0) { $0 + pow($1 - mean, 2) } / Double(intervals.count)
            let stdDev = sqrt(variance)
            let coefficientOfVariation = mean > 0.0001 ? (stdDev / mean) : 0.0

            // Si un ID cyclique présente une dispersion violente ou une injection ultra-rapide
            if coefficientOfVariation > 1.8 && mean < 0.005 {
                suspiciousIDs.append(id)
            }
        }

        // 4. Calcul du score global d'anomalie
        var score = 0.0
        var status = BusAnomalyReport.BusSecurityStatus.nominal
        var rationale = "Flux CAN stable et prévisible."

        if recentAvgDtMs < 0.3 { // Moins de 300 microsecondes récent = flood CAN
            score = 0.95
            status = .busFlood
            rationale = "Saturation extrême du bus détectée (débit > 3 300 trames/s)."
        } else if !suspiciousIDs.isEmpty {
            score = 0.75
            status = .injectionDetected
            rationale = "Injection asynchrone suspecte ou fuzzing actif sur les identifiants: \(suspiciousIDs.map { String(format: "0x%X", $0) }.joined(separator: ", "))."
        } else if entropy > 7.6 {
            score = 0.60
            status = .suspiciousJitter
            rationale = "Entropie de charge utile anormalement élevée (\(String(format: "%.2f", entropy)) bits/octet), possible flux aléatoire ou payload inconnu."
        }

        return BusAnomalyReport(
            status: status,
            anomalyScore: score,
            flaggedIDs: suspiciousIDs,
            payloadEntropy: entropy,
            averageInterArrivalMs: recentAvgDtMs,
            messageCount: frameBuffer.count,
            rationale: rationale
        )
    }
}
