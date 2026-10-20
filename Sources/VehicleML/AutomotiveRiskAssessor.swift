import Foundation
import VehicleCore

/// Catégories de menaces STRIDE appliquées aux calculateurs et réseaux automobiles (Alissa Knight, Ch. 3 & 7)
public enum STRIDECategory: String, Sendable, Codable, CaseIterable {
    case spoofing = "Spoofing (Usurpation d'identité ECU/Trame)"
    case tampering = "Tampering (Altération de données/Firmware)"
    case repudiation = "Repudiation (Absence de traçabilité d'événement)"
    case informationDisclosure = "Information Disclosure (Fuite de mémoire/VIN/Clés)"
    case denialOfService = "Denial of Service (Saturation Bus CAN / Bus-Off)"
    case elevationOfPrivilege = "Elevation of Privilege (Accès Diagnostic/Seed-Key)"
}

/// Niveau de menace selon le référentiel HEAVENS / ISO/SAE 21434 (Alissa Knight, Ch. 8)
public enum HEAVENSThreatLevel: Int, Sendable, Codable, Comparable {
    case none = 0
    case low = 1
    case medium = 2
    case high = 3
    case critical = 4

    public static func < (lhs: HEAVENSThreatLevel, rhs: HEAVENSThreatLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .none: return "None (0)"
        case .low: return "Low (1)"
        case .medium: return "Medium (2)"
        case .high: return "High (3)"
        case .critical: return "Critical (4)"
        }
    }
}

/// Niveau d'impact selon le référentiel HEAVENS / ISO/SAE 21434 (Alissa Knight, Ch. 8)
public enum HEAVENSImpactLevel: Int, Sendable, Codable, Comparable {
    case negligible = 0
    case low = 1
    case medium = 2
    case high = 3
    case critical = 4

    public static func < (lhs: HEAVENSImpactLevel, rhs: HEAVENSImpactLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .negligible: return "Negligible (0)"
        case .low: return "Low (1)"
        case .medium: return "Medium (2)"
        case .high: return "High (3)"
        case .critical: return "Critical (4)"
        }
    }
}

/// Niveau d'exigence de sécurité résultant de la matrice HEAVENS `(ThreatLevel × ImpactLevel)`
public enum HEAVENSSecurityLevel: String, Sendable, Codable, Comparable {
    case qm = "QM (Quality Management)"
    case low = "CAL 1 / Low"
    case medium = "CAL 2 / Medium"
    case high = "CAL 3 / High"
    case critical = "CAL 4 / Critical"

    private var rank: Int {
        switch self {
        case .qm: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        case .critical: return 4
        }
    }

    public static func < (lhs: HEAVENSSecurityLevel, rhs: HEAVENSSecurityLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// Paramètres de faisabilité d'attaque HEAVENS / EVITA (Alissa Knight, Ch. 8, Tables 8.1–8.5)
/// Les scores vont de 0 (très difficile pour l'attaquant) à 3 (très facile pour l'attaquant).
public struct HEAVENSThreatParameters: Sendable, Equatable, Codable {
    public enum Expertise: Int, Sendable, Codable {
        case multipleExperts = 0
        case expert = 1
        case proficient = 2
        case layman = 3
    }

    public enum KnowledgeOfTarget: Int, Sendable, Codable {
        case critical = 0
        case sensitive = 1
        case restricted = 2
        case publicInformation = 3
    }

    public enum WindowOfOpportunity: Int, Sendable, Codable {
        case small = 0
        case medium = 1
        case large = 2
        case unlimited = 3
    }

    public enum Equipment: Int, Sendable, Codable {
        case multipleBespoke = 0
        case bespoke = 1
        case specialized = 2
        case standard = 3
    }

    public let expertise: Expertise
    public let knowledgeOfTarget: KnowledgeOfTarget
    public let windowOfOpportunity: WindowOfOpportunity
    public let equipment: Equipment

    public init(
        expertise: Expertise,
        knowledgeOfTarget: KnowledgeOfTarget,
        windowOfOpportunity: WindowOfOpportunity,
        equipment: Equipment
    ) {
        self.expertise = expertise
        self.knowledgeOfTarget = knowledgeOfTarget
        self.windowOfOpportunity = windowOfOpportunity
        self.equipment = equipment
    }

    /// Somme pondérée HEAVENS `[0...12]`
    public var rawScore: Int {
        expertise.rawValue + knowledgeOfTarget.rawValue + windowOfOpportunity.rawValue + equipment.rawValue
    }

    /// Niveau de menace HEAVENS dérivé du score `[0...12]`
    public var threatLevel: HEAVENSThreatLevel {
        switch rawScore {
        case ...1: return .none
        case 2...3: return .low
        case 4...6: return .medium
        case 7...9: return .high
        default: return .critical
        }
    }
}

/// Paramètres d'impact HEAVENS (Safety, Financial, Operational, Privacy/Legislation — Alissa Knight, Ch. 8, Tables 8.6–8.10)
public struct HEAVENSImpactParameters: Sendable, Equatable, Codable {
    public enum SafetyImpact: Int, Sendable, Codable {
        case noInjuries = 0
        case lightOrModerateInjuries = 10
        case severeInjuries = 100
        case lifeThreateningOrFatal = 1000
    }

    public enum FinancialImpact: Int, Sendable, Codable {
        case noImpact = 0
        case low = 10
        case medium = 100
        case high = 1000
    }

    public enum OperationalImpact: Int, Sendable, Codable {
        case noImpact = 0
        case low = 1
        case medium = 10
        case high = 100
    }

    public enum PrivacyImpact: Int, Sendable, Codable {
        case noImpact = 0
        case low = 1
        case medium = 10
        case high = 100
    }

    public let safety: SafetyImpact
    public let financial: FinancialImpact
    public let operational: OperationalImpact
    public let privacy: PrivacyImpact

    public init(
        safety: SafetyImpact,
        financial: FinancialImpact,
        operational: OperationalImpact,
        privacy: PrivacyImpact
    ) {
        self.safety = safety
        self.financial = financial
        self.operational = operational
        self.privacy = privacy
    }

    /// Somme pondérée HEAVENS (la sécurité physique et le risque financier dominent d'un facteur 10x)
    public var rawScore: Int {
        safety.rawValue + financial.rawValue + operational.rawValue + privacy.rawValue
    }

    /// Niveau d'impact HEAVENS (Table 8.10)
    public var impactLevel: HEAVENSImpactLevel {
        switch rawScore {
        case ...0: return .negligible
        case 1...19: return .low
        case 20...99: return .medium
        case 100...999: return .high
        default: return .critical
        }
    }
}

/// Cotation DREAD (Craig Smith, *The Car Hacker's Handbook*, Ch. 1, p. 41–45)
public struct DREADParameters: Sendable, Equatable, Codable {
    public let damage: Double
    public let reproducibility: Double
    public let exploitability: Double
    public let affectedUsers: Double
    public let discoverability: Double

    public init(
        damage: Double,
        reproducibility: Double,
        exploitability: Double,
        affectedUsers: Double,
        discoverability: Double
    ) {
        self.damage = Self.clamp(damage)
        self.reproducibility = Self.clamp(reproducibility)
        self.exploitability = Self.clamp(exploitability)
        self.affectedUsers = Self.clamp(affectedUsers)
        self.discoverability = Self.clamp(discoverability)
    }

    private static func clamp(_ v: Double) -> Double {
        guard v.isFinite else { return 0.0 }
        return min(10.0, max(0.0, v))
    }

    /// Moyenne arithmétique DREAD `[0.0, 10.0]`
    public var averageScore: Double {
        (damage + reproducibility + exploitability + affectedUsers + discoverability) / 5.0
    }
}

/// Observations télémétriques et diagnostiques collectées sur un calculateur / réseau du véhicule
public struct ECUSecurityObservations: Sendable, Equatable, Codable {
    public let ecuName: String
    public let isSafetyCriticalDomain: Bool
    public let securityAccessUnlockedByDefault: Bool
    public let staticSeedDetected: Bool
    public let programmingSessionAllowedInMotion: Bool
    public let gatewayIsolationPresent: Bool
    public let busAnomalyScore: Double

    public init(
        ecuName: String,
        isSafetyCriticalDomain: Bool,
        securityAccessUnlockedByDefault: Bool = false,
        staticSeedDetected: Bool = false,
        programmingSessionAllowedInMotion: Bool = false,
        gatewayIsolationPresent: Bool = true,
        busAnomalyScore: Double = 0.0
    ) {
        self.ecuName = ecuName
        self.isSafetyCriticalDomain = isSafetyCriticalDomain
        self.securityAccessUnlockedByDefault = securityAccessUnlockedByDefault
        self.staticSeedDetected = staticSeedDetected
        self.programmingSessionAllowedInMotion = programmingSessionAllowedInMotion
        self.gatewayIsolationPresent = gatewayIsolationPresent
        self.busAnomalyScore = busAnomalyScore.isFinite ? min(1.0, max(0.0, busAnomalyScore)) : 0.0
    }
}

/// Rapport consolidé d'analyse de risque cyber-automobile (HEAVENS + ISO/SAE 21434 + DREAD + STRIDE)
public struct AutomotiveRiskReport: Sendable, Equatable, Codable {
    public let targetName: String
    public let threatLevel: HEAVENSThreatLevel
    public let impactLevel: HEAVENSImpactLevel
    public let securityLevel: HEAVENSSecurityLevel
    public let dreadScore: Double
    public let strideCategories: [STRIDECategory]
    public let findings: [String]
    public let remediations: [String]

    public init(
        targetName: String,
        threatLevel: HEAVENSThreatLevel,
        impactLevel: HEAVENSImpactLevel,
        securityLevel: HEAVENSSecurityLevel,
        dreadScore: Double,
        strideCategories: [STRIDECategory],
        findings: [String],
        remediations: [String]
    ) {
        self.targetName = targetName
        self.threatLevel = threatLevel
        self.impactLevel = impactLevel
        self.securityLevel = securityLevel
        self.dreadScore = dreadScore
        self.strideCategories = strideCategories
        self.findings = findings
        self.remediations = remediations
    }
}

/// Moteur d'évaluation des risques cyber-automobiles selon HEAVENS (Alissa Knight, Ch. 8) et DREAD (Craig Smith, Ch. 1)
public enum AutomotiveRiskAssessor {

    /// Calcule le `HEAVENSSecurityLevel` à partir de la matrice officielle `(ThreatLevel × ImpactLevel)` (Table 8.11)
    public static func evaluateHEAVENSMatrix(
        threat: HEAVENSThreatLevel,
        impact: HEAVENSImpactLevel
    ) -> HEAVENSSecurityLevel {
        switch (threat, impact) {
        case (.none, _), (_, .negligible):
            return .qm
        case (.low, .low), (.low, .medium), (.medium, .low):
            return .low
        case (.low, .high), (.medium, .medium), (.high, .low):
            return .medium
        case (.low, .critical), (.medium, .high), (.high, .medium), (.critical, .low):
            return .high
        case (.medium, .critical), (.high, .high), (.high, .critical), (.critical, .medium), (.critical, .high), (.critical, .critical):
            return .critical
        }
    }

    /// Évalue automatiquement la posture de sécurité d'un calculateur (ECU) à partir des observations terrain
    public static func evaluateECUPosture(_ obs: ECUSecurityObservations) -> AutomotiveRiskReport {
        var strideSet: Set<STRIDECategory> = []
        var findings: [String] = []
        var remediations: [String] = []

        // 1. Analyse des vulnérabilités diagnostiques & réseau
        if obs.securityAccessUnlockedByDefault {
            strideSet.insert(.elevationOfPrivilege)
            strideSet.insert(.tampering)
            findings.append("Service UDS SecurityAccess (0x27) déverrouillé par défaut (graine nulle 0x0000).")
            remediations.append("Verrouiller l'accès sécurisé au démarrage et imposer un défi Seed-Key cryptographique (SecOC / HSM).")
        }

        if obs.staticSeedDetected {
            strideSet.insert(.elevationOfPrivilege)
            strideSet.insert(.informationDisclosure)
            findings.append("Graine SecurityAccess (0x27) statique ou prédictible permettant un rejeu trivial.")
            remediations.append("Utiliser un générateur de nombres aléatoires matériel (TRNG) conforme FIPS/AIS-31 pour la génération des graines UDS.")
        }

        if obs.programmingSessionAllowedInMotion {
            strideSet.insert(.tampering)
            strideSet.insert(.denialOfService)
            findings.append("Session de programmation (0x10 02) autorisée alors que la vitesse véhicule est non nulle.")
            remediations.append("Retourner systématiquement NRC 0x22 (ConditionsNotCorrect) lorsque VehicleSpeed > 0 km/h ou moteur tournant.")
        }

        if !obs.gatewayIsolationPresent {
            strideSet.insert(.spoofing)
            strideSet.insert(.tampering)
            findings.append("Absence d'isolation passerelle (Gateway) entre la prise OBD-II / IVI et le bus CAN motopropulseur/châssis.")
            remediations.append("Déployer un pare-feu de passerelle CAN filtrant les IDs critiques et bloquant l'injection directe depuis l'IVI/OBD.")
        }

        if obs.busAnomalyScore >= 0.35 {
            strideSet.insert(.denialOfService)
            strideSet.insert(.spoofing)
            findings.append(String(format: "Anomalie temporelle ou injection détectée sur le bus CAN (score IDS: %.2f).", obs.busAnomalyScore))
            remediations.append("Activer l'authentification des messages CAN (AUTOSAR SecOC MAC) et isoler le segment en anomalie.")
        }

        // 2. Détermination des paramètres HEAVENS Threat
        let hasTrivialAuthBypass = obs.securityAccessUnlockedByDefault || obs.staticSeedDetected
        let expertise: HEAVENSThreatParameters.Expertise = hasTrivialAuthBypass ? .layman : (!obs.gatewayIsolationPresent ? .proficient : .expert)
        let knowledge: HEAVENSThreatParameters.KnowledgeOfTarget = hasTrivialAuthBypass ? .publicInformation : .restricted
        let window: HEAVENSThreatParameters.WindowOfOpportunity = (!obs.gatewayIsolationPresent || obs.busAnomalyScore >= 0.35) ? .unlimited : .medium
        let equipment: HEAVENSThreatParameters.Equipment = (!obs.gatewayIsolationPresent || hasTrivialAuthBypass) ? .standard : .specialized

        let threatParams = HEAVENSThreatParameters(
            expertise: expertise,
            knowledgeOfTarget: knowledge,
            windowOfOpportunity: window,
            equipment: equipment
        )

        let effectiveThreatLevel: HEAVENSThreatLevel
        if findings.isEmpty {
            effectiveThreatLevel = .low
        } else {
            effectiveThreatLevel = threatParams.threatLevel
        }

        // 3. Détermination des paramètres HEAVENS Impact
        let safetyImpact: HEAVENSImpactParameters.SafetyImpact
        if obs.isSafetyCriticalDomain {
            if obs.programmingSessionAllowedInMotion || obs.securityAccessUnlockedByDefault || obs.busAnomalyScore >= 0.6 {
                safetyImpact = .lifeThreateningOrFatal
            } else if !findings.isEmpty {
                safetyImpact = .severeInjuries
            } else {
                safetyImpact = .lightOrModerateInjuries
            }
        } else {
            safetyImpact = findings.isEmpty ? .noInjuries : .lightOrModerateInjuries
        }

        let financialImpact: HEAVENSImpactParameters.FinancialImpact = findings.isEmpty ? .noImpact : (obs.isSafetyCriticalDomain ? .high : .medium)
        let operationalImpact: HEAVENSImpactParameters.OperationalImpact = findings.isEmpty ? .noImpact : (obs.isSafetyCriticalDomain ? .high : .medium)
        let privacyImpact: HEAVENSImpactParameters.PrivacyImpact = findings.isEmpty ? .noImpact : ((obs.securityAccessUnlockedByDefault || obs.staticSeedDetected) ? .medium : .low)

        let impactParams = HEAVENSImpactParameters(
            safety: safetyImpact,
            financial: financialImpact,
            operational: operationalImpact,
            privacy: privacyImpact
        )

        let securityLevel = evaluateHEAVENSMatrix(threat: effectiveThreatLevel, impact: impactParams.impactLevel)

        // 4. Calcul DREAD (Craig Smith Ch. 1)
        let damage = obs.isSafetyCriticalDomain ? (findings.isEmpty ? 3.0 : 9.5) : (findings.isEmpty ? 1.0 : 5.5)
        let reproducibility = hasTrivialAuthBypass ? 10.0 : (findings.isEmpty ? 1.0 : 7.0)
        let exploitability = hasTrivialAuthBypass ? 9.5 : (!obs.gatewayIsolationPresent ? 8.0 : 3.0)
        let affectedUsers = (obs.securityAccessUnlockedByDefault || obs.staticSeedDetected) ? 9.0 : 4.0
        let discoverability = (!obs.gatewayIsolationPresent || hasTrivialAuthBypass) ? 8.5 : 3.0

        let dread = DREADParameters(
            damage: damage,
            reproducibility: reproducibility,
            exploitability: exploitability,
            affectedUsers: affectedUsers,
            discoverability: discoverability
        )

        let sortedStride = strideSet.sorted { $0.rawValue < $1.rawValue }

        return AutomotiveRiskReport(
            targetName: obs.ecuName,
            threatLevel: effectiveThreatLevel,
            impactLevel: impactParams.impactLevel,
            securityLevel: securityLevel,
            dreadScore: dread.averageScore,
            strideCategories: sortedStride,
            findings: findings,
            remediations: remediations
        )
    }
}
