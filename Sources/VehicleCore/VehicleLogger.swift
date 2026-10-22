import Foundation
import os

/// Niveau de sévérité d'une entrée de journalisation `VehicleLogger`.
public enum VehicleLogLevel: Int, Comparable, Sendable, Codable, CaseIterable {
    case trace = 0
    case debug = 1
    case info = 2
    case notice = 3
    case warning = 4
    case error = 5
    case fault = 6

    public var label: String {
        switch self {
        case .trace: return "TRACE"
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .notice: return "NOTICE"
        case .warning: return "WARN"
        case .error: return "ERROR"
        case .fault: return "FAULT"
        }
    }

    public static func < (lhs: VehicleLogLevel, rhs: VehicleLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Catégorie fonctionnelle du sous-système `com.electricpassage.VehicleKit`.
public enum VehicleLogCategory: String, Sendable, Codable, CaseIterable {
    case bus = "bus"
    case transport = "transport"
    case isotp = "isotp"
    case diagnostic = "diagnostic"
    case analytics = "analytics"
    case ml = "ml"
    case forensic = "forensic"
    case security = "security"
}

/// Direction d'une trame bus ou diagnostique capturée par le Flight Recorder.
public enum VehicleFrameDirection: String, Sendable, Codable, Equatable {
    case tx = "TX"
    case rx = "RX"
}

/// Entrée structurée enregistrée dans le tampon circulaire du Flight Recorder.
public struct VehicleLogEntry: Sendable, Equatable, Codable, Identifiable {
    public let id: UInt64
    public let timestamp: TimeInterval
    public let level: VehicleLogLevel
    public let category: VehicleLogCategory
    public let message: String
    public let direction: VehicleFrameDirection?
    public let canID: String?
    public let bus: UInt8?
    public let payloadHex: String?
    public let latencyMs: Double?
    public let metadata: [String: String]

    public init(
        id: UInt64,
        timestamp: TimeInterval,
        level: VehicleLogLevel,
        category: VehicleLogCategory,
        message: String,
        direction: VehicleFrameDirection? = nil,
        canID: String? = nil,
        bus: UInt8? = nil,
        payloadHex: String? = nil,
        latencyMs: Double? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.direction = direction
        self.canID = canID
        self.bus = bus
        self.payloadHex = payloadHex
        self.latencyMs = latencyMs
        self.metadata = metadata
    }
}

/// Système de journalisation unifié (`os.Logger`) et enregistreur de vol circulaire $O(1)$ (`Flight Recorder`)
/// pour `VehicleKit`. Totalement `Sendable` et synchrone via `OSAllocatedUnfairLock`.
public final class VehicleLogger: Sendable {
    public static let shared = VehicleLogger()

    public static let subsystem = "com.electricpassage.VehicleKit"

    private struct State: Sendable {
        var capacity: Int
        var ringBuffer: [VehicleLogEntry?]
        var writeIndex: Int = 0
        var totalWritten: UInt64 = 0
        var minimumLevel: VehicleLogLevel
        var osLogEnabled: Bool

        init(capacity: Int, minimumLevel: VehicleLogLevel, osLogEnabled: Bool) {
            let safeCapacity = max(16, capacity)
            self.capacity = safeCapacity
            self.ringBuffer = Array(repeating: nil, count: safeCapacity)
            self.minimumLevel = minimumLevel
            self.osLogEnabled = osLogEnabled
        }

        mutating func append(_ entry: VehicleLogEntry) {
            guard capacity > 0 else { return }
            ringBuffer[writeIndex] = entry
            writeIndex = (writeIndex + 1) % capacity
            totalWritten &+= 1
        }

        func orderedEntries() -> [VehicleLogEntry] {
            let count = Int(min(totalWritten, UInt64(capacity)))
            guard count > 0 else { return [] }
            var result: [VehicleLogEntry] = []
            result.reserveCapacity(count)
            let startIndex = totalWritten >= UInt64(capacity) ? writeIndex : 0
            for offset in 0..<count {
                let idx = (startIndex + offset) % capacity
                if let entry = ringBuffer[idx] {
                    result.append(entry)
                }
            }
            return result
        }
    }

    private let stateLock: OSAllocatedUnfairLock<State>
    private let osLoggers: [VehicleLogCategory: Logger]

    public init(
        capacity: Int = 2048,
        minimumLevel: VehicleLogLevel = .debug,
        osLogEnabled: Bool = true
    ) {
        self.stateLock = OSAllocatedUnfairLock(
            initialState: State(
                capacity: capacity,
                minimumLevel: minimumLevel,
                osLogEnabled: osLogEnabled
            )
        )
        var loggers: [VehicleLogCategory: Logger] = [:]
        for category in VehicleLogCategory.allCases {
            loggers[category] = Logger(subsystem: Self.subsystem, category: category.rawValue)
        }
        self.osLoggers = loggers
    }

    /// Reconfigure dynamiquement la capacité du tampon circulaire, le niveau minimal de capture et l'émission `os.Logger`.
    public func configure(
        capacity: Int? = nil,
        minimumLevel: VehicleLogLevel? = nil,
        osLogEnabled: Bool? = nil
    ) {
        stateLock.withLock { state in
            if let minLvl = minimumLevel {
                state.minimumLevel = minLvl
            }
            if let osEnabled = osLogEnabled {
                state.osLogEnabled = osEnabled
            }
            if let newCap = capacity {
                let safeCap = max(16, newCap)
                if safeCap != state.capacity {
                    let existing = state.orderedEntries().suffix(safeCap)
                    state.capacity = safeCap
                    state.ringBuffer = Array(repeating: nil, count: safeCap)
                    state.writeIndex = 0
                    for entry in existing {
                        state.ringBuffer[state.writeIndex] = entry
                        state.writeIndex = (state.writeIndex + 1) % safeCap
                    }
                }
            }
        }
    }

    /// Vide le tampon circulaire en mémoire.
    public func clear() {
        stateLock.withLock { state in
            state.ringBuffer = Array(repeating: nil, count: state.capacity)
            state.writeIndex = 0
            state.totalWritten = 0
        }
    }

    /// Enregistre une entrée structurée dans le Flight Recorder et dans `os.Logger` si son niveau atteint `minimumLevel`.
    public func log(
        _ level: VehicleLogLevel,
        category: VehicleLogCategory,
        _ message: @autoclosure () -> String,
        direction: VehicleFrameDirection? = nil,
        canID: String? = nil,
        bus: UInt8? = nil,
        payloadHex: String? = nil,
        latencyMs: Double? = nil,
        metadata: [String: String] = [:],
        timestamp: TimeInterval? = nil
    ) {
        let shouldLog: (enabled: Bool, osEnabled: Bool) = stateLock.withLock { state in
            (level >= state.minimumLevel, state.osLogEnabled)
        }
        guard shouldLog.enabled else { return }

        let resolvedMessage = message()
        let now = timestamp ?? Date().timeIntervalSince1970

        let entry: VehicleLogEntry = stateLock.withLock { state in
            let nextID = state.totalWritten &+ 1
            let item = VehicleLogEntry(
                id: nextID,
                timestamp: now,
                level: level,
                category: category,
                message: resolvedMessage,
                direction: direction,
                canID: canID,
                bus: bus,
                payloadHex: payloadHex,
                latencyMs: latencyMs,
                metadata: metadata
            )
            state.append(item)
            return item
        }

        if shouldLog.osEnabled, let logger = osLoggers[category] {
            let formatted = Self.formatOSLogLine(for: entry)
            switch level {
            case .trace, .debug:
                logger.debug("\(formatted, privacy: .public)")
            case .info:
                logger.info("\(formatted, privacy: .public)")
            case .notice:
                logger.notice("\(formatted, privacy: .public)")
            case .warning:
                logger.warning("\(formatted, privacy: .public)")
            case .error:
                logger.error("\(formatted, privacy: .public)")
            case .fault:
                logger.fault("\(formatted, privacy: .public)")
            }
        }
    }

    /// Enregistre une trame bus ou diagnostique (`TX` / `RX`) avec identifiant CAN, charge hexadécimale et latence optionnelle.
    public func logFrame(
        direction: VehicleFrameDirection,
        level: VehicleLogLevel = .debug,
        category: VehicleLogCategory = .transport,
        canID: String,
        payloadHex: String,
        bus: UInt8? = nil,
        latencyMs: Double? = nil,
        message: String = "",
        metadata: [String: String] = [:],
        timestamp: TimeInterval? = nil
    ) {
        let summary = message.isEmpty ? "\(direction.rawValue) [\(canID)] \(payloadHex)" : message
        log(
            level,
            category: category,
            summary,
            direction: direction,
            canID: canID,
            bus: bus,
            payloadHex: payloadHex,
            latencyMs: latencyMs,
            metadata: metadata,
            timestamp: timestamp
        )
    }

    public func trace(_ category: VehicleLogCategory, _ message: @autoclosure () -> String, metadata: [String: String] = [:]) {
        log(.trace, category: category, message(), metadata: metadata)
    }

    public func debug(_ category: VehicleLogCategory, _ message: @autoclosure () -> String, metadata: [String: String] = [:]) {
        log(.debug, category: category, message(), metadata: metadata)
    }

    public func info(_ category: VehicleLogCategory, _ message: @autoclosure () -> String, metadata: [String: String] = [:]) {
        log(.info, category: category, message(), metadata: metadata)
    }

    public func notice(_ category: VehicleLogCategory, _ message: @autoclosure () -> String, metadata: [String: String] = [:]) {
        log(.notice, category: category, message(), metadata: metadata)
    }

    public func warning(_ category: VehicleLogCategory, _ message: @autoclosure () -> String, metadata: [String: String] = [:]) {
        log(.warning, category: category, message(), metadata: metadata)
    }

    public func error(_ category: VehicleLogCategory, _ message: @autoclosure () -> String, metadata: [String: String] = [:]) {
        log(.error, category: category, message(), metadata: metadata)
    }

    public func fault(_ category: VehicleLogCategory, _ message: @autoclosure () -> String, metadata: [String: String] = [:]) {
        log(.fault, category: category, message(), metadata: metadata)
    }

    /// Retourne les entrées récentes du Flight Recorder filtrées par niveau minimal et catégorie.
    public func recentEntries(
        limit: Int? = nil,
        minLevel: VehicleLogLevel? = nil,
        category: VehicleLogCategory? = nil
    ) -> [VehicleLogEntry] {
        let all = stateLock.withLock { $0.orderedEntries() }
        let filtered = all.filter { entry in
            if let minLvl = minLevel, entry.level < minLvl { return false }
            if let cat = category, entry.category != cat { return false }
            return true
        }
        if let maxCount = limit, maxCount >= 0, filtered.count > maxCount {
            return Array(filtered.suffix(maxCount))
        }
        return filtered
    }

    /// Exporte toutes les trames capturées au format standard Linux `candump -L` :
    /// `(1729624200.123456) can0 7E0#021003`
    public func exportCANDumpLog(defaultInterface: String = "can0") -> String {
        let entries = stateLock.withLock { $0.orderedEntries() }
        var lines: [String] = []
        lines.reserveCapacity(entries.count)

        for entry in entries {
            guard let rawID = entry.canID, !rawID.isEmpty,
                  let rawPayload = entry.payloadHex, !rawPayload.isEmpty else {
                continue
            }
            let cleanedID = Self.cleanHexIdentifier(rawID)
            let cleanedPayload = Self.cleanHexPayload(rawPayload)
            guard !cleanedID.isEmpty, !cleanedPayload.isEmpty else { continue }

            let iface = entry.bus.map { "can\($0)" } ?? defaultInterface
            let tsString = String(format: "%.6f", entry.timestamp)
            lines.append("(\(tsString)) \(iface) \(cleanedID)#\(cleanedPayload)")
        }

        return lines.joined(separator: "\n")
    }

    /// Exporte les entrées du Flight Recorder au format JSON Lines (`.jsonl`) déterministe (clés triées).
    public func exportJSONLines(
        minLevel: VehicleLogLevel? = nil,
        category: VehicleLogCategory? = nil
    ) -> String {
        let entries = recentEntries(minLevel: minLevel, category: category)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "+INF",
            negativeInfinity: "-INF",
            nan: "NAN"
        )
        var lines: [String] = []
        lines.reserveCapacity(entries.count)
        for entry in entries {
            if let data = try? encoder.encode(entry),
               let line = String(data: data, encoding: .utf8) {
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func formatOSLogLine(for entry: VehicleLogEntry) -> String {
        var parts: [String] = ["[\(entry.level.label)]"]
        if let dir = entry.direction {
            parts.append(dir.rawValue)
        }
        if let canID = entry.canID {
            parts.append("ID:\(canID)")
        }
        parts.append(entry.message)
        if let latency = entry.latencyMs, latency.isFinite {
            parts.append(String(format: "(%.2f ms)", latency))
        }
        return parts.joined(separator: " ")
    }

    private static func cleanHexIdentifier(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if trimmed.hasPrefix("0X") {
            trimmed.removeFirst(2)
        }
        return trimmed.filter { $0.isHexDigit }
    }

    private static func cleanHexPayload(_ raw: String) -> String {
        let hexChars = raw.uppercased().filter { $0.isHexDigit }
        return String(hexChars)
    }
}
