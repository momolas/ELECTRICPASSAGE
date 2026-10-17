import Foundation

/// Dictionnaire standardisé et typé des Negative Response Codes (NRC)
/// selon les normes ISO 14229-1 (UDS) et ISO 14230 (KWP2000).
public enum UDSNRC: UInt8, Sendable, CaseIterable, Identifiable {
    case generalReject = 0x10
    case serviceNotSupported = 0x11
    case subFunctionNotSupported = 0x12
    case incorrectMessageLengthOrInvalidFormat = 0x13
    case responseTooLong = 0x14
    case busyRepeatRequest = 0x21
    case conditionsNotCorrect = 0x22
    case requestSequenceError = 0x24
    case noResponseFromSubnetComponent = 0x25
    case failurePreventsExecutionOfRequestedAction = 0x26
    case requestOutOfRange = 0x31
    case securityAccessDenied = 0x33
    case invalidKey = 0x35
    case exceededNumberOfAttempts = 0x36
    case requiredTimeDelayNotExpired = 0x37
    case uploadDownloadNotAccepted = 0x70
    case transferDataSuspended = 0x71
    case generalProgrammingFailure = 0x72
    case wrongBlockSequenceCounter = 0x73
    case requestCorrectlyReceivedResponsePending = 0x78
    case subFunctionNotSupportedInActiveSession = 0x7E
    case serviceNotSupportedInActiveSession = 0x7F
    
    // Codes spécifiques aux conditions d'exécution (ISO 14229-1 Annexe A.1)
    case rpmTooHigh = 0x81
    case rpmTooLow = 0x82
    case engineIsRunning = 0x83
    case engineIsNotRunning = 0x84
    case engineRunTimeTooLow = 0x85
    case temperatureTooHigh = 0x86
    case temperatureTooLow = 0x87
    case vehicleSpeedTooHigh = 0x88
    case vehicleSpeedTooLow = 0x89
    case throttlePedalTooHigh = 0x8A
    case throttlePedalTooLow = 0x8B
    case transmissionRangeNotInNeutral = 0x8C
    case transmissionRangeNotInGear = 0x8D
    case brakeSwitchNotClosed = 0x8F
    case shifterLeverNotInPark = 0x90
    case torqueConverterClutchLocked = 0x91
    case voltageTooHigh = 0x92
    case voltageTooLow = 0x93

    public var id: UInt8 { rawValue }

    /// Titre court du code NRC
    public var title: String {
        switch self {
        case .generalReject: return "Rejet Général"
        case .serviceNotSupported: return "Service Non Supporté"
        case .subFunctionNotSupported: return "Sous-Fonction Non Supportée"
        case .incorrectMessageLengthOrInvalidFormat: return "Format ou Longueur Invalide"
        case .responseTooLong: return "Réponse Trop Longue"
        case .busyRepeatRequest: return "Calculateur Occupé"
        case .conditionsNotCorrect: return "Conditions Non Remplies"
        case .requestSequenceError: return "Erreur de Séquence"
        case .noResponseFromSubnetComponent: return "Absence de Réponse Sous-Réseau"
        case .failurePreventsExecutionOfRequestedAction: return "Échec Exécution Action"
        case .requestOutOfRange: return "Paramètre Hors Limites"
        case .securityAccessDenied: return "Accès Sécurisé Refusé"
        case .invalidKey: return "Clé de Sécurité Invalide"
        case .exceededNumberOfAttempts: return "Tentatives Dépassées"
        case .requiredTimeDelayNotExpired: return "Délai d'Attente Non Expiré"
        case .uploadDownloadNotAccepted: return "Transfert Non Accepté"
        case .transferDataSuspended: return "Transfert Données Suspendu"
        case .generalProgrammingFailure: return "Erreur de Programmation"
        case .wrongBlockSequenceCounter: return "Erreur Compteur de Bloc"
        case .requestCorrectlyReceivedResponsePending: return "Réponse en Attente (0x78)"
        case .subFunctionNotSupportedInActiveSession: return "Sous-Fonction Non Supportée en Session"
        case .serviceNotSupportedInActiveSession: return "Service Non Supporté en Session"
        case .rpmTooHigh: return "Régime Moteur Trop Élevé"
        case .rpmTooLow: return "Régime Moteur Trop Bas"
        case .engineIsRunning: return "Moteur Tournant"
        case .engineIsNotRunning: return "Moteur Arrêté"
        case .engineRunTimeTooLow: return "Temps de Fonctionnement Trop Court"
        case .temperatureTooHigh: return "Température Trop Élevée"
        case .temperatureTooLow: return "Température Trop Basse"
        case .vehicleSpeedTooHigh: return "Vitesse Véhicule Trop Élevée"
        case .vehicleSpeedTooLow: return "Vitesse Véhicule Trop Basse"
        case .throttlePedalTooHigh: return "Pédale d'Accélérateur Enfoncée"
        case .throttlePedalTooLow: return "Pédale d'Accélérateur Relâchée"
        case .transmissionRangeNotInNeutral: return "Boîte Pas au Point Mort"
        case .transmissionRangeNotInGear: return "Vitesse Non Engagée"
        case .brakeSwitchNotClosed: return "Pédale de Frein Non Appuyée"
        case .shifterLeverNotInPark: return "Levier de Vitesse Pas en Position P"
        case .torqueConverterClutchLocked: return "Convertisseur Verrouillé"
        case .voltageTooHigh: return "Tension Batterie Trop Élevée"
        case .voltageTooLow: return "Tension Batterie Trop Faible"
        }
    }

    /// Explication détaillée
    public var explanation: String {
        switch self {
        case .generalReject:
            return "Le calculateur a rejeté la requête sans précision additionnelle."
        case .serviceNotSupported:
            return "Le service de diagnostic demandé (SID) n'est pas implémenté sur ce calculateur."
        case .subFunctionNotSupported:
            return "La sous-fonction demandée n'est pas reconnue par le calculateur."
        case .incorrectMessageLengthOrInvalidFormat:
            return "La taille de la trame ou les octets de paramètres ne respectent pas la spécification UDS."
        case .responseTooLong:
            return "La réponse dépasse la capacité du buffer de communication."
        case .busyRepeatRequest:
            return "Le calculateur est temporairement saturé par des tâches prioritaires."
        case .conditionsNotCorrect:
            return "Les prérequis véhicule (contact, régime, tension, vitesse) ne sont pas satisfaits pour exécuter cette opération."
        case .requestSequenceError:
            return "La commande a été envoyée dans un ordre invalide (ex: démarrage de routine sans session de diagnostic active)."
        case .noResponseFromSubnetComponent:
            return "Un module esclave ou un capteur du sous-réseau ne répond pas."
        case .failurePreventsExecutionOfRequestedAction:
            return "Un défaut interne matériel ou logiciel bloque la réalisation de l'action."
        case .requestOutOfRange:
            return "Les identifiants de données (DID) ou les arguments transmis sont en dehors de la plage admissible."
        case .securityAccessDenied:
            return "Niveau de sécurité non déverrouillé. Une procédure SecurityAccess (Service 0x27) est requise."
        case .invalidKey:
            return "La clé calculée à partir du Seed de sécurité a été rejetée par le calculateur."
        case .exceededNumberOfAttempts:
            return "Trop de tentatives erronées de calcul de clé. Le calculateur est temporairement verrouillé."
        case .requiredTimeDelayNotExpired:
            return "La temporisation de sécurité (délai anti-bruteforce) est toujours en cours d'écoulement."
        case .uploadDownloadNotAccepted:
            return "La demande de transfert de mémoire ou de cartographie a été refusée."
        case .transferDataSuspended:
            return "Le transfert de données en mémoire a été interrompu."
        case .generalProgrammingFailure:
            return "Échec de l'écriture en mémoire Flash ou EEPROM."
        case .wrongBlockSequenceCounter:
            return "Désynchronisation dans la numérotation des blocs de données transférés."
        case .requestCorrectlyReceivedResponsePending:
            return "Le calculateur traite la requête mais nécessite un délai supplémentaire (attente normale)."
        case .subFunctionNotSupportedInActiveSession:
            return "La sous-fonction est réservée à une autre session (ex: Session Étendue 0x03 ou Programmation 0x02)."
        case .serviceNotSupportedInActiveSession:
            return "Le service demandé n'est pas autorisé dans la session de diagnostic courante."
        case .rpmTooHigh:
            return "Le régime moteur est supérieur à la limite maximale autorisée pour ce test."
        case .rpmTooLow:
            return "Le régime moteur est insuffisant pour permettre cette opération."
        case .engineIsRunning:
            return "L'opération requiert que le moteur soit coupé (contact seul mis)."
        case .engineIsNotRunning:
            return "L'opération requiert que le moteur soit tournant."
        case .engineRunTimeTooLow:
            return "Le moteur n'a pas tourné assez longtemps pour stabiliser les paramètres."
        case .temperatureTooHigh:
            return "La température du liquide de refroidissement ou de l'huile est trop haute."
        case .temperatureTooLow:
            return "Le moteur ou la boîte n'a pas encore atteint sa température de fonctionnement."
        case .vehicleSpeedTooHigh:
            return "Le véhicule roule trop vite pour autoriser ce test."
        case .vehicleSpeedTooLow:
            return "Le véhicule doit être en mouvement à une vitesse donnée pour cette calibration."
        case .throttlePedalTooHigh:
            return "La pédale d'accélérateur ne doit pas être enfoncée pendant le test."
        case .throttlePedalTooLow:
            return "Enfoncez la pédale d'accélérateur selon les consignes."
        case .transmissionRangeNotInNeutral:
            return "La boîte de vitesses doit impérativement être au point mort (Neutre)."
        case .transmissionRangeNotInGear:
            return "Un rapport doit être engagé pour exécuter ce test."
        case .brakeSwitchNotClosed:
            return "Vous devez maintenir la pédale de frein fermement enfoncée."
        case .shifterLeverNotInPark:
            return "Le sélecteur de boîte automatique doit être positionné sur P (Parking)."
        case .torqueConverterClutchLocked:
            return "Déverrouillez le convertisseur de couple."
        case .voltageTooHigh:
            return "La tension de la batterie dépasse la tolérance maximale (risque de surtension)."
        case .voltageTooLow:
            return "La tension de la batterie est trop basse (< 12.0 V). Branchez un chargeur stabilisé."
        }
    }

    /// Conseil d'action immédiate pour l'utilisateur
    public var actionAdvice: String {
        switch self {
        case .generalReject:
            return "Vérifiez que le contact est bien mis et que l'ECU est alimenté."
        case .serviceNotSupported, .subFunctionNotSupported:
            return "Cette fonction n'est pas supportée par cette version logicielle du calculateur."
        case .incorrectMessageLengthOrInvalidFormat:
            return "Vérifiez les paramètres et la longueur de la commande de diagnostic."
        case .responseTooLong:
            return "Fractionnez la requête ou utilisez des requêtes spécifiques plutôt que groupées."
        case .busyRepeatRequest:
            return "Patientez quelques secondes puis réessayez la commande."
        case .conditionsNotCorrect:
            return "Vérifiez les prérequis : Contact mis, Moteur arrêté, Batterie chargée (>12.5V), Frein à main serré."
        case .requestSequenceError:
            return "Passez d'abord en Session Étendue (0x10 0x03) ou déverrouillez la sécurité avant de relancer."
        case .noResponseFromSubnetComponent:
            return "Vérifiez le câblage du bus local (LIN/CAN secondaire) ou l'alimentation du composant."
        case .failurePreventsExecutionOfRequestedAction:
            return "Consultez les défauts DTC actifs qui bloquent l'actionnement."
        case .requestOutOfRange:
            return "Ajustez la valeur cible pour rester dans les bornes autorisées par le constructeur."
        case .securityAccessDenied:
            return "Exécutez la procédure de déverrouillage de sécurité (SecurityAccess 0x27)."
        case .invalidKey:
            return "Vérifiez l'algorithme de calcul de clé ou le profil véhicule sélectionné."
        case .exceededNumberOfAttempts, .requiredTimeDelayNotExpired:
            return "Coupez le contact, patientez 10 minutes (délai anti-bruteforce) puis remettez le contact."
        case .uploadDownloadNotAccepted, .transferDataSuspended:
            return "Vérifiez les autorisations de session de programmation (0x10 0x02)."
        case .generalProgrammingFailure:
            return "Contrôlez la tension batterie et la qualité de la liaison avant de retenter l'écriture."
        case .wrongBlockSequenceCounter:
            return "Recommencez la séquence de transfert depuis le premier bloc."
        case .requestCorrectlyReceivedResponsePending:
            return "Calculateur en cours de travail, maintien de la liaison actif."
        case .subFunctionNotSupportedInActiveSession, .serviceNotSupportedInActiveSession:
            return "Basculez d'abord en Session Étendue (0x10 0x03) ou Session Diagnostic (0x10 0xC0)."
        case .rpmTooHigh:
            return "Laissez le moteur revenir au ralenti ou coupez le moteur."
        case .rpmTooLow:
            return "Démarrez le moteur et maintenez un régime stable."
        case .engineIsRunning:
            return "Coupez le moteur (clé en position contact)."
        case .engineIsNotRunning:
            return "Démarrez le moteur."
        case .engineRunTimeTooLow:
            return "Laissez tourner le moteur pendant 2 minutes avant de relancer."
        case .temperatureTooHigh:
            return "Laissez refroidir le moteur avant de relancer le test."
        case .temperatureTooLow:
            return "Faites chauffer le moteur jusqu'à température nominale (environ 80°C)."
        case .vehicleSpeedTooHigh:
            return "Immobilisez complètement le véhicule."
        case .vehicleSpeedTooLow:
            return "Effectuez le test en roulant à la vitesse préconisée."
        case .throttlePedalTooHigh:
            return "Ne touchez pas à la pédale d'accélérateur."
        case .throttlePedalTooLow:
            return "Enfoncez la pédale d'accélérateur selon les consignes."
        case .transmissionRangeNotInNeutral:
            return "Mettez le levier de vitesse au point mort (Neutre)."
        case .transmissionRangeNotInGear:
            return "Engagez la première vitesse ou le rapport demandé."
        case .brakeSwitchNotClosed:
            return "Appuyez fermement sur la pédale de frein."
        case .shifterLeverNotInPark:
            return "Positionnez le levier sur P (Park)."
        case .torqueConverterClutchLocked:
            return "Déverrouillez le convertisseur de couple."
        case .voltageTooHigh:
            return "Coupez les chargeurs externes à tension excessive (>14.8V)."
        case .voltageTooLow:
            return "Connectez un chargeur ou un booster de batterie (>12.5V requis)."
        }
    }
}

/// Résultat détaillé d'un rejet de commande UDS / KWP2000
public struct UDSNRCResponse: Sendable, Identifiable, Equatable {
    public var id: String { "\(requestedServiceID)-\(rawHexCode)" }
    public let requestedServiceID: UInt8
    public let nrc: UDSNRC?
    public let rawHexCode: String
    public let rawHexByte: UInt8
    public let title: String
    public let explanation: String
    public let actionAdvice: String
    
    public init(requestedServiceID: UInt8, rawHexByte: UInt8) {
        self.requestedServiceID = requestedServiceID
        self.rawHexByte = rawHexByte
        self.rawHexCode = String(format: "%02X", rawHexByte)
        if let parsedNrc = UDSNRC(rawValue: rawHexByte) {
            self.nrc = parsedNrc
            self.title = parsedNrc.title
            self.explanation = parsedNrc.explanation
            self.actionAdvice = parsedNrc.actionAdvice
        } else {
            self.nrc = nil
            self.title = "Rejet Calculateur Inconnu (0x\(String(format: "%02X", rawHexByte)))"
            self.explanation = "Le calculateur a renvoyé un code de réponse négative non répertorié."
            self.actionAdvice = "Vérifiez la documentation technique spécifique à ce calculateur."
        }
    }
}

extension UDSNRC {
    /// Retourne une description textuelle détaillée et actionnable pour un code octet NRC
    public static func description(for nrcCode: UInt8) -> String {
        if let nrc = UDSNRC(rawValue: nrcCode) {
            return "\(nrc.title) — \(nrc.actionAdvice)"
        }
        return "NRC Inconnu (0x\(String(format: "%02X", nrcCode)))"
    }

    /// Analyse une chaîne de réponse hexadécimale brute et extrait le NRC si présent
    public static func parse(from hexResponse: String) -> UDSNRCResponse? {
        let stripped = HexParsing.stripISOTPFraming(hexResponse)
        guard !stripped.isEmpty else { return nil }

        let hexToParse: String
        if stripped.count >= 9 && stripped.count % 2 == 1 && stripped.hasPrefix("7") {
            hexToParse = String(stripped.dropFirst(3))
        } else {
            hexToParse = stripped
        }

        guard let bytes = HexParsing.bytes(hexToParse), bytes.count >= 3 else {
            return nil
        }

        if bytes[0] == 0x7F {
            return UDSNRCResponse(requestedServiceID: bytes[1], rawHexByte: bytes[2])
        } else if bytes.count >= 4 && bytes[0] == 0x03 && bytes[1] == 0x7F {
            return UDSNRCResponse(requestedServiceID: bytes[2], rawHexByte: bytes[3])
        }

        return nil
    }
}
