import Foundation
import VehicleCore

/// Représente le résultat d'une corrélation sur une tranche de données hexadécimales.
public struct SliceCorrelation: Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let sliceName: String
    public let referenceSignal: String
    public let coefficient: Double
    public let range: Double
    public let classification: String

    public init(
        id: UUID = UUID(),
        sliceName: String,
        referenceSignal: String,
        coefficient: Double,
        range: Double,
        classification: String
    ) {
        self.id = id
        self.sliceName = sliceName
        self.referenceSignal = referenceSignal
        self.coefficient = coefficient
        self.range = range
        self.classification = classification
    }

    public static func == (lhs: SliceCorrelation, rhs: SliceCorrelation) -> Bool {
        lhs.sliceName == rhs.sliceName &&
        lhs.referenceSignal == rhs.referenceSignal &&
        lhs.coefficient == rhs.coefficient &&
        lhs.range == rhs.range &&
        lhs.classification == rhs.classification
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(sliceName)
        hasher.combine(referenceSignal)
        hasher.combine(coefficient)
        hasher.combine(range)
        hasher.combine(classification)
    }
}

#if canImport(Accelerate)
import Accelerate
#endif

public enum SignalCorrelator: Sendable {

    /// Calcule le coefficient de corrélation linéaire de Pearson entre deux séries
    public static func pearsonCorrelation(x: [Double], y: [Double]) -> Double? {
        guard x.count == y.count, x.count >= 2 else { return nil }

        #if canImport(Accelerate)
        let meanX = vDSP.mean(x)
        let meanY = vDSP.mean(y)

        let dx = vDSP.add(-meanX, x)
        let dy = vDSP.add(-meanY, y)

        let num = vDSP.dot(dx, dy)
        let denX = vDSP.dot(dx, dx)
        let denY = vDSP.dot(dy, dy)

        guard denX > 1e-12, denY > 1e-12 else { return nil }
        let den = sqrt(denX) * sqrt(denY)
        guard den > 1e-9 else { return nil }
        let r = num / den
        guard r.isFinite else { return nil }
        return max(-1.0, min(1.0, r))
        #else
        let n = Double(x.count)
        let meanX = x.reduce(0, +) / n
        let meanY = y.reduce(0, +) / n

        var num = 0.0
        var denX = 0.0
        var denY = 0.0

        for i in 0..<x.count {
            let dx = x[i] - meanX
            let dy = y[i] - meanY
            num += dx * dy
            denX += dx * dx
            denY += dy * dy
        }

        guard denX > 1e-12, denY > 1e-12 else { return nil }
        let den = sqrt(denX) * sqrt(denY)
        guard den > 1e-9 else { return nil }
        let r = num / den
        guard r.isFinite else { return nil }
        return max(-1.0, min(1.0, r))
        #endif
    }

    /// Calcule la corrélation croisée avec décalage temporel (Time-Lag $\tau$) entre deux séries temporelles.
    ///
    /// Permet de mesurer le déphasage ou retard de réponse physique (ex: turbo lag, délai papillon/régime).
    ///
    /// - Parameters:
    ///   - x: Série temporelle de commande (ex: position papillon, consigne).
    ///   - y: Série temporelle de réponse (ex: pression de suralimentation, régime).
    ///   - maxLag: Nombre maximum d'échantillons de décalage à explorer (\(\tau \in [-maxLag, +maxLag]\)).
    /// - Returns: Tuple contenant le meilleur lag (en échantillons), la corrélation maximale et la carte des corrélations par lag.
    public static func crossCorrelationWithLag(
        x: [Double],
        y: [Double],
        maxLag: Int = 10
    ) -> (bestLag: Int, bestCorrelation: Double, lags: [Int: Double]) {
        guard x.count == y.count, x.count >= 4, maxLag >= 0 else {
            return (0, 0.0, [:])
        }

        let n = x.count
        let bound = min(maxLag, n / 2)
        var lagMap: [Int: Double] = [:]
        var bestLag = 0
        var bestCorrelation = 0.0

        for lag in -bound...bound {
            let sliceX: [Double]
            let sliceY: [Double]

            if lag >= 0 {
                sliceX = Array(x[0..<(n - lag)])
                sliceY = Array(y[lag..<n])
            } else {
                let k = -lag
                sliceX = Array(x[k..<n])
                sliceY = Array(y[0..<(n - k)])
            }

            if let r = pearsonCorrelation(x: sliceX, y: sliceY) {
                lagMap[lag] = r
                if abs(r) > abs(bestCorrelation) {
                    bestCorrelation = r
                    bestLag = lag
                }
            }
        }

        return (bestLag, bestCorrelation, lagMap)
    }

    /// Génère une étiquette de colonne unique (A..Z, AA..AZ, etc.)
    public static func sliceLabel(for index: Int) -> String {
        guard index >= 0 else { return "" }
        var idx = index
        var result = ""
        repeat {
            let rem = idx % 26
            result = String(Character(UnicodeScalar(65 + UInt8(rem)))) + result
            idx = (idx / 26) - 1
        } while idx >= 0
        return result
    }

    /// Analyse les corrélations de toutes les tranches 8-bit et 16-bit d'une matrice d'octets avec des signaux de référence
    public static func correlateSlices(
        byteRows: [[UInt8]],
        references: [String: [Double]],
        minimumSamples: Int = 6
    ) -> [SliceCorrelation] {
        guard !byteRows.isEmpty, !references.isEmpty else { return [] }
        let nBytes = byteRows[0].count
        guard nBytes > 0, byteRows.allSatisfy({ $0.count >= nBytes }) else { return [] }

        var minCount = byteRows.count
        for (_, refValues) in references {
            minCount = min(minCount, refValues.count)
        }
        guard minCount >= minimumSamples else { return [] }

        let alignedRows = Array(byteRows.suffix(minCount))
        var slices: [String: [Double]] = [:]

        // Génération des tranches 8-bit (A, B, C... sans collision au-delà de 26 octets)
        let labels = (0..<nBytes).map { sliceLabel(for: $0) }
        for i in 0..<nBytes {
            slices[labels[i]] = alignedRows.map { Double($0[i]) }
        }

        // Génération des tranches 16-bit Big-Endian (AB, BC...)
        for i in 0..<(nBytes - 1) {
            let label16 = "\(labels[i])\(labels[i+1])"
            slices[label16] = alignedRows.map { Double((Int($0[i]) << 8) | Int($0[i+1])) }
        }

        var results: [SliceCorrelation] = []

        for (sliceName, sVals) in slices {
            #if canImport(Accelerate)
            let sMin = vDSP.minimum(sVals)
            let sMax = vDSP.maximum(sVals)
            #else
            let sMin = sVals.min() ?? 0.0
            let sMax = sVals.max() ?? 0.0
            #endif
            let sRange = sMax - sMin

            for (refName, refValues) in references {
                let alignedRef = Array(refValues.suffix(minCount))
                if let r = pearsonCorrelation(x: sVals, y: alignedRef) {
                    let classification = classify(range: sRange, r: r, refName: refName)
                    results.append(
                        SliceCorrelation(
                            sliceName: sliceName,
                            referenceSignal: refName.uppercased(),
                            coefficient: r,
                            range: sRange,
                            classification: classification
                        )
                    )
                }
            }
        }

        return results.sorted { abs($0.coefficient) > abs($1.coefficient) }
    }

    /// Classification heuristique basée sur le coefficient r et la plage dynamique
    public static func classify(range: Double, r: Double, refName: String) -> String {
        if range == 0 { return "MARKER (Constant)" }
        let absR = abs(r)
        if absR >= 0.75 {
            return "🔥 SIGNAL FORT (\(refName))"
        } else if absR >= 0.50 {
            return "⚡️ Signal potentiel (\(refName))"
        } else if range <= 5 {
            return "Compteur / Dérive"
        }
        return "—"
    }
}
