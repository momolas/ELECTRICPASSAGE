import Foundation

public enum PidCategory: String, Codable, Sendable, CaseIterable {
    case engine, hybrid, battery, transmission, emissions, diagnostics, other
    case rpm, speed, temperature
    case climate, airbag, brakes, lighting, body
    case electrical, fuel, air, pressure

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = PidCategory(rawValue: rawValue.lowercased()) ?? .other
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }
}

public struct PidDef: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let ecu: String
    public let mode: String
    public let pid: String
    public let unit: String
    public let formula: String
    public let category: PidCategory
    public let min: Double?
    public let max: Double?

    public init(
        id: String,
        displayName: String,
        ecu: String,
        mode: String,
        pid: String,
        unit: String,
        formula: String,
        category: PidCategory,
        min: Double? = nil,
        max: Double? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.ecu = ecu
        self.mode = mode
        self.pid = pid
        self.unit = unit
        self.formula = formula
        self.category = category
        self.min = min
        self.max = max
    }

    public enum CodingKeys: String, CodingKey, Sendable {
        case id
        case displayName = "display_name"
        case ecu, mode, pid, unit, formula, category, min, max
    }
}

extension PidDef: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? id
        self.ecu = try container.decodeIfPresent(String.self, forKey: .ecu) ?? "engine"
        self.mode = try container.decodeIfPresent(String.self, forKey: .mode) ?? "01"
        self.pid = try container.decodeIfPresent(String.self, forKey: .pid) ?? ""
        self.unit = try container.decodeIfPresent(String.self, forKey: .unit) ?? ""
        self.formula = try container.decodeIfPresent(String.self, forKey: .formula) ?? "A"
        self.category = try container.decodeIfPresent(PidCategory.self, forKey: .category) ?? .other
        self.min = try container.decodeIfPresent(Double.self, forKey: .min)
        self.max = try container.decodeIfPresent(Double.self, forKey: .max)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(ecu, forKey: .ecu)
        try container.encode(mode, forKey: .mode)
        try container.encode(pid, forKey: .pid)
        try container.encode(unit, forKey: .unit)
        try container.encode(formula, forKey: .formula)
        try container.encode(category, forKey: .category)
        try container.encodeIfPresent(min, forKey: .min)
        try container.encodeIfPresent(max, forKey: .max)
    }
}

public struct EcuDef: Identifiable, Hashable, Sendable {
    public var id: String { requestHeader }
    public let requestHeader: String
    public let responseHeader: String

    public init(requestHeader: String, responseHeader: String) {
        self.requestHeader = requestHeader
        self.responseHeader = responseHeader
    }

    public static func == (lhs: EcuDef, rhs: EcuDef) -> Bool {
        lhs.requestHeader == rhs.requestHeader && lhs.responseHeader == rhs.responseHeader
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(requestHeader)
        hasher.combine(responseHeader)
    }

    public enum CodingKeys: String, CodingKey, Sendable {
        case requestHeader = "request_header"
        case responseHeader = "response_header"
    }
}

extension EcuDef: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.requestHeader = try container.decode(String.self, forKey: .requestHeader)
        self.responseHeader = try container.decode(String.self, forKey: .responseHeader)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestHeader, forKey: .requestHeader)
        try container.encode(responseHeader, forKey: .responseHeader)
    }
}

public struct VehicleMatch: Hashable, Sendable {
    public let make: String?
    public let models: [String]?
    public let yearMin: Int?
    public let yearMax: Int?

    public init(make: String? = nil, models: [String]? = nil, yearMin: Int? = nil, yearMax: Int? = nil) {
        self.make = make
        self.models = models
        self.yearMin = yearMin
        self.yearMax = yearMax
    }

    public static func == (lhs: VehicleMatch, rhs: VehicleMatch) -> Bool {
        lhs.make == rhs.make && lhs.models == rhs.models && lhs.yearMin == rhs.yearMin && lhs.yearMax == rhs.yearMax
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(make)
        hasher.combine(models)
        hasher.combine(yearMin)
        hasher.combine(yearMax)
    }

    public enum CodingKeys: String, CodingKey, Sendable {
        case make, models
        case yearMin = "year_min"
        case yearMax = "year_max"
    }
}

extension VehicleMatch: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.make = try container.decodeIfPresent(String.self, forKey: .make)
        self.models = try container.decodeIfPresent([String].self, forKey: .models)
        self.yearMin = try container.decodeIfPresent(Int.self, forKey: .yearMin)
        self.yearMax = try container.decodeIfPresent(Int.self, forKey: .yearMax)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(make, forKey: .make)
        try container.encodeIfPresent(models, forKey: .models)
        try container.encodeIfPresent(yearMin, forKey: .yearMin)
        try container.encodeIfPresent(yearMax, forKey: .yearMax)
    }
}

public struct ValidationEntry: Hashable, Sendable {
    public let vehicle: String
    public let date: String
    public let notes: String?

    public init(vehicle: String, date: String, notes: String? = nil) {
        self.vehicle = vehicle
        self.date = date
        self.notes = notes
    }
}

extension ValidationEntry: Codable {
    public enum CodingKeys: String, CodingKey, Sendable {
        case vehicle, date, notes
    }
}

public struct Profile: Identifiable, Hashable, Sendable {
    public let profileId: String
    public let profileVersion: String
    public let displayName: String
    public let description: String?
    public let vehicleMatch: VehicleMatch?
    public let ecus: [String: EcuDef]
    public let pids: [PidDef]
    public let sources: [String]?
    public let validatedAgainst: [ValidationEntry]?

    public var id: String { profileId }

    public init(
        profileId: String,
        profileVersion: String,
        displayName: String,
        description: String? = nil,
        vehicleMatch: VehicleMatch? = nil,
        ecus: [String: EcuDef] = [:],
        pids: [PidDef] = [],
        sources: [String]? = nil,
        validatedAgainst: [ValidationEntry]? = nil
    ) {
        self.profileId = profileId
        self.profileVersion = profileVersion
        self.displayName = displayName
        self.description = description
        self.vehicleMatch = vehicleMatch
        self.ecus = ecus
        self.pids = pids
        self.sources = sources
        self.validatedAgainst = validatedAgainst
    }

    public static var fallback: Profile {
        Profile(
            profileId: "generic_obd2",
            profileVersion: "1.0",
            displayName: "Generic OBD2"
        )
    }
}

extension Profile: Codable {
    public enum CodingKeys: String, CodingKey, Sendable {
        case profileId = "profile_id"
        case profileVersion = "profile_version"
        case displayName = "display_name"
        case description
        case vehicleMatch = "vehicle_match"
        case ecus, pids, sources
        case validatedAgainst = "validated_against"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.profileId = try container.decode(String.self, forKey: .profileId)
        self.profileVersion = try container.decode(String.self, forKey: .profileVersion)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.vehicleMatch = try container.decodeIfPresent(VehicleMatch.self, forKey: .vehicleMatch)
        self.ecus = try container.decodeIfPresent([String: EcuDef].self, forKey: .ecus) ?? [:]
        self.pids = try container.decodeIfPresent([PidDef].self, forKey: .pids) ?? []
        self.sources = try container.decodeIfPresent([String].self, forKey: .sources)
        self.validatedAgainst = try container.decodeIfPresent([ValidationEntry].self, forKey: .validatedAgainst)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(profileId, forKey: .profileId)
        try container.encode(profileVersion, forKey: .profileVersion)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(vehicleMatch, forKey: .vehicleMatch)
        try container.encode(ecus, forKey: .ecus)
        try container.encode(pids, forKey: .pids)
        try container.encodeIfPresent(sources, forKey: .sources)
        try container.encodeIfPresent(validatedAgainst, forKey: .validatedAgainst)
    }
}
