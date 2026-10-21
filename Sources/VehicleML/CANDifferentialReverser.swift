import Foundation
import VehicleCore
import VehicleAnalytics

/// Ordre des octets (Endianness) d'un signal CAN multi-octets selon la norme Vector DBC
public enum CANByteOrder: String, Sendable, Codable, Equatable, CaseIterable {
    /// Motorola Big-Endian (`@0+` dans la syntaxe Vector DBC)
    case motorolaBigEndian = "Motorola Big-Endian (@0+)"
    /// Intel Little-Endian (`@1+` dans la syntaxe Vector DBC)
    case intelLittleEndian = "Intel Little-Endian (@1+)"

    /// Indicateur syntaxique Vector DBC (`"0"` pour Motorola/Big-Endian, `"1"` pour Intel/Little-Endian)
    public var dbcIndicator: String {
        switch self {
        case .motorolaBigEndian: return "0"
        case .intelLittleEndian: return "1"
        }
    }
}

/// Échantillon physique de vérité terrain (ex: PID OBD-II connu) utilisé pour la régression automatique
public struct CANReferenceSample: Sendable, Equatable, Codable {
    public let timestampSeconds: Double
    public let physicalValue: Double

    public init(timestampSeconds: Double, physicalValue: Double) {
        self.timestampSeconds = timestampSeconds
        self.physicalValue = physicalValue
    }
}

/// Candidat de bit d'état discret isolé par analyse différentielle (Repos vs Action physique)
/// Inspiré de Craig Smith, *The Car Hacker's Handbook*, Ch. 6 (Reversing CAN Bus Communications).
public struct CANDifferentialBitCandidate: Sendable, Equatable, Codable {
    public let canID: UInt32
    public let dlc: Int
    public let byteIndex: Int
    public let bitIndex: Int
    public let bitMask: UInt8
    public let baselineBitValue: UInt8
    public let stimulusBitValue: UInt8
    public let confidence: Double

    public init(
        canID: UInt32,
        dlc: Int,
        byteIndex: Int,
        bitIndex: Int,
        bitMask: UInt8,
        baselineBitValue: UInt8,
        stimulusBitValue: UInt8,
        confidence: Double
    ) {
        self.canID = canID
        self.dlc = dlc
        self.byteIndex = byteIndex
        self.bitIndex = bitIndex
        self.bitMask = bitMask
        self.baselineBitValue = baselineBitValue
        self.stimulusBitValue = stimulusBitValue
        self.confidence = confidence
    }
}

/// Signal analogique CAN rétro-ingéniéré automatiquement par régression linéaire ($y = \text{scale} \cdot x + \text{offset}$)
public struct DiscoveredCANSignal: Sendable, Equatable, Codable {
    public let name: String
    public let canID: UInt32
    public let dlc: Int
    public let startByte: Int
    public let bitLength: Int
    public let byteOrder: CANByteOrder
    public let scale: Double
    public let offset: Double
    public let minValue: Double
    public let maxValue: Double
    public let unit: String
    public let rSquared: Double

    public init(
        name: String,
        canID: UInt32,
        dlc: Int,
        startByte: Int,
        bitLength: Int,
        byteOrder: CANByteOrder,
        scale: Double,
        offset: Double,
        minValue: Double,
        maxValue: Double,
        unit: String,
        rSquared: Double
    ) {
        self.name = name
        self.canID = canID
        self.dlc = dlc
        self.startByte = startByte
        self.bitLength = bitLength
        self.byteOrder = byteOrder
        self.scale = scale
        self.offset = offset
        self.minValue = minValue
        self.maxValue = maxValue
        self.unit = unit
        self.rSquared = rSquared
    }

    /// Bit de départ selon la convention standard Vector `.dbc`
    public var dbcStartBit: Int {
        switch byteOrder {
        case .intelLittleEndian:
            return startByte * 8
        case .motorolaBigEndian:
            return startByte * 8 + 7
        }
    }
}

/// Moteur de rétro-ingénierie différentielle de bus CAN et de synthèse automatique de fichiers Vector `.dbc`
/// Combine l'isolation de bits d'actionneurs (Ch. 6) et la régression affine par moindres carrés sur tranches 8/16-bits.
public enum CANDifferentialReverser: Sendable {

    /// Isole les bits d'état discrets ayant basculé de manière déterministe entre une capture au repos (`baselineFrames`)
    /// et une capture sous action physique (`stimulusFrames`, ex: appui frein, ouverture portière, verrouillage).
    /// Élimine automatiquement les compteurs cycliques (Rolling Counters), les checksums CRC et les capteurs analogiques fluctuants.
    public static func isolateBitTransitions(
        baselineFrames: [CANSampleFrame],
        stimulusFrames: [CANSampleFrame],
        minimumFramesPerState: Int = 6
    ) -> [CANDifferentialBitCandidate] {
        let minCount = max(4, minimumFramesPerState)
        var baseByID: [UInt32: [CANSampleFrame]] = [:]
        var stimByID: [UInt32: [CANSampleFrame]] = [:]

        for frame in baselineFrames where !frame.payload.isEmpty {
            baseByID[frame.canID, default: []].append(frame)
        }
        for frame in stimulusFrames where !frame.payload.isEmpty {
            stimByID[frame.canID, default: []].append(frame)
        }

        var candidates: [CANDifferentialBitCandidate] = []

        for canID in baseByID.keys.sorted() {
            guard let baseList = baseByID[canID],
                  let stimList = stimByID[canID],
                  baseList.count >= minCount,
                  stimList.count >= minCount else {
                continue
            }

            let minBaseDLC = baseList.map(\.payload.count).min() ?? 0
            let minStimDLC = stimList.map(\.payload.count).min() ?? 0
            let dlc = min(minBaseDLC, minStimDLC)
            guard dlc > 0 else { continue }

            for byteIdx in 0..<dlc {
                let baseByteDoubles = baseList.map { Double($0.payload[byteIdx]) }
                let stimByteDoubles = stimList.map { Double($0.payload[byteIdx]) }

                // Élimination des compteurs cycliques / CRC
                let baseClass = SemanticSignalClassifier.classify(sliceName: "B\(byteIdx)", values: baseByteDoubles)
                let stimClass = SemanticSignalClassifier.classify(sliceName: "S\(byteIdx)", values: stimByteDoubles)
                if baseClass.category == .counterOrCRC || stimClass.category == .counterOrCRC {
                    continue
                }

                // Élimination des octets analogiques variant continuellement à l'intérieur d'un même état (> 2 valeurs distinctes)
                let distinctBaseBytes = Set(baseList.map { $0.payload[byteIdx] })
                let distinctStimBytes = Set(stimList.map { $0.payload[byteIdx] })
                if distinctBaseBytes.count > 2 || distinctStimBytes.count > 2 {
                    continue
                }

                for bitIdx in 0..<8 {
                    let mask = UInt8(1 << bitIdx)
                    let baseBits = baseList.map { ($0.payload[byteIdx] & mask) != 0 ? UInt8(1) : UInt8(0) }
                    let stimBits = stimList.map { ($0.payload[byteIdx] & mask) != 0 ? UInt8(1) : UInt8(0) }

                    let baseOnes = baseBits.reduce(0) { $0 + Int($1) }
                    let stimOnes = stimBits.reduce(0) { $0 + Int($1) }

                    let baseRatioOne = Double(baseOnes) / Double(baseBits.count)
                    let stimRatioOne = Double(stimOnes) / Double(stimBits.count)

                    // Le bit au repos doit être quasi-constant (>= 95 % à 0 ou >= 95 % à 1)
                    let baseDominant: UInt8
                    let baseStability: Double
                    if baseRatioOne <= 0.05 {
                        baseDominant = 0
                        baseStability = 1.0 - baseRatioOne
                    } else if baseRatioOne >= 0.95 {
                        baseDominant = 1
                        baseStability = baseRatioOne
                    } else {
                        continue
                    }

                    // Le bit sous stimulus doit avoir basculé dans l'état opposé (>= 90 %)
                    let stimDominant: UInt8
                    let stimStability: Double
                    if stimRatioOne >= 0.90 {
                        stimDominant = 1
                        stimStability = stimRatioOne
                    } else if stimRatioOne <= 0.10 {
                        stimDominant = 0
                        stimStability = 1.0 - stimRatioOne
                    } else {
                        continue
                    }

                    guard baseDominant != stimDominant else { continue }

                    let confidence = min(1.0, max(0.0, (baseStability + stimStability) / 2.0))
                    candidates.append(
                        CANDifferentialBitCandidate(
                            canID: canID,
                            dlc: dlc,
                            byteIndex: byteIdx,
                            bitIndex: bitIdx,
                            bitMask: mask,
                            baselineBitValue: baseDominant,
                            stimulusBitValue: stimDominant,
                            confidence: confidence
                        )
                    )
                }
            }
        }

        return candidates.sorted {
            if abs($0.confidence - $1.confidence) > 1e-6 {
                return $0.confidence > $1.confidence
            }
            if $0.canID != $1.canID {
                return $0.canID < $1.canID
            }
            if $0.byteIndex != $1.byteIndex {
                return $0.byteIndex < $1.byteIndex
            }
            return $0.bitIndex < $1.bitIndex
        }
    }

    /// Découvre automatiquement la position, l'endianness (Motorola BE vs Intel LE), le facteur d'échelle (`scale`)
    /// et l'`offset` d'un signal analogique CAN à partir d'une série de référence (ex: RPM ou vitesse OBD-II).
    public static func discoverAnalogSignals(
        frames: [CANSampleFrame],
        referenceSamples: [CANReferenceSample],
        signalName: String,
        unit: String,
        minimumRSquared: Double = 0.92,
        maxTimeDeltaSeconds: Double = 0.25
    ) -> [DiscoveredCANSignal] {
        let validRefs = referenceSamples
            .filter { $0.timestampSeconds.isFinite && $0.physicalValue.isFinite }
            .sorted { $0.timestampSeconds < $1.timestampSeconds }

        guard validRefs.count >= 6 else { return [] }

        var framesByID: [UInt32: [CANSampleFrame]] = [:]
        for frame in frames where !frame.payload.isEmpty && frame.timestampSeconds.isFinite {
            framesByID[frame.canID, default: []].append(frame)
        }

        var rawCandidates: [DiscoveredCANSignal] = []

        for canID in framesByID.keys.sorted() {
            guard let idFrames = framesByID[canID], idFrames.count >= 6 else { continue }
            let dlc = idFrames.map(\.payload.count).min() ?? 0
            guard dlc >= 1 else { continue }

            // Alignement temporel de chaque trame avec l'échantillon de référence le plus proche
            var alignedFrames: [CANSampleFrame] = []
            var alignedRefValues: [Double] = []
            alignedFrames.reserveCapacity(idFrames.count)
            alignedRefValues.reserveCapacity(idFrames.count)

            for frame in idFrames {
                if let nearest = nearestReference(timestamp: frame.timestampSeconds, in: validRefs, maxDelta: maxTimeDeltaSeconds) {
                    alignedFrames.append(frame)
                    alignedRefValues.append(nearest.physicalValue)
                }
            }

            guard alignedFrames.count >= 6 else { continue }

            // 1. Test des tranches 16-bits (Motorola Big-Endian & Intel Little-Endian)
            var coveredBytesByHighPrecision16Bit: Set<Int> = []
            if dlc >= 2 {
                for startByte in 0..<(dlc - 1) {
                    let beValues = alignedFrames.map { frame -> Double in
                        let hi = UInt16(frame.payload[startByte])
                        let lo = UInt16(frame.payload[startByte + 1])
                        return Double((hi << 8) | lo)
                    }
                    let leValues = alignedFrames.map { frame -> Double in
                        let lo = UInt16(frame.payload[startByte])
                        let hi = UInt16(frame.payload[startByte + 1])
                        return Double((hi << 8) | lo)
                    }

                    let beCandidate = evaluateLinearFit(
                        rawValues: beValues,
                        referenceValues: alignedRefValues,
                        name: signalName,
                        canID: canID,
                        dlc: dlc,
                        startByte: startByte,
                        bitLength: 16,
                        byteOrder: .motorolaBigEndian,
                        unit: unit,
                        minimumRSquared: minimumRSquared
                    )
                    let leCandidate = evaluateLinearFit(
                        rawValues: leValues,
                        referenceValues: alignedRefValues,
                        name: signalName,
                        canID: canID,
                        dlc: dlc,
                        startByte: startByte,
                        bitLength: 16,
                        byteOrder: .intelLittleEndian,
                        unit: unit,
                        minimumRSquared: minimumRSquared
                    )

                    let best16: DiscoveredCANSignal?
                    switch (beCandidate, leCandidate) {
                    case let (be?, le?):
                        best16 = (be.rSquared >= le.rSquared) ? be : le
                    case let (be?, nil):
                        best16 = be
                    case let (nil, le?):
                        best16 = le
                    case (nil, nil):
                        best16 = nil
                    }

                    if let winner = best16 {
                        rawCandidates.append(winner)
                        if winner.rSquared >= 0.985 {
                            coveredBytesByHighPrecision16Bit.insert(startByte)
                            coveredBytesByHighPrecision16Bit.insert(startByte + 1)
                        }
                    }
                }
            }

            // 2. Test des tranches 8-bits (pour les octets non déjà expliqués par un mot 16-bits haute précision)
            for byteIdx in 0..<dlc where !coveredBytesByHighPrecision16Bit.contains(byteIdx) {
                let byteValues = alignedFrames.map { Double($0.payload[byteIdx]) }
                if let candidate8 = evaluateLinearFit(
                    rawValues: byteValues,
                    referenceValues: alignedRefValues,
                    name: signalName,
                    canID: canID,
                    dlc: dlc,
                    startByte: byteIdx,
                    bitLength: 8,
                    byteOrder: .intelLittleEndian,
                    unit: unit,
                    minimumRSquared: minimumRSquared
                ) {
                    rawCandidates.append(candidate8)
                }
            }
        }

        return rawCandidates.sorted {
            if abs($0.rSquared - $1.rSquared) > 1e-6 {
                return $0.rSquared > $1.rSquared
            }
            return $0.canID < $1.canID
        }
    }

    /// Synthétise un fichier standard Vector `.dbc` à partir des signaux analogiques et des bits d'état découverts.
    public static func synthesizeDBC(
        analogSignals: [DiscoveredCANSignal],
        bitCandidates: [CANDifferentialBitCandidate] = [],
        busName: String = "ELECTRICPASSAGE_REVERSED"
    ) -> String {
        var lines: [String] = [
            "VERSION \"\(busName)\"",
            "",
            "NS_ :",
            "\tNS_DESC_",
            "\tCM_",
            "\tBA_DEF_",
            "\tBA_",
            "\tVAL_",
            "",
            "BS_:",
            "",
            "BU_: Vector__XXX",
            ""
        ]

        var allCANIDs = Set<UInt32>()
        var dlcByID: [UInt32: Int] = [:]

        for sig in analogSignals {
            allCANIDs.insert(sig.canID)
            dlcByID[sig.canID] = max(dlcByID[sig.canID] ?? 8, sig.dlc)
        }
        for bit in bitCandidates {
            allCANIDs.insert(bit.canID)
            dlcByID[bit.canID] = max(dlcByID[bit.canID] ?? 8, bit.dlc)
        }

        for canID in allCANIDs.sorted() {
            let dlc = dlcByID[canID] ?? 8
            let hexID = String(format: "%03X", canID)
            lines.append("BO_ \(canID) MSG_\(hexID): \(dlc) Vector__XXX")

            let analogs = analogSignals.filter { $0.canID == canID }
            for sig in analogs {
                let sanitizedName = sanitizeIdentifier(sig.name)
                let scaleStr = formatDecimal(sig.scale)
                let offsetStr = formatDecimal(sig.offset)
                let minStr = formatDecimal(sig.minValue)
                let maxStr = formatDecimal(sig.maxValue)
                lines.append(
                    " SG_ \(sanitizedName) : \(sig.dbcStartBit)|\(sig.bitLength)@\(sig.byteOrder.dbcIndicator)+ (\(scaleStr),\(offsetStr)) [\(minStr)|\(maxStr)] \"\(sig.unit)\" Vector__XXX"
                )
            }

            let bits = bitCandidates.filter { $0.canID == canID }
            for bit in bits {
                let absBit = bit.byteIndex * 8 + bit.bitIndex
                let sigName = String(format: "STATE_%03X_B%d_BIT%d", canID, bit.byteIndex, bit.bitIndex)
                lines.append(
                    " SG_ \(sigName) : \(absBit)|1@1+ (1,0) [0|1] \"flag\" Vector__XXX"
                )
            }

            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Private Helpers

    private static func nearestReference(
        timestamp: Double,
        in sortedRefs: [CANReferenceSample],
        maxDelta: Double
    ) -> CANReferenceSample? {
        var low = 0
        var high = sortedRefs.count - 1
        while low < high {
            let mid = (low + high) / 2
            if sortedRefs[mid].timestampSeconds < timestamp {
                low = mid + 1
            } else {
                high = mid
            }
        }

        var best = sortedRefs[low]
        var bestDist = abs(best.timestampSeconds - timestamp)
        if low > 0 {
            let prev = sortedRefs[low - 1]
            let prevDist = abs(prev.timestampSeconds - timestamp)
            if prevDist < bestDist {
                best = prev
                bestDist = prevDist
            }
        }

        return bestDist <= maxDelta ? best : nil
    }

    private static func evaluateLinearFit(
        rawValues: [Double],
        referenceValues: [Double],
        name: String,
        canID: UInt32,
        dlc: Int,
        startByte: Int,
        bitLength: Int,
        byteOrder: CANByteOrder,
        unit: String,
        minimumRSquared: Double
    ) -> DiscoveredCANSignal? {
        guard rawValues.count == referenceValues.count, rawValues.count >= 6 else { return nil }

        // Écarter les compteurs cycliques et constantes
        let classification = SemanticSignalClassifier.classify(sliceName: name, values: rawValues)
        if classification.category == .counterOrCRC || classification.category == .constantMarker {
            return nil
        }

        guard let r = SignalCorrelator.pearsonCorrelation(x: rawValues, y: referenceValues) else {
            return nil
        }

        let rSquared = r * r
        guard rSquared >= minimumRSquared else { return nil }

        let n = Double(rawValues.count)
        let meanX = rawValues.reduce(0.0, +) / n
        let meanY = referenceValues.reduce(0.0, +) / n

        var covXY = 0.0
        var varX = 0.0
        for i in 0..<rawValues.count {
            let dx = rawValues[i] - meanX
            let dy = referenceValues[i] - meanY
            covXY += dx * dy
            varX += dx * dx
        }

        guard varX > 1e-12 else { return nil }
        let rawScale = covXY / varX
        let rawOffset = meanY - rawScale * meanX
        guard rawScale.isFinite && rawOffset.isFinite && abs(rawScale) > 1e-9 else { return nil }

        // Arrondi propre à 6 décimales pour éviter le bruit IEEE-754 dans les fichiers .dbc
        let cleanScale = (rawScale * 1_000_000.0).rounded() / 1_000_000.0
        let cleanOffset = (rawOffset * 10_000.0).rounded() / 10_000.0

        let minRaw = rawValues.min() ?? 0.0
        let maxRaw = rawValues.max() ?? 0.0
        let p1 = cleanScale * minRaw + cleanOffset
        let p2 = cleanScale * maxRaw + cleanOffset

        return DiscoveredCANSignal(
            name: name,
            canID: canID,
            dlc: dlc,
            startByte: startByte,
            bitLength: bitLength,
            byteOrder: byteOrder,
            scale: cleanScale,
            offset: cleanOffset,
            minValue: min(p1, p2),
            maxValue: max(p1, p2),
            unit: unit,
            rSquared: rSquared
        )
    }

    private static func sanitizeIdentifier(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        let cleaned = text.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let result = String(cleaned)
        return result.isEmpty ? "SIGNAL" : result
    }

    private static func formatDecimal(_ value: Double) -> String {
        if abs(value.rounded() - value) < 1e-6 {
            return String(format: "%.0f", value.rounded())
        }
        var s = String(format: "%.6f", value)
        while s.hasSuffix("0") {
            s.removeLast()
        }
        if s.hasSuffix(".") {
            s.removeLast()
        }
        return s
    }
}
