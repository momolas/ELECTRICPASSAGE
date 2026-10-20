import Foundation
import VehicleCore
import VehicleTransport

/// Résultat d'énumération d'une session diagnostique UDS (`0x10`)
public struct UDSSessionProbeResult: Sendable, Equatable, Codable {
    public let sessionType: UInt8
    public let sessionName: String
    public let isSupported: Bool
    public let negativeResponseCode: UInt8?

    public init(
        sessionType: UInt8,
        sessionName: String,
        isSupported: Bool,
        negativeResponseCode: UInt8?
    ) {
        self.sessionType = sessionType
        self.sessionName = sessionName
        self.isSupported = isSupported
        self.negativeResponseCode = negativeResponseCode
    }
}

/// Résultat de découverte d'un service UDS (inspiré de `Caring Caribou` — Craig Smith, Ch. 4 & Annexe A)
public struct UDSServiceProbeResult: Sendable, Equatable, Codable {
    public enum ServiceAvailability: String, Sendable, Codable {
        case supported = "Supporté (Actif)"
        case securityRequired = "Verrouillé par SecurityAccess (NRC 0x33)"
        case supportedInOtherSession = "Restreint à une autre session (NRC 0x7E/0x7F)"
        case unsupported = "Non supporté (NRC 0x11)"
    }

    public let serviceID: UInt8
    public let serviceName: String
    public let availability: ServiceAvailability
    public let negativeResponseCode: UInt8?

    public init(
        serviceID: UInt8,
        serviceName: String,
        availability: ServiceAvailability,
        negativeResponseCode: UInt8?
    ) {
        self.serviceID = serviceID
        self.serviceName = serviceName
        self.availability = availability
        self.negativeResponseCode = negativeResponseCode
    }
}

/// Résultat d'audit de robustesse d'accès sécurisé `SecurityAccess (0x27)` (Craig Smith, Ch. 6, p. 155)
public struct UDSSecuritySeedAudit: Sendable, Equatable, Codable {
    public enum SeedPosture: String, Sendable, Codable {
        case unlockedByDefault = "Vulnérable : Déverrouillé par défaut (Seed 0x00...00)"
        case staticSeedVulnerability = "Vulnérable : Graine statique/constante (Rejeu possible)"
        case dynamicSeedNominal = "Nominal : Graine dynamique aléatoire (PRNG/TRNG actif)"
        case lockedOutTimeDelay = "Verrouillé : Temporisation anti-bruteforce active (NRC 0x36/0x37)"
        case notSupported = "Non supporté sur ce niveau/session"
    }

    public let level: UInt8
    public let posture: SeedPosture
    public let firstSeed: [UInt8]
    public let secondSeed: [UInt8]?
    public let shannonEntropyBitsPerByte: Double
    public let negativeResponseCode: UInt8?

    public init(
        level: UInt8,
        posture: SeedPosture,
        firstSeed: [UInt8],
        secondSeed: [UInt8]?,
        shannonEntropyBitsPerByte: Double,
        negativeResponseCode: UInt8?
    ) {
        self.level = level
        self.posture = posture
        self.firstSeed = firstSeed
        self.secondSeed = secondSeed
        self.shannonEntropyBitsPerByte = shannonEntropyBitsPerByte
        self.negativeResponseCode = negativeResponseCode
    }
}

/// Rapport d'audit de surface d'attaque UDS d'un calculateur (ECU)
public struct UDSSecurityScanReport: Sendable, Equatable, Codable {
    public let sessions: [UDSSessionProbeResult]
    public let services: [UDSServiceProbeResult]
    public let seedAudits: [UDSSecuritySeedAudit]

    public init(
        sessions: [UDSSessionProbeResult],
        services: [UDSServiceProbeResult],
        seedAudits: [UDSSecuritySeedAudit]
    ) {
        self.sessions = sessions
        self.services = services
        self.seedAudits = seedAudits
    }
}

/// Scanner défensif et non destructif de surface d'attaque UDS (ISO 14229)
/// Permet d'auditer les sessions disponibles, les services exposés et la qualité cryptographique des graines `0x27`.
public actor UDSSecurityScanner {
    private let interface: VehicleInterface

    public init(interface: VehicleInterface) {
        self.interface = interface
    }

    /// Énumère les sessions diagnostiques UDS (`0x10`) prises en charge par l'ECU cible.
    public func probeSessions(
        candidates: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x40, 0x60],
        timeout: TimeInterval = 2.0
    ) async throws -> [UDSSessionProbeResult] {
        var results: [UDSSessionProbeResult] = []
        results.reserveCapacity(candidates.count)

        for sessionID in candidates {
            try Task.checkCancellation()
            let cmd = String(format: "10%02X", sessionID)
            let raw = try await interface.sendDiagnosticRequest(cmd, timeout: timeout)
            let bytes = Self.extractPDUBytes(from: raw)

            let isSupported: Bool
            let nrc: UInt8?
            if bytes.count >= 2 && bytes[0] == 0x50 && bytes[1] == sessionID {
                isSupported = true
                nrc = nil
            } else if bytes.count >= 3 && bytes[0] == 0x7F && bytes[1] == 0x10 {
                // NRC 0x22 (ConditionsNotCorrect) ou 0x33 (SecurityAccessDenied) prouvent que la session existe !
                let code = bytes[2]
                isSupported = (code == 0x22 || code == 0x33)
                nrc = code
            } else {
                isSupported = false
                nrc = nil
            }

            results.append(
                UDSSessionProbeResult(
                    sessionType: sessionID,
                    sessionName: Self.sessionName(for: sessionID),
                    isSupported: isSupported,
                    negativeResponseCode: nrc
                )
            )
        }

        // Retour systématique en DefaultSession (0x10 01) en fin d'audit
        if !Task.isCancelled {
            _ = try? await interface.sendDiagnosticRequest("1001", timeout: timeout)
        }

        return results
    }

    /// Découvre de manière non destructive les services UDS supportés par l'ECU.
    public func probeServices(
        serviceIDs: [UInt8] = [0x10, 0x11, 0x14, 0x19, 0x22, 0x23, 0x27, 0x28, 0x2E, 0x31, 0x34, 0x35, 0x36, 0x37, 0x3E, 0x85],
        timeout: TimeInterval = 2.0
    ) async throws -> [UDSServiceProbeResult] {
        var results: [UDSServiceProbeResult] = []
        results.reserveCapacity(serviceIDs.count)

        for sid in serviceIDs {
            try Task.checkCancellation()
            // Envoie uniquement l'octet SID ou une requête minimale de lecture pour provoquer
            // soit une réponse positive, soit un NRC discriminant (0x13 vs 0x11 vs 0x33 vs 0x7F) sans effet de bord.
            let probeCmd = Self.safeProbePayload(for: sid)
            let raw = try await interface.sendDiagnosticRequest(probeCmd, timeout: timeout)
            let bytes = Self.extractPDUBytes(from: raw)

            let availability: UDSServiceProbeResult.ServiceAvailability
            let nrc: UInt8?

            if let first = bytes.first, first == (sid &+ 0x40) {
                availability = .supported
                nrc = nil
            } else if bytes.count >= 3 && bytes[0] == 0x7F && bytes[1] == sid {
                let code = bytes[2]
                nrc = code
                switch code {
                case 0x11:
                    availability = .unsupported
                case 0x33, 0x35, 0x36, 0x37:
                    availability = .securityRequired
                case 0x7E, 0x7F:
                    availability = .supportedInOtherSession
                default:
                    // 0x12 (subFunctionNotSupported), 0x13 (incorrectLength), 0x22 (conditionsNotCorrect),
                    // 0x24 (requestSequenceError), 0x31 (requestOutOfRange) prouvent que le gestionnaire SID est actif
                    availability = .supported
                }
            } else {
                availability = .unsupported
                nrc = nil
            }

            results.append(
                UDSServiceProbeResult(
                    serviceID: sid,
                    serviceName: Self.serviceName(for: sid),
                    availability: availability,
                    negativeResponseCode: nrc
                )
            )
        }

        return results
    }

    /// Audite la sécurité du service `SecurityAccess (0x27)` sur un niveau impair donné (ex: `0x01`, `0x03`)
    /// sans envoyer de mauvaise clé afin de ne jamais incrémenter le compteur d'échecs de l'ECU.
    public func auditSecurityAccessSeed(level: UInt8 = 0x01, timeout: TimeInterval = 2.0) async throws -> UDSSecuritySeedAudit {
        guard level >= 1 && level < 0xFF && (level % 2 == 1) else {
            return UDSSecuritySeedAudit(
                level: level,
                posture: .notSupported,
                firstSeed: [],
                secondSeed: nil,
                shannonEntropyBitsPerByte: 0.0,
                negativeResponseCode: 0x12
            )
        }

        try Task.checkCancellation()
        let cmd = String(format: "27%02X", level)
        let raw1 = try await interface.sendDiagnosticRequest(cmd, timeout: timeout)
        let bytes1 = Self.extractPDUBytes(from: raw1)

        if bytes1.count >= 3 && bytes1[0] == 0x7F && bytes1[1] == 0x27 {
            let nrc = bytes1[2]
            let posture: UDSSecuritySeedAudit.SeedPosture = (nrc == 0x36 || nrc == 0x37) ? .lockedOutTimeDelay : .notSupported
            return UDSSecuritySeedAudit(
                level: level,
                posture: posture,
                firstSeed: [],
                secondSeed: nil,
                shannonEntropyBitsPerByte: 0.0,
                negativeResponseCode: nrc
            )
        }

        guard bytes1.count >= 3 && bytes1[0] == 0x67 && bytes1[1] == level else {
            return UDSSecuritySeedAudit(
                level: level,
                posture: .notSupported,
                firstSeed: [],
                secondSeed: nil,
                shannonEntropyBitsPerByte: 0.0,
                negativeResponseCode: nil
            )
        }

        let seed1 = Array(bytes1.dropFirst(2))

        // Cas 1 : Toutes les valeurs de la graine sont à 0x00 -> L'ECU est déjà déverrouillé !
        if seed1.allSatisfy({ $0 == 0x00 }) {
            return UDSSecuritySeedAudit(
                level: level,
                posture: .unlockedByDefault,
                firstSeed: seed1,
                secondSeed: nil,
                shannonEntropyBitsPerByte: 0.0,
                negativeResponseCode: nil
            )
        }

        // Seconde requête Seed pour vérifier si l'ECU génère une nouvelle graine aléatoire ou réutilise une graine fixe
        try Task.checkCancellation()
        let raw2 = try await interface.sendDiagnosticRequest(cmd, timeout: timeout)
        let bytes2 = Self.extractPDUBytes(from: raw2)

        let seed2: [UInt8]?
        if bytes2.count >= 3 && bytes2[0] == 0x67 && bytes2[1] == level {
            seed2 = Array(bytes2.dropFirst(2))
        } else {
            seed2 = nil
        }

        let combined = seed1 + (seed2 ?? [])
        let entropy = Self.shannonEntropy(bytes: combined)

        let posture: UDSSecuritySeedAudit.SeedPosture
        if let s2 = seed2, s2 == seed1 {
            posture = .staticSeedVulnerability
        } else {
            posture = .dynamicSeedNominal
        }

        return UDSSecuritySeedAudit(
            level: level,
            posture: posture,
            firstSeed: seed1,
            secondSeed: seed2,
            shannonEntropyBitsPerByte: entropy,
            negativeResponseCode: nil
        )
    }

    /// Exécute un scan de sécurité UDS complet (Sessions + Services + Audit Seed `0x27`).
    public func runFullScan(
        sessionCandidates: [UInt8] = [0x01, 0x02, 0x03],
        securityLevels: [UInt8] = [0x01, 0x03]
    ) async throws -> UDSSecurityScanReport {
        let sessions = try await probeSessions(candidates: sessionCandidates)
        let services = try await probeServices()

        var audits: [UDSSecuritySeedAudit] = []
        audits.reserveCapacity(securityLevels.count)
        for level in securityLevels {
            try Task.checkCancellation()
            let audit = try await auditSecurityAccessSeed(level: level)
            audits.append(audit)
        }

        return UDSSecurityScanReport(
            sessions: sessions,
            services: services,
            seedAudits: audits
        )
    }

    // MARK: - Helpers

    internal static func extractPDUBytes(from raw: String) -> [UInt8] {
        let stripped = HexParsing.stripISOTPFraming(raw)
        var bytes = HexParsing.bytes(stripped) ?? []
        if bytes.count >= 2 && bytes[0] <= 0x07 && Int(bytes[0]) == bytes.count - 1 {
            bytes.removeFirst()
        }
        return bytes
    }

    /// Calcule l'entropie de Shannon d'une séquence d'octets en bits par octet `[0.0, 8.0]`.
    public static func shannonEntropy(bytes: [UInt8]) -> Double {
        guard !bytes.isEmpty else { return 0.0 }
        var counts: [UInt8: Int] = [:]
        for b in bytes {
            counts[b, default: 0] += 1
        }
        let total = Double(bytes.count)
        var entropy = 0.0
        for (_, c) in counts {
            let p = Double(c) / total
            if p > 0 {
                entropy -= p * log2(p)
            }
        }
        return entropy
    }

    private static func safeProbePayload(for sid: UInt8) -> String {
        switch sid {
        case 0x10:
            return "1001" // DefaultSession (inoffensif)
        case 0x22:
            return "22F190" // Read VIN (inoffensif)
        case 0x3E:
            return "3E00" // TesterPresent (inoffensif)
        default:
            // Requête de longueur minimale (1 octet SID) provoquant NRC 0x13 si le service est implémenté
            // sans jamais déclencher d'effacement DTC (0x14), de reset (0x11) ni d'écriture (0x2E/0x34).
            return String(format: "%02X", sid)
        }
    }

    public static func sessionName(for id: UInt8) -> String {
        switch id {
        case 0x01: return "DefaultSession (0x01)"
        case 0x02: return "ProgrammingSession (0x02)"
        case 0x03: return "ExtendedDiagnosticSession (0x03)"
        case 0x04: return "SafetySystemDiagnosticSession (0x04)"
        case 0x40...0x5F: return String(format: "VehicleManufacturerSession (0x%02X)", id)
        case 0x60...0x7E: return String(format: "SystemSupplierSession (0x%02X)", id)
        default: return String(format: "Session (0x%02X)", id)
        }
    }

    public static func serviceName(for sid: UInt8) -> String {
        switch sid {
        case 0x10: return "DiagnosticSessionControl"
        case 0x11: return "ECUReset"
        case 0x14: return "ClearDiagnosticInformation"
        case 0x19: return "ReadDTCInformation"
        case 0x22: return "ReadDataByIdentifier"
        case 0x23: return "ReadMemoryByAddress"
        case 0x27: return "SecurityAccess"
        case 0x28: return "CommunicationControl"
        case 0x2E: return "WriteDataByIdentifier"
        case 0x2F: return "InputOutputControlByIdentifier"
        case 0x31: return "RoutineControl"
        case 0x34: return "RequestDownload"
        case 0x35: return "RequestUpload"
        case 0x36: return "TransferData"
        case 0x37: return "RequestTransferExit"
        case 0x3D: return "WriteMemoryByAddress"
        case 0x3E: return "TesterPresent"
        case 0x85: return "ControlDTCSetting"
        default: return String(format: "Service_0x%02X", sid)
        }
    }
}
