import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// Résultat de l'analyse spectrale (FFT / DFT)
public struct SpectralResult: Sendable, Equatable {
    public struct Peak: Sendable, Equatable {
        public let frequencyHz: Double
        public let magnitude: Double
        public init(frequencyHz: Double, magnitude: Double) {
            self.frequencyHz = frequencyHz
            self.magnitude = magnitude
        }
    }

    public let samplingRateHz: Double
    public let frequencies: [Double]
    public let magnitudes: [Double]
    public let dominantPeaks: [Peak]

    public init(
        samplingRateHz: Double,
        frequencies: [Double],
        magnitudes: [Double],
        dominantPeaks: [Peak]
    ) {
        self.samplingRateHz = samplingRateHz
        self.frequencies = frequencies
        self.magnitudes = magnitudes
        self.dominantPeaks = dominantPeaks
    }
}

/// Analyseur spectral temps réel pour bus CAN et signaux télémétriques (RPM, vibrations, jitter)
public enum SpectralAnalyzer: Sendable {

    /// Calcule le spectre d'amplitude d'un signal et isole les fréquences dominantes
    /// - Parameters:
    ///   - samples: Série temporelle d'échantillons (de préférence une puissance de 2: 64, 128, 256, etc.)
    ///   - sampleRateHz: Fréquence d'échantillonnage en Hz (ex: 100 Hz)
    ///   - topPeaksCount: Nombre de pics dominants à extraire
    public static func analyze(
        samples: [Double],
        sampleRateHz: Double,
        topPeaksCount: Int = 3
    ) -> SpectralResult? {
        guard samples.count >= 8, sampleRateHz > 0 else { return nil }

        #if canImport(Accelerate)
        return acceleratedDFT(samples: samples, sampleRateHz: sampleRateHz, topPeaksCount: topPeaksCount)
        #else
        return scalarDFT(samples: samples, sampleRateHz: sampleRateHz, topPeaksCount: topPeaksCount)
        #endif
    }

    #if canImport(Accelerate)
    private static func acceleratedDFT(
        samples: [Double],
        sampleRateHz: Double,
        topPeaksCount: Int
    ) -> SpectralResult? {
        let n = samples.count
        guard let setup = vDSP_DFT_zop_CreateSetupD(nil, vDSP_Length(n), .FORWARD) else {
            return scalarDFT(samples: samples, sampleRateHz: sampleRateHz, topPeaksCount: topPeaksCount)
        }
        defer { vDSP_DFT_DestroySetupD(setup) }

        var inputReal = samples
        var inputImag = [Double](repeating: 0.0, count: n)
        var realOut = [Double](repeating: 0.0, count: n)
        var imagOut = [Double](repeating: 0.0, count: n)

        vDSP_DFT_ExecuteD(setup, &inputReal, &inputImag, &realOut, &imagOut)

        let halfN = n / 2
        var magnitudes = [Double](repeating: 0.0, count: halfN)
        // Magnitude = sqrt(real^2 + imag^2) / (n / 2)
        vDSP_vdistD(&realOut, 1, &imagOut, 1, &magnitudes, 1, vDSP_Length(halfN))
        var scale = 2.0 / Double(n)
        vDSP_vsmulD(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(halfN))
        magnitudes[0] /= 2.0 // Normalisation composante DC

        let freqStep = sampleRateHz / Double(n)
        var frequencies = [Double](repeating: 0.0, count: halfN)
        for i in 0..<halfN {
            frequencies[i] = Double(i) * freqStep
        }

        let peaks = extractPeaks(frequencies: frequencies, magnitudes: magnitudes, topCount: topPeaksCount)
        return SpectralResult(
            samplingRateHz: sampleRateHz,
            frequencies: frequencies,
            magnitudes: magnitudes,
            dominantPeaks: peaks
        )
    }
    #endif

    /// Fallback scalaire (DFT discrète)
    public static func scalarDFT(
        samples: [Double],
        sampleRateHz: Double,
        topPeaksCount: Int
    ) -> SpectralResult {
        let n = samples.count
        let halfN = n / 2
        var frequencies = [Double](repeating: 0.0, count: halfN)
        var magnitudes = [Double](repeating: 0.0, count: halfN)
        let freqStep = sampleRateHz / Double(n)

        for k in 0..<halfN {
            frequencies[k] = Double(k) * freqStep
            var sumReal = 0.0
            var sumImag = 0.0
            for t in 0..<n {
                let angle = 2.0 * Double.pi * Double(k * t) / Double(n)
                sumReal += samples[t] * cos(angle)
                sumImag -= samples[t] * sin(angle)
            }
            let rawMag = sqrt(sumReal * sumReal + sumImag * sumImag)
            magnitudes[k] = (k == 0 ? 1.0 : 2.0) * rawMag / Double(n)
        }

        let peaks = extractPeaks(frequencies: frequencies, magnitudes: magnitudes, topCount: topPeaksCount)
        return SpectralResult(
            samplingRateHz: sampleRateHz,
            frequencies: frequencies,
            magnitudes: magnitudes,
            dominantPeaks: peaks
        )
    }

    private static func extractPeaks(
        frequencies: [Double],
        magnitudes: [Double],
        topCount: Int
    ) -> [SpectralResult.Peak] {
        guard frequencies.count == magnitudes.count, !frequencies.isEmpty else { return [] }
        // Ignorer la composante continue (DC / k=0) pour la détection de pics oscillants
        var indexedPeaks: [(freq: Double, mag: Double)] = []
        for i in 1..<frequencies.count {
            indexedPeaks.append((frequencies[i], magnitudes[i]))
        }
        let sorted = indexedPeaks.sorted { $0.mag > $1.mag }
        return sorted.prefix(topCount).map { SpectralResult.Peak(frequencyHz: $0.freq, magnitude: $0.mag) }
    }
}
