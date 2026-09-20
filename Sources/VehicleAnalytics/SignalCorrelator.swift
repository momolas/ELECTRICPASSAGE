import Foundation
import VehicleCore
#if canImport(Accelerate)
import Accelerate
#endif

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

public enum SignalCorrelator: Sendable {

    /// Calcule le coefficient de corrélation linéaire de Pearson entre deux séries
    /// Utilise automatiquement l'accélération vectorielle SIMD (Apple Accelerate) si disponible.
    public static func pearsonCorrelation(x: [Double], y: [Double]) -> Double? {
        guard x.count == y.count, x.count >= 2 else { return nil }
        #if canImport(Accelerate)
        return acceleratedPearson(x: x, y: y)
        #else
        return scalarPearson(x: x, y: y)
        #endif
    }

    #if canImport(Accelerate)
    /// Calcul vectoriel SIMD ultra-haute performance exploitant vDSP (Apple Accelerate)
    public static func acceleratedPearson(x: [Double], y: [Double]) -> Double? {
        guard x.count == y.count, x.count >= 2 else { return nil }
        let n = vDSP_Length(x.count)

        var meanX = 0.0
        var meanY = 0.0
        vDSP_meanvD(x, 1, &meanX, n)
        vDSP_meanvD(y, 1, &meanY, n)

        var negMeanX = -meanX
        var negMeanY = -meanY
        var dx = [Double](repeating: 0.0, count: x.count)
        var dy = [Double](repeating: 0.0, count: y.count)

        // Soustraction vectorielle SIMD en 1 passe
        vDSP_vsaddD(x, 1, &negMeanX, &dx, 1, n)
        vDSP_vsaddD(y, 1, &negMeanY, &dy, 1, n)

        var num = 0.0
        var sumSqX = 0.0
        var sumSqY = 0.0

        // Produits scalaires et sommes des carrés vectorisés
        vDSP_dotprD(dx, 1, dy, 1, &num, n)
        vDSP_svesqD(dx, 1, &sumSqX, n)
        vDSP_svesqD(dy, 1, &sumSqY, n)

        let den = sqrt(sumSqX * sumSqY)
        guard den > 1e-9 else { return nil }
        return num / den
    }
    #endif

    /// Version scalaire de référence (fallback pur Swift)
    public static func scalarPearson(x: [Double], y: [Double]) -> Double? {
        guard x.count == y.count, x.count >= 2 else { return nil }
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

        let den = sqrt(denX * denY)
        guard den > 1e-9 else { return nil }
        return num / den
    }

    /// Analyse les corrélations de toutes les tranches 8-bit et 16-bit d'une matrice d'octets avec des signaux de référence
    public static func correlateSlices(
        byteRows: [[UInt8]],
        references: [String: [Double]],
        minimumSamples: Int = 6
    ) -> [SliceCorrelation] {
        guard !byteRows.isEmpty, !references.isEmpty else { return [] }
        let nBytes = byteRows[0].count
        guard nBytes > 0 else { return [] }

        var minCount = byteRows.count
        for (_, refValues) in references {
            minCount = min(minCount, refValues.count)
        }
        guard minCount >= minimumSamples else { return [] }

        let alignedRows = Array(byteRows.suffix(minCount))
        var slices: [String: [Double]] = [:]

        // Génération des tranches 8-bit (A, B, C...)
        let labels = (0..<nBytes).map { String(Character(UnicodeScalar(UInt8(65 + ($0 % 26))))) }
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
            let sMin: Double
            let sMax: Double
            #if canImport(Accelerate)
            var minVal = 0.0
            var maxVal = 0.0
            vDSP_minvD(sVals, 1, &minVal, vDSP_Length(sVals.count))
            vDSP_maxvD(sVals, 1, &maxVal, vDSP_Length(sVals.count))
            sMin = minVal
            sMax = maxVal
            #else
            sMin = sVals.min() ?? 0.0
            sMax = sVals.max() ?? 0.0
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
