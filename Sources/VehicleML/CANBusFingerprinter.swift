import Foundation
import VehicleCore

/// Statistique temporelle et dimensionnelle d'un identifiant CAN observé passivement (méthode `c0f`)
public struct CANIDIntervalStat: Sendable, Equatable, Codable {
    public let canID: UInt32
    public let occurrenceCount: Int
    public let minDLC: Int
    public let maxDLC: Int
    public let meanIntervalSeconds: Double?
    public let intervalStdDevSeconds: Double?

    public init(
        canID: UInt32,
        occurrenceCount: Int,
        minDLC: Int,
        maxDLC: Int,
        meanIntervalSeconds: Double?,
        intervalStdDevSeconds: Double?
    ) {
        self.canID = canID
        self.occurrenceCount = occurrenceCount
        self.minDLC = minDLC
        self.maxDLC = maxDLC
        self.meanIntervalSeconds = meanIntervalSeconds
        self.intervalStdDevSeconds = intervalStdDevSeconds
    }
}

/// Empreinte passive d'un bus CAN (inspirée de l'outil `c0f` — Craig Smith, *The Car Hacker's Handbook*, Ch. 11)
public struct CANBusFingerprint: Sendable, Equatable, Codable {
    /// `true` si au moins une trame utilise une longueur DLC dynamique (< 8 octets), `false` si toutes les trames sont fixées à 8 octets
    public let isDynamicDLC: Bool
    /// Octet de bourrage constant détecté en fin de trames de 8 octets (`0x00`, `0xFF`, `0xAA`, `0x55`), ou `nil`
    public let paddingByte: UInt8?
    /// Cluster des identifiants CAN périodiques partageant la fréquence cardinale principale du bus
    public let commonIDs: [UInt32]
    /// Identifiant CAN dominant (le plus fréquent avec l'intervalle moyen le plus court parmi les `commonIDs`)
    public let mainID: UInt32?
    /// Période moyenne d'émission (en secondes) du `mainID`
    public let mainIntervalSeconds: Double?
    /// Nombre total de trames CAN valides analysées
    public let sampleCount: Int
    /// Statistiques détaillées par identifiant CAN (triées par ID croissant)
    public let idStatistics: [CANIDIntervalStat]

    public init(
        isDynamicDLC: Bool,
        paddingByte: UInt8?,
        commonIDs: [UInt32],
        mainID: UInt32?,
        mainIntervalSeconds: Double?,
        sampleCount: Int,
        idStatistics: [CANIDIntervalStat]
    ) {
        self.isDynamicDLC = isDynamicDLC
        self.paddingByte = paddingByte
        self.commonIDs = commonIDs
        self.mainID = mainID
        self.mainIntervalSeconds = mainIntervalSeconds
        self.sampleCount = sampleCount
        self.idStatistics = idStatistics
    }
}

/// Profil d'empreinte CAN de référence associé à un constructeur / modèle / plateforme châssis
public struct KnownChassisFingerprint: Sendable, Equatable, Codable {
    public let make: String
    public let model: String
    public let platformCode: String
    public let referenceFingerprint: CANBusFingerprint

    public init(
        make: String,
        model: String,
        platformCode: String,
        referenceFingerprint: CANBusFingerprint
    ) {
        self.make = make
        self.model = model
        self.platformCode = platformCode
        self.referenceFingerprint = referenceFingerprint
    }
}

/// Moteur de prise d'empreinte passive du bus CAN sans émission (`Zero-TX` CAN Bus Fingerprinter)
/// Implémente l'algorithme statistique de caractérisation d'architecture véhicule décrit par Craig Smith (Ch. 11).
public enum CANBusFingerprinter {

    /// Génère l'empreinte passive `CANBusFingerprint` à partir d'une capture de trames `CANSampleFrame`.
    public static func fingerprint(frames: [CANSampleFrame]) -> CANBusFingerprint {
        let validFrames = frames.filter { $0.timestampSeconds.isFinite && $0.timestampSeconds >= 0 && !$0.payload.isEmpty }
        guard !validFrames.isEmpty else {
            return CANBusFingerprint(
                isDynamicDLC: false,
                paddingByte: nil,
                commonIDs: [],
                mainID: nil,
                mainIntervalSeconds: nil,
                sampleCount: 0,
                idStatistics: []
            )
        }

        var counts: [UInt32: Int] = [:]
        var minDLCs: [UInt32: Int] = [:]
        var maxDLCs: [UInt32: Int] = [:]
        var lastTimestamp: [UInt32: Double] = [:]
        var intervalsByID: [UInt32: [Double]] = [:]

        var hasSubEightByteFrame = false
        var trailingByteHistogram: [UInt8: Int] = [:]
        var eightByteFrameCount = 0

        // Tri chronologique défensif pour garantir la positivité des intervalles
        let sortedFrames = validFrames.sorted { $0.timestampSeconds < $1.timestampSeconds }

        for frame in sortedFrames {
            let id = frame.canID
            let dlc = frame.payload.count
            counts[id, default: 0] += 1
            minDLCs[id] = min(minDLCs[id] ?? dlc, dlc)
            maxDLCs[id] = max(maxDLCs[id] ?? dlc, dlc)

            if dlc < 8 {
                hasSubEightByteFrame = true
            } else if dlc == 8, let lastByte = frame.payload.last {
                eightByteFrameCount += 1
                // Vérifie si les 2 derniers octets sont identiques (signature typique de bourrage fixe)
                if frame.payload[6] == lastByte {
                    trailingByteHistogram[lastByte, default: 0] += 1
                }
            }

            if let prevT = lastTimestamp[id] {
                let dt = frame.timestampSeconds - prevT
                if dt > 0 && dt.isFinite {
                    intervalsByID[id, default: []].append(dt)
                }
            }
            lastTimestamp[id] = frame.timestampSeconds
        }

        // Détection de l'octet de bourrage dominant lorsque le bus n'est pas dynamique (DLC fixe à 8)
        let detectedPadding: UInt8?
        if !hasSubEightByteFrame && eightByteFrameCount >= 4 {
            let candidateBytes: Set<UInt8> = [0x00, 0xFF, 0xAA, 0x55]
            if let best = trailingByteHistogram
                .filter({ candidateBytes.contains($0.key) })
                .max(by: { $0.value < $1.value }),
               Double(best.value) / Double(eightByteFrameCount) >= 0.50 {
                detectedPadding = best.key
            } else {
                detectedPadding = nil
            }
        } else {
            detectedPadding = nil
        }

        // Construction des statistiques par ID
        var stats: [CANIDIntervalStat] = []
        stats.reserveCapacity(counts.count)

        for id in counts.keys.sorted() {
            let count = counts[id] ?? 0
            let minD = minDLCs[id] ?? 0
            let maxD = maxDLCs[id] ?? 0
            let dts = intervalsByID[id] ?? []

            let meanDT: Double?
            let stdDT: Double?
            if !dts.isEmpty {
                let mean = dts.reduce(0.0, +) / Double(dts.count)
                meanDT = mean
                if dts.count >= 2 {
                    let variance = dts.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(dts.count)
                    stdDT = sqrt(max(0.0, variance))
                } else {
                    stdDT = 0.0
                }
            } else {
                meanDT = nil
                stdDT = nil
            }

            stats.append(
                CANIDIntervalStat(
                    canID: id,
                    occurrenceCount: count,
                    minDLC: minD,
                    maxDLC: maxD,
                    meanIntervalSeconds: meanDT,
                    intervalStdDevSeconds: stdDT
                )
            )
        }

        // Identification du cluster `commonIDs` et du `mainID` selon l'heuristique `c0f` :
        // Les signaux haute fréquence d'un même calculateur/bus apparaissent avec un nombre d'occurrences
        // quasi identique (tolérance ±1 trame liée aux bords de fenêtre de capture).
        let maxCount = stats.map(\.occurrenceCount).max() ?? 0
        let thresholdCount = (maxCount <= 1) ? 1 : max(2, Int((Double(maxCount) * 0.85).rounded(.down)))

        let commonStats = stats.filter { $0.occurrenceCount >= thresholdCount }
        let commonIDs = commonStats.map(\.canID).sorted()

        let mainStat = commonStats.min { lhs, rhs in
            if lhs.occurrenceCount != rhs.occurrenceCount {
                return lhs.occurrenceCount > rhs.occurrenceCount
            }
            let lMean = lhs.meanIntervalSeconds ?? .infinity
            let rMean = rhs.meanIntervalSeconds ?? .infinity
            if abs(lMean - rMean) > 1e-6 {
                return lMean < rMean
            }
            return lhs.canID < rhs.canID
        }

        return CANBusFingerprint(
            isDynamicDLC: hasSubEightByteFrame,
            paddingByte: detectedPadding,
            commonIDs: commonIDs,
            mainID: mainStat?.canID,
            mainIntervalSeconds: mainStat?.meanIntervalSeconds,
            sampleCount: validFrames.count,
            idStatistics: stats
        )
    }

    /// Calcule un score de similarité normalisé `[0.0, 1.0]` entre deux empreintes CAN.
    public static func similarity(between lhs: CANBusFingerprint, and rhs: CANBusFingerprint) -> Double {
        guard lhs.sampleCount > 0 && rhs.sampleCount > 0 else { return 0.0 }

        // 1. Recouvrement de Jaccard sur les `commonIDs` (ou repli sur `idStatistics` si vides, poids 55%)
        let idsA = lhs.commonIDs.isEmpty ? lhs.idStatistics.map(\.canID) : lhs.commonIDs
        let idsB = rhs.commonIDs.isEmpty ? rhs.idStatistics.map(\.canID) : rhs.commonIDs
        let setA = Set(idsA)
        let setB = Set(idsB)
        let unionCount = setA.union(setB).count
        let jaccardCommon = unionCount > 0 ? Double(setA.intersection(setB).count) / Double(unionCount) : 0.0

        // 2. Concordance du mode DLC dynamique vs statique 8 octets (poids 15%)
        let dlcScore = (lhs.isDynamicDLC == rhs.isDynamicDLC) ? 1.0 : 0.0

        // 3. Concordance de l'octet de bourrage (poids 10%)
        let paddingScore: Double
        if lhs.paddingByte == rhs.paddingByte {
            paddingScore = 1.0
        } else if lhs.paddingByte == nil || rhs.paddingByte == nil {
            paddingScore = 0.5
        } else {
            paddingScore = 0.0
        }

        // 4. Proximité de la période `mainIntervalSeconds` (poids 20%)
        let intervalScore: Double
        if let dtA = lhs.mainIntervalSeconds, let dtB = rhs.mainIntervalSeconds, dtA > 0, dtB > 0 {
            let relError = abs(dtA - dtB) / max(dtA, dtB)
            intervalScore = max(0.0, 1.0 - min(1.0, relError * 5.0))
        } else if lhs.mainIntervalSeconds == nil && rhs.mainIntervalSeconds == nil {
            intervalScore = 1.0
        } else {
            intervalScore = 0.0
        }

        return min(1.0, max(0.0, 0.55 * jaccardCommon + 0.15 * dlcScore + 0.10 * paddingScore + 0.20 * intervalScore))
    }

    /// Recherche le profil de châssis le plus proche dans une base d'empreintes connues.
    public static func matchProfile(
        fingerprint: CANBusFingerprint,
        database: [KnownChassisFingerprint],
        minimumConfidence: Double = 0.65
    ) -> (profile: KnownChassisFingerprint, score: Double)? {
        guard fingerprint.sampleCount > 0, !database.isEmpty else { return nil }

        var bestMatch: (profile: KnownChassisFingerprint, score: Double)?
        for entry in database {
            let s = similarity(between: fingerprint, and: entry.referenceFingerprint)
            if s >= minimumConfidence {
                if let currentBest = bestMatch {
                    if s > currentBest.score {
                        bestMatch = (entry, s)
                    }
                } else {
                    bestMatch = (entry, s)
                }
            }
        }
        return bestMatch
    }
}
