import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// Module de filtrage et lissage numérique de signaux télémétriques automobiles (PIDs, bus CAN).
public enum SignalFilter: Sendable {

    /// Filtre numérique récursif IIR Biquad (Butterworth d'ordre 2)
    public struct Biquad: Sendable {
        public let b0: Double
        public let b1: Double
        public let b2: Double
        public let a1: Double
        public let a2: Double

        // État interne pour le streaming temps réel
        public struct State: Sendable {
            public var x1: Double = 0.0
            public var x2: Double = 0.0
            public var y1: Double = 0.0
            public var y2: Double = 0.0
            public init() {}
        }

        public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
            self.b0 = b0
            self.b1 = b1
            self.b2 = b2
            self.a1 = a1
            self.a2 = a2
        }

        /// Crée un filtre passe-bas Butterworth 2e ordre
        /// - Parameters:
        ///   - cutoffFrequency: Fréquence de coupure en Hz (ex: 2.0 Hz pour supprimer le bruit)
        ///   - sampleRate: Fréquence d'échantillonnage en Hz (ex: 10.0 Hz pour un PID rapide)
        ///   - q: Facteur de qualité (défaut: 1 / sqrt(2) ≈ 0.7071 pour Butterworth critique)
        public static func lowPass(cutoffFrequency: Double, sampleRate: Double, q: Double = 0.70710678) -> Biquad {
            let omega = 2.0 * Double.pi * (cutoffFrequency / sampleRate)
            let sinOmega = sin(omega)
            let cosOmega = cos(omega)
            let alpha = sinOmega / (2.0 * q)

            let a0 = 1.0 + alpha
            let b0 = ((1.0 - cosOmega) / 2.0) / a0
            let b1 = (1.0 - cosOmega) / a0
            let b2 = ((1.0 - cosOmega) / 2.0) / a0
            let a1 = (-2.0 * cosOmega) / a0
            let a2 = (1.0 - alpha) / a0

            return Biquad(b0: b0, b1: b1, b2: b2, a1: a1, a2: a2)
        }

        /// Filtre un échantillon unique en mettant à jour l'état glissant (latence nulle)
        public func filter(sample: Double, state: inout State) -> Double {
            let y = (b0 * sample) + (b1 * state.x1) + (b2 * state.x2) - (a1 * state.y1) - (a2 * state.y2)
            state.x2 = state.x1
            state.x1 = sample
            state.y2 = state.y1
            state.y1 = y
            return y
        }

        /// Filtre un tableau complet de points (avec accélération SIMD si disponible)
        public func filter(batch: [Double]) -> [Double] {
            guard !batch.isEmpty else { return [] }
            var state = State()
            var result = [Double](repeating: 0.0, count: batch.count)
            for i in 0..<batch.count {
                result[i] = filter(sample: batch[i], state: &state)
            }
            return result
        }
    }

    /// Moyenne mobile exponentielle (EMA) : lissage fluide avec pondération temporelle
    public static func exponentialMovingAverage(values: [Double], alpha: Double) -> [Double] {
        guard !values.isEmpty else { return [] }
        let clampedAlpha = max(0.001, min(1.0, alpha))
        var result = [Double](repeating: 0.0, count: values.count)
        result[0] = values[0]
        for i in 1..<values.count {
            result[i] = (clampedAlpha * values[i]) + ((1.0 - clampedAlpha) * result[i - 1])
        }
        return result
    }

    /// Filtre Médian glissant : suppression radicale des pics d'artefacts (spikes) de bus
    public static func medianFilter(values: [Double], windowSize: Int = 3) -> [Double] {
        guard values.count >= windowSize, windowSize >= 3 else { return values }
        let half = windowSize / 2
        var result = values

        for i in half..<(values.count - half) {
            let window = values[(i - half)...(i + half)].sorted()
            result[i] = window[window.count / 2]
        }
        return result
    }
}
