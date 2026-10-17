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
        guard samples.count >= 8,
              samples.allSatisfy(\.isFinite),
              sampleRateHz.isFinite,
              sampleRateHz > 0,
              topPeaksCount > 0 else { return nil }

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
        let mean = vDSP.mean(samples)
        let centered = vDSP.add(-mean, samples)

        guard let setup = vDSP_DFT_zop_CreateSetupD(nil, vDSP_Length(n), .FORWARD) else {
            return scalarDFT(samples: centered, sampleRateHz: sampleRateHz, topPeaksCount: topPeaksCount)
        }
        defer { vDSP_DFT_DestroySetupD(setup) }

        var inputReal = centered
        var inputImag = [Double](repeating: 0.0, count: n)
        var realOut = [Double](repeating: 0.0, count: n)
        var imagOut = [Double](repeating: 0.0, count: n)

        vDSP_DFT_ExecuteD(setup, &inputReal, &inputImag, &realOut, &imagOut)

        let halfN = (n / 2) + 1
        var magnitudes = [Double](repeating: 0.0, count: halfN)
        // Magnitude = sqrt(real^2 + imag^2) / (n / 2)
        vDSP_vdistD(&realOut, 1, &imagOut, 1, &magnitudes, 1, vDSP_Length(halfN))
        let scale = 2.0 / Double(n)
        magnitudes = vDSP.multiply(scale, magnitudes)
        magnitudes[0] /= 2.0 // Normalisation composante DC
        if n % 2 == 0 {
            magnitudes[halfN - 1] /= 2.0 // Normalisation composante Nyquist
        }

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
        guard n > 0, samples.allSatisfy(\.isFinite), sampleRateHz.isFinite, sampleRateHz > 0 else {
            return SpectralResult(samplingRateHz: max(0.0, sampleRateHz), frequencies: [], magnitudes: [], dominantPeaks: [])
        }
        let mean = samples.reduce(0.0, +) / Double(n)
        let centered = samples.map { $0 - mean }

        let halfN = (n / 2) + 1
        var frequencies = [Double](repeating: 0.0, count: halfN)
        var magnitudes = [Double](repeating: 0.0, count: halfN)
        let freqStep = sampleRateHz / Double(n)

        for k in 0..<halfN {
            frequencies[k] = Double(k) * freqStep
            var sumReal = 0.0
            var sumImag = 0.0
            for t in 0..<n {
                let angle = 2.0 * Double.pi * Double(k * t) / Double(n)
                sumReal += centered[t] * cos(angle)
                sumImag -= centered[t] * sin(angle)
            }
            let rawMag = sqrt(sumReal * sumReal + sumImag * sumImag)
            let isDCOrNyquist = (k == 0) || (k == n / 2 && n % 2 == 0)
            magnitudes[k] = (isDCOrNyquist ? 1.0 : 2.0) * rawMag / Double(n)
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
        guard frequencies.count == magnitudes.count, !frequencies.isEmpty, topCount > 0 else { return [] }
        // Ignorer la composante continue (DC / k=0) et privilégier les maxima locaux
        var localMaxPeaks: [(index: Int, freq: Double, mag: Double)] = []
        var fallbackPeaks: [(index: Int, freq: Double, mag: Double)] = []

        for i in 1..<frequencies.count {
            let isLocalMax = i > 1 && i + 1 < magnitudes.count &&
                magnitudes[i] >= magnitudes[i - 1] &&
                magnitudes[i] >= magnitudes[i + 1]
            if isLocalMax {
                localMaxPeaks.append((i, frequencies[i], magnitudes[i]))
            } else {
                fallbackPeaks.append((i, frequencies[i], magnitudes[i]))
            }
        }

        var selected = localMaxPeaks.sorted { $0.mag > $1.mag }
        if selected.count < topCount {
            let remaining = fallbackPeaks.sorted { $0.mag > $1.mag }
            selected.append(contentsOf: remaining.prefix(topCount - selected.count))
        }

        let safeCount = min(selected.count, topCount)
        return selected.prefix(safeCount).map {
            SpectralResult.Peak(frequencyHz: $0.freq, magnitude: $0.mag)
        }
    }
}
