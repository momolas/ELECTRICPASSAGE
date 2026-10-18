import Foundation
import VehicleCore

/// Métadonnées d'inspection statique d'un fichier binaire de cartographie ECU (.bin).
public nonisolated struct ECUBinaryMetadata: Sendable, Codable, Equatable {
    public let fileName: String
    public let fileSize: Int
    public let crc32: UInt32
    public let crc32Hex: String
    public let checksum16Modular: UInt16
    public let checksum16Hex: String
    public let detectedASCIIIdentifiers: [String]
    public let isValidSize: Bool
    public let isAllBlankOrZero: Bool

    public nonisolated init(
        fileName: String,
        fileSize: Int,
        crc32: UInt32,
        checksum16Modular: UInt16,
        detectedASCIIIdentifiers: [String],
        isValidSize: Bool,
        isAllBlankOrZero: Bool
    ) {
        self.fileName = fileName
        self.fileSize = fileSize
        self.crc32 = crc32
        self.crc32Hex = String(format: "%08X", crc32)
        self.checksum16Modular = checksum16Modular
        self.checksum16Hex = String(format: "%04X", checksum16Modular)
        self.detectedASCIIIdentifiers = detectedASCIIIdentifiers
        self.isValidSize = isValidSize
        self.isAllBlankOrZero = isAllBlankOrZero
    }
}

/// Rapport de comparaison secteur par secteur entre une cartographie d'origine (ORI) et une cartographie modifiée (MOD).
public nonisolated struct ECUBinaryDiffReport: Sendable, Equatable {
    public nonisolated struct ModifiedSector: Sendable, Equatable, Identifiable {
        public var id: Int { index }
        public let index: Int
        public let startOffset: Int
        public let length: Int
        public let changedBytes: Int

        public nonisolated init(index: Int, startOffset: Int, length: Int, changedBytes: Int) {
            self.index = index
            self.startOffset = startOffset
            self.length = length
            self.changedBytes = changedBytes
        }
    }

    public let originalSize: Int
    public let modifiedSize: Int
    public let sizeMatches: Bool
    public let changedBytesCount: Int
    public let changedPercent: Double
    public let totalSectors: Int
    public let modifiedSectors: [ModifiedSector]
    public let hwSwCompatibilityPassed: Bool
    public let compatibilityWarning: String?

    public nonisolated init(
        originalSize: Int,
        modifiedSize: Int,
        sizeMatches: Bool,
        changedBytesCount: Int,
        changedPercent: Double,
        totalSectors: Int,
        modifiedSectors: [ModifiedSector],
        hwSwCompatibilityPassed: Bool,
        compatibilityWarning: String?
    ) {
        self.originalSize = originalSize
        self.modifiedSize = modifiedSize
        self.sizeMatches = sizeMatches
        self.changedBytesCount = changedBytesCount
        self.changedPercent = changedPercent
        self.totalSectors = totalSectors
        self.modifiedSectors = modifiedSectors
        self.hwSwCompatibilityPassed = hwSwCompatibilityPassed
        self.compatibilityWarning = compatibilityWarning
    }
}

/// Rapport de sécurité pré-flashage (Pre-Flight Gate) vérifiant les conditions matérielles et logicielles.
public nonisolated struct ECUFlashPreFlightReport: Sendable, Equatable {
    public let batteryVoltage: Double
    public let isBatteryVoltageSafe: Bool
    public let isTargetCompatible: Bool
    public let hasStockBackupInVault: Bool
    public let binaryValidationPassed: Bool
    public let canProceedWithFlash: Bool
    public let blockingReasons: [String]

    public nonisolated init(
        batteryVoltage: Double,
        isBatteryVoltageSafe: Bool,
        isTargetCompatible: Bool,
        hasStockBackupInVault: Bool,
        binaryValidationPassed: Bool,
        canProceedWithFlash: Bool,
        blockingReasons: [String]
    ) {
        self.batteryVoltage = batteryVoltage
        self.isBatteryVoltageSafe = isBatteryVoltageSafe
        self.isTargetCompatible = isTargetCompatible
        self.hasStockBackupInVault = hasStockBackupInVault
        self.binaryValidationPassed = binaryValidationPassed
        self.canProceedWithFlash = canProceedWithFlash
        self.blockingReasons = blockingReasons
    }
}

/// Moteur d'inspection binaire, de calcul de sommes de contrôle (CRC32 / Checksum 16-bit Bosch) et de comparaison par secteur.
public enum ECUFlashValidator: Sendable {

    /// Calcule le CRC-32 standard (IEEE 802.3, polynôme `0xEDB88320`) sur un tampon binaire.
    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            var c = (crc ^ UInt32(byte)) & 0xFF
            for _ in 0..<8 {
                if (c & 1) != 0 {
                    c = 0xEDB8_8320 ^ (c >> 1)
                } else {
                    c >>= 1
                }
            }
            crc = (crc >> 8) ^ c
        }
        return ~crc
    }

    /// Calcule la somme de contrôle modulaire 16 bits (Big-Endian) utilisée sur les blocs de calibration Bosch/Siemens.
    public static func checksum16(_ data: Data) -> UInt16 {
        var sum: UInt16 = 0
        var idx = data.startIndex
        let end = data.endIndex
        while idx < end {
            let b0 = UInt16(data[idx])
            let nextIdx = data.index(after: idx)
            if nextIdx < end {
                let b1 = UInt16(data[nextIdx])
                sum = sum &+ ((b0 << 8) | b1)
                idx = data.index(after: nextIdx)
            } else {
                sum = sum &+ (b0 << 8)
                idx = nextIdx
            }
        }
        return sum
    }

    /// Extrait les identifiants logiciels/matériels ASCII pertinents (ex. `8200399038`, `HW-8200298457`, `1037...`) présents dans le binaire.
    public static func extractASCIIIdentifiers(from data: Data) -> [String] {
        var results: [String] = []
        var current: [UInt8] = []
        current.reserveCapacity(32)

        func flushCandidate() {
            defer { current.removeAll(keepingCapacity: true) }
            guard current.count >= 6 && current.count <= 40 else { return }
            let str = String(decoding: current, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            let upper = str.uppercased()
            let RelevantPrefixes = ["8200", "1037", "0281", "HW-", "SW-", "CAL-", "S3000", "EDC15", "EDC16", "EDC17", "SID3", "STAGE", "VF1"]
            if RelevantPrefixes.contains(where: { upper.contains($0) }) {
                if !results.contains(str) {
                    results.append(str)
                }
            }
        }

        for byte in data {
            if byte >= 0x20 && byte <= 0x7E {
                current.append(byte)
            } else {
                flushCandidate()
            }
        }
        flushCandidate()
        return results
    }

    /// Inspecte un fichier binaire de cartographie et génère ses métadonnées d'intégrité.
    public static func inspect(data: Data, fileName: String = "map.bin") -> ECUBinaryMetadata {
        let size = data.count
        let standardSizes: Set<Int> = [
            4096, 8192, 16384, 32768, 65536, 131072, 262144, 524288,
            1048576, 1024000, 2097152, 4194304
        ]
        let isValidSize = standardSizes.contains(size) || (size >= 1024 && size % 256 == 0)
        let isAllZero = !data.isEmpty && data.allSatisfy { $0 == 0x00 }
        let isAllFF = !data.isEmpty && data.allSatisfy { $0 == 0xFF }
        let isAllBlankOrZero = data.isEmpty || isAllZero || isAllFF

        return ECUBinaryMetadata(
            fileName: fileName,
            fileSize: size,
            crc32: crc32(data),
            checksum16Modular: checksum16(data),
            detectedASCIIIdentifiers: extractASCIIIdentifiers(from: data),
            isValidSize: isValidSize,
            isAllBlankOrZero: isAllBlankOrZero
        )
    }

    /// Compare une cartographie d'origine (ORI) et une cartographie modifiée (MOD) secteur par secteur.
    public static func compare(
        original: Data,
        modified: Data,
        sectorSize: Int = 4096,
        ecuCalibration: ECUCalibrationInfo? = nil
    ) -> ECUBinaryDiffReport {
        let safeSectorSize = max(256, sectorSize)
        let sizeMatches = original.count == modified.count && !original.isEmpty
        let minLen = min(original.count, modified.count)
        let maxLen = max(original.count, modified.count)

        let origBytes = [UInt8](original)
        let modBytes = [UInt8](modified)

        var totalChanged = 0
        var modifiedSectors: [ECUBinaryDiffReport.ModifiedSector] = []
        let totalSectors = maxLen > 0 ? ((maxLen + safeSectorSize - 1) / safeSectorSize) : 0

        for sectorIdx in 0..<totalSectors {
            let start = sectorIdx * safeSectorSize
            let end = min(start + safeSectorSize, maxLen)
            guard start < end else { continue }
            var sectorDiff = 0
            for i in start..<end {
                if i < minLen {
                    if origBytes[i] != modBytes[i] {
                        sectorDiff += 1
                    }
                } else {
                    sectorDiff += 1
                }
            }
            if sectorDiff > 0 {
                totalChanged += sectorDiff
                modifiedSectors.append(
                    ECUBinaryDiffReport.ModifiedSector(
                        index: sectorIdx,
                        startOffset: start,
                        length: end - start,
                        changedBytes: sectorDiff
                    )
                )
            }
        }

        let changedPercent = maxLen > 0 ? (Double(totalChanged) / Double(maxLen)) * 100.0 : 0.0
        let modAscii = extractASCIIIdentifiers(from: modified).joined(separator: " ").uppercased()
        let origAscii = extractASCIIIdentifiers(from: original).joined(separator: " ").uppercased()

        var hwSwCompatible = sizeMatches
        var warning: String? = nil

        if !sizeMatches {
            warning = "Taille du fichier modifié (\(modified.count) octets) différente de l'origine (\(original.count) octets)."
        } else if let hw = ecuCalibration?.hardwareNumber {
            // Extrait chaque jeton numérique distinct d'au moins 8 chiffres (ex: HW 8200298457 et MPR 8200399038)
            let tokens = hw.split { !$0.isNumber }.map(String.init).filter { $0.count >= 8 }
            if let primaryToken = tokens.first,
               !modAscii.isEmpty && !modAscii.contains(primaryToken) && origAscii.contains(primaryToken) {
                hwSwCompatible = false
                warning = "Incompatibilité matérielle (HW mismatch) : la référence \(primaryToken) est absente du fichier modifié."
            }
        }

        return ECUBinaryDiffReport(
            originalSize: original.count,
            modifiedSize: modified.count,
            sizeMatches: sizeMatches,
            changedBytesCount: totalChanged,
            changedPercent: changedPercent,
            totalSectors: totalSectors,
            modifiedSectors: modifiedSectors,
            hwSwCompatibilityPassed: hwSwCompatible,
            compatibilityWarning: warning
        )
    }

    /// Évalue la barrière de sécurité pré-flashage (Pre-Flight Safety Gate).
    public static func evaluatePreFlight(
        batteryVoltage: Double,
        metadata: ECUBinaryMetadata,
        ecuCalibration: ECUCalibrationInfo?,
        hasStockBackupInVault: Bool
    ) -> ECUFlashPreFlightReport {
        var reasons: [String] = []

        let isVoltageSafe = batteryVoltage.isFinite && batteryVoltage >= 12.5 && batteryVoltage <= 15.8
        if !batteryVoltage.isFinite || batteryVoltage < 12.5 {
            let formatted = batteryVoltage.isFinite ? batteryVoltage.formatted(.number.precision(.fractionLength(2))) : "N/A"
            reasons.append("Tension batterie insuffisante (\(formatted) V < 12.50 V). Branchez un maintien de charge.")
        } else if batteryVoltage > 15.8 {
            reasons.append("Surtension batterie dangereuse (\(batteryVoltage.formatted(.number.precision(.fractionLength(2)))) V > 15.80 V). Vérifiez le chargeur/alternateur.")
        }

        let isBinaryValid = metadata.isValidSize && !metadata.isAllBlankOrZero
        if !metadata.isValidSize {
            reasons.append("Taille du fichier binaire invalide (\(metadata.fileSize) octets).")
        }
        if metadata.isAllBlankOrZero {
            reasons.append("Le fichier binaire est vide ou vierge (0x00 / 0xFF uniquement).")
        }

        var isTargetCompatible = true
        if let cal = ecuCalibration, !metadata.detectedASCIIIdentifiers.isEmpty {
            let joinedMeta = metadata.detectedASCIIIdentifiers.joined(separator: " ").uppercased()
            if let hw = cal.hardwareNumber {
                let tokens = hw.split { !$0.isNumber }.map(String.init).filter { $0.count >= 8 }
                if let primaryToken = tokens.first, !joinedMeta.contains(primaryToken) {
                    isTargetCompatible = false
                    reasons.append("Référence matérielle ECU (\(hw)) absente des signatures du fichier binaire.")
                }
            }
        }

        if !hasStockBackupInVault {
            reasons.append("Aucune sauvegarde d'origine (Backup ORI) présente dans le coffre local.")
        }

        let canProceed = isVoltageSafe && isBinaryValid && isTargetCompatible && hasStockBackupInVault

        return ECUFlashPreFlightReport(
            batteryVoltage: batteryVoltage,
            isBatteryVoltageSafe: isVoltageSafe,
            isTargetCompatible: isTargetCompatible,
            hasStockBackupInVault: hasStockBackupInVault,
            binaryValidationPassed: isBinaryValid,
            canProceedWithFlash: canProceed,
            blockingReasons: reasons
        )
    }

    /// Construit une image binaire de calibration d'origine déterministe et réaliste (64 Ko par défaut)
    /// intégrant les identifiants réels du calculateur (`HW`, `SW`, `CalID`, `CVN`), des tables 16 bits
    /// (couple, injection, pression turbo) et un bloc CRC-32 de fin de zone.
    public static func buildSyntheticStockCalibration(
        calibration: ECUCalibrationInfo?,
        size: Int = 65536
    ) -> Data {
        let finalSize = max(4096, size)
        var bytes = [UInt8](repeating: 0xFF, count: finalSize)

        let hw = calibration?.hardwareNumber ?? "HW-8200298457"
        let sw = calibration?.softwareNumber ?? "SW-00B2-V0430"
        let calID = calibration?.primaryCalID ?? "8200399038_S3000"
        let cvn = calibration?.primaryCVN ?? "A3B8C912"

        func writeASCII(_ text: String, at offset: Int) {
            let utf8 = Array(text.utf8)
            guard offset + utf8.count + 1 < bytes.count else { return }
            for (i, b) in utf8.enumerated() {
                bytes[offset + i] = b
            }
            bytes[offset + utf8.count] = 0x00
        }

        // En-tête d'identification constructeur (Zone 0x0100)
        writeASCII(hw, at: 0x0100)
        writeASCII(sw, at: 0x0140)
        writeASCII(calID, at: 0x0180)
        writeASCII("CVN-\(cvn)", at: 0x01C0)

        // Table 1 : Demande Conducteur / Driver's Wish 16x16 (Zone 0x1000)
        for row in 0..<16 {
            for col in 0..<16 {
                let offset = 0x1000 + (row * 16 + col) * 2
                guard offset + 1 < bytes.count else { break }
                // Couple demandé de 0 à 300.0 Nm (facteur 0.1 -> 0..3000)
                let torqueRaw = UInt16((row * col * 3000) / (15 * 15))
                bytes[offset] = UInt8((torqueRaw >> 8) & 0xFF)
                bytes[offset + 1] = UInt8(torqueRaw & 0xFF)
            }
        }

        // Table 2 : Limiteur de Couple 20x1 (Zone 0x1400)
        for idx in 0..<20 {
            let offset = 0x1400 + idx * 2
            guard offset + 1 < bytes.count else { break }
            let limitRaw = UInt16(1800 + min(idx, 10) * 120) // Jusqu'à 300.0 Nm
            bytes[offset] = UInt8((limitRaw >> 8) & 0xFF)
            bytes[offset + 1] = UInt8(limitRaw & 0xFF)
        }

        // Table 3 : Consigne Pression Turbo 16x16 (Zone 0x2000)
        for row in 0..<16 {
            for col in 0..<16 {
                let offset = 0x2000 + (row * 16 + col) * 2
                guard offset + 1 < bytes.count else { break }
                let boostMbar = UInt16(1000 + (row * col * 1250) / (15 * 15)) // 1000..2250 mbar
                bytes[offset] = UInt8((boostMbar >> 8) & 0xFF)
                bytes[offset + 1] = UInt8(boostMbar & 0xFF)
            }
        }

        // Calcul et inscription du CRC-32 dans les 4 derniers octets
        let payloadWithoutCRC = Data(bytes[0..<(finalSize - 4)])
        let computedCRC = crc32(payloadWithoutCRC)
        bytes[finalSize - 4] = UInt8((computedCRC >> 24) & 0xFF)
        bytes[finalSize - 3] = UInt8((computedCRC >> 16) & 0xFF)
        bytes[finalSize - 2] = UInt8((computedCRC >> 8) & 0xFF)
        bytes[finalSize - 1] = UInt8(computedCRC & 0xFF)

        return Data(bytes)
    }

    /// Génère une variante de calibration « Stage 1 » à partir d'une sauvegarde d'origine (ORI),
    /// en conservant les références matérielles/logicielles (`HW`/`SW`), en optimisant les tables de couple/turbo (+12 %)
    /// et en recalculant le CRC-32 de fin de zone.
    public static func buildSimulatedStage1Calibration(from stockData: Data) -> Data {
        guard stockData.count >= 8192 else { return stockData }
        var bytes = [UInt8](stockData)

        // Mise à jour du marqueur de calibration à 0x0180 tout en préservant HW (0x0100) et SW (0x0140)
        let stageTag = Array("8200399038_STAGE1_OPT".utf8)
        if 0x0180 + stageTag.count + 1 < bytes.count {
            for (i, b) in stageTag.enumerated() {
                bytes[0x0180 + i] = b
            }
            bytes[0x0180 + stageTag.count] = 0x00
        }

        // Augmentation de +12 % sur la table Limiteur de Couple (Zone 0x1400)
        for idx in 0..<20 {
            let offset = 0x1400 + idx * 2
            guard offset + 1 < bytes.count else { break }
            let current = (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
            let tuned = UInt16(min(65535, Int(Double(current) * 1.12)))
            bytes[offset] = UInt8((tuned >> 8) & 0xFF)
            bytes[offset + 1] = UInt8(tuned & 0xFF)
        }

        // Augmentation de +8 % sur la table Pression Turbo (Zone 0x2000)
        for i in 0..<256 {
            let offset = 0x2000 + i * 2
            guard offset + 1 < bytes.count else { break }
            let current = (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
            let tuned = UInt16(min(2600, Int(Double(current) * 1.08)))
            bytes[offset] = UInt8((tuned >> 8) & 0xFF)
            bytes[offset + 1] = UInt8(tuned & 0xFF)
        }

        // Recalcul automatique du CRC-32 final
        let finalSize = bytes.count
        let payloadWithoutCRC = Data(bytes[0..<(finalSize - 4)])
        let newCRC = crc32(payloadWithoutCRC)
        bytes[finalSize - 4] = UInt8((newCRC >> 24) & 0xFF)
        bytes[finalSize - 3] = UInt8((newCRC >> 16) & 0xFF)
        bytes[finalSize - 2] = UInt8((newCRC >> 8) & 0xFF)
        bytes[finalSize - 1] = UInt8(newCRC & 0xFF)

        return Data(bytes)
    }
}
