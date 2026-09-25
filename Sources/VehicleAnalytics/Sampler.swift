import Foundation
import VehicleCore
import VehicleTransport

/// Cadence d'échantillonnage par PID pour le Multi-Rate Sampler
public enum SamplingRate: String, Sendable, CaseIterable, Identifiable, Codable {
    case fast = "Rapide (10 Hz)"
    case normal = "Normal (2 Hz)"
    case slow = "Lent (0.5 Hz)"

    public var id: String { rawValue }

    public var shortName: String {
        switch self {
        case .fast: return "10 Hz"
        case .normal: return "2 Hz"
        case .slow: return "0.5 Hz"
        }
    }

    /// Diviseur de cycle basé sur une boucle de base à 10 Hz
    public var tickDivider: Int {
        switch self {
        case .fast: return 1   // Chaque tick (10 Hz)
        case .normal: return 5 // Tous les 5 ticks (~2 Hz)
        case .slow: return 20  // Tous les 20 ticks (~0.5 Hz)
        }
    }

    public var iconName: String {
        switch self {
        case .fast: return "bolt.fill"
        case .normal: return "gauge.with.needle"
        case .slow: return "leaf.fill"
        }
    }
}

/// Tick-driven multi-rate sampler & orchestrateur de requêtes multi-PIDs (SAE J1979).
/// Conçu sous forme d'`actor` Swift 6 natif découplé du MainActor pour maximiser le débit d'acquisition
/// sans bloquer l'interface graphique.
public actor Sampler {

    public struct LiveValue: Sendable, Identifiable {
        public var id: String { pidID }
        public let pidID: String
        public let raw: String
        public let value: Double?
        public let unit: String
        public let displayName: String
        public let category: PidCategory
        public let samplingRate: SamplingRate
        public let timestamp: Date

        public init(
            pidID: String,
            raw: String,
            value: Double?,
            unit: String,
            displayName: String,
            category: PidCategory,
            samplingRate: SamplingRate,
            timestamp: Date
        ) {
            self.pidID = pidID
            self.raw = raw
            self.value = value
            self.unit = unit
            self.displayName = displayName
            self.category = category
            self.samplingRate = samplingRate
            self.timestamp = timestamp
        }
    }

    public struct TickRow: Sendable {
        public let timestampISO: String
        public let elapsedMs: Int
        public let values: [String: String]

        public init(timestampISO: String, elapsedMs: Int, values: [String: String]) {
            self.timestampISO = timestampISO
            self.elapsedMs = elapsedMs
            self.values = values
        }
    }

    private let driver: VehicleInterface
    private let pids: [PidDef]
    private let ecus: [String: EcuDef]
    private let evaluator: FormulaEvaluator
    private let baseLoopRateHz: Double
    private let sessionStartMs: Int
    private let customRates: [String: SamplingRate]

    private var task: Task<Void, Never>?
    private var stopped = false
    public private(set) var tickCount: Int = 0

    private var strikes: [String: Int] = [:]
    public private(set) var disabledPIDs: Set<String> = []

    private let rehabEveryNTicks = 60
    private let interQueryGapNs: UInt64 = 20_000_000

    public var onValues: (@Sendable ([LiveValue]) -> Void)?
    public var onTick: (@Sendable (TickRow) -> Void)?

    private var streamContinuations: [UUID: AsyncStream<[LiveValue]>.Continuation] = [:]

    deinit {
        task?.cancel()
        for continuation in streamContinuations.values {
            continuation.finish()
        }
    }

    public init(
        driver: VehicleInterface,
        pids: [PidDef],
        ecus: [String: EcuDef],
        baseLoopRateHz: Double = 10.0,
        customRates: [String: SamplingRate] = [:],
        sessionStartMs: Int,
        evaluator: FormulaEvaluator? = nil
    ) {
        self.driver = driver
        self.pids = pids
        self.ecus = ecus
        self.baseLoopRateHz = baseLoopRateHz
        self.customRates = customRates
        self.sessionStartMs = sessionStartMs
        self.evaluator = evaluator ?? FormulaEvaluator()
    }

    public func setOnValues(_ handler: (@Sendable ([LiveValue]) -> Void)?) {
        self.onValues = handler
    }

    public func setOnTick(_ handler: (@Sendable (TickRow) -> Void)?) {
        self.onTick = handler
    }

    /// Flux asynchrone d'observation des valeurs en direct.
    public func liveValues() -> AsyncStream<[LiveValue]> {
        let streamID = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: [LiveValue].self,
            bufferingPolicy: .bufferingNewest(50)
        )
        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in
                await self?.removeStream(id: streamID)
            }
        }
        self.streamContinuations[streamID] = continuation
        return stream
    }

    private func removeStream(id: UUID) {
        streamContinuations.removeValue(forKey: id)
    }

    /// Détermine la cadence par défaut optimale selon la nature du signal
    public static func defaultSamplingRate(for pid: PidDef) -> SamplingRate {
        let idLower = pid.id.lowercased()
        let nameLower = pid.displayName.lowercased()

        // PIDs haute dynamique -> Fast (10 Hz)
        if idLower.contains("rpm") || idLower.contains("regime") ||
           idLower.contains("speed") || idLower.contains("vitesse") ||
           idLower.contains("pedal") || idLower.contains("throttle") || idLower.contains("papillon") ||
           idLower.contains("turbo") || idLower.contains("boost") || idLower.contains("torque") ||
           idLower.contains("couple") || idLower.contains("pressure_intake") {
            return .fast
        }

        // PIDs thermiques / statiques -> Slow (0.5 Hz)
        if idLower.contains("temp") || nameLower.contains("température") ||
           idLower.contains("fuel_level") || idLower.contains("carburant") ||
           idLower.contains("battery_voltage") || idLower.contains("ambient") ||
           idLower.contains("oil_level") || idLower.contains("vin") || idLower.contains("distance") {
            return .slow
        }

        return .normal
    }

    public func start() {
        guard task == nil else { return }
        stopped = false
        task = Task { [weak self] in
            await self?.runLoop()
        }
    }

    private func runLoop() async {
        let intervalNs = UInt64(1_000_000_000.0 / baseLoopRateHz)
        while !Task.isCancelled && !stopped {
            do {
                try Task.checkCancellation()
            } catch {
                break
            }
            let tickStart = Date.now
            let row = await runOneTick()
            dispatchTick(row)
            let elapsed = Date.now.timeIntervalSince(tickStart)
            let remaining = max(0, (Double(intervalNs) / 1_000_000_000.0) - elapsed)
            if remaining > 0 {
                do {
                    try await Task.sleep(for: .seconds(remaining))
                } catch {
                    break
                }
            }
        }
    }

    public func stop() {
        stopped = true
        task?.cancel()
        task = nil
        for continuation in streamContinuations.values {
            continuation.finish()
        }
        streamContinuations.removeAll()
    }

    private func dispatchTick(_ row: TickRow) {
        onTick?(row)
    }

    private func broadcastValues(_ values: [LiveValue]) {
        onValues?(values)
        for continuation in streamContinuations.values {
            continuation.yield(values)
        }
    }

    public func runOneTick() async -> TickRow {
        tickCount += 1

        // Réhabilitation périodique des PIDs silencieux
        if tickCount % rehabEveryNTicks == 0, !disabledPIDs.isEmpty {
            disabledPIDs.removeAll()
            strikes.removeAll()
        }

        let startMs = Int(Date.now.timeIntervalSince1970 * 1000)
        let elapsedMs = startMs - sessionStartMs
        let timestampISO = Date.now.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: TimeZone(secondsFromGMT: 0)!))

        var values: [String: String] = [:]
        var liveValuesCollected: [LiveValue] = []

        // Filtrage Multi-Rate : ne retenir que les PIDs arrivés à échéance lors de ce tick
        let eligiblePids = pids.filter { pid in
            guard !disabledPIDs.contains(pid.id) else { return false }
            let rate = customRates[pid.id] ?? Self.defaultSamplingRate(for: pid)
            return (tickCount % rate.tickDivider) == 0
        }

        if eligiblePids.isEmpty {
            return TickRow(timestampISO: timestampISO, elapsedMs: elapsedMs, values: values)
        }

        let groups = groupByEcu(eligiblePids)
        for (ecuName, groupPIDs) in groups {
            if Task.isCancelled || stopped { break }
            if let ecu = ecus[ecuName] {
                _ = try? await driver.setTarget(txID: ecu.requestHeader, rxID: ecu.responseHeader)
            }

            // Séparation des requêtes Mode 01 (éligibles multi-PIDs) et des autres modes
            let mode01Pids = groupPIDs.filter { $0.mode == "01" }
            let otherPids = groupPIDs.filter { $0.mode != "01" }

            // 1. Exécution par lot Multi-PIDs pour Mode 01 (paquets de 4 PIDs)
            if !mode01Pids.isEmpty {
                let chunks = mode01Pids.chunked(into: 4)
                for chunk in chunks {
                    if Task.isCancelled || stopped { break }
                    let queryPids = Array(Set(chunk.map { $0.pid.uppercased() })).sorted()
                    let multiRequest = "01" + queryPids.joined()
                    var handled = false

                    do {
                        let response = try await driver.sendDiagnosticRequest(multiRequest, timeout: 1.0)
                        try? await Task.sleep(for: .nanoseconds(Int(interQueryGapNs)))

                        if let extracted = extractMultiPayloads(response: response, requestedPids: queryPids) {
                            var missingPids: [PidDef] = []
                            for def in chunk {
                                if let payload = extracted[def.pid.uppercased()] {
                                    strikes[def.id] = 0
                                    let evaluated = evaluator.evaluate(formula: def.formula, bytes: payload)
                                    let formatted: String = {
                                        if let v = evaluated {
                                            return Self.format(value: v)
                                        } else {
                                            return HexParsing.hex(payload)
                                        }
                                    }()
                                    values[def.id] = formatted
                                    let rate = customRates[def.id] ?? Self.defaultSamplingRate(for: def)
                                    let live = LiveValue(
                                        pidID: def.id,
                                        raw: HexParsing.hex(payload),
                                        value: evaluated,
                                        unit: def.unit,
                                        displayName: def.displayName,
                                        category: def.category,
                                        samplingRate: rate,
                                        timestamp: Date.now
                                    )
                                    liveValuesCollected.append(live)
                                } else {
                                    missingPids.append(def)
                                }
                            }

                            // Fallback unitaire pour les PIDs omis par l'ECU dans la réponse groupée
                            for def in missingPids {
                                if let live = await querySinglePid(mode: def.mode, pid: def.pid, def: def, values: &values) {
                                    liveValuesCollected.append(live)
                                }
                            }
                            handled = true
                        }
                    } catch is CancellationError {
                        break
                    } catch {
                        // Fallback vers requêtage unitaire si erreur réseau
                    }

                    // Fallback unitaire si la réponse multi-PIDs n'a pas pu être décodée
                    if !handled && !Task.isCancelled && !stopped {
                        for def in chunk {
                            if let live = await querySinglePid(mode: def.mode, pid: def.pid, def: def, values: &values) {
                                liveValuesCollected.append(live)
                            }
                        }
                    }
                }
            }

            // 2. Exécution unitaire pour les autres modes (UDS, KWP2000)
            for (mode, pid, defs) in dedupeByQuery(otherPids) {
                if Task.isCancelled || stopped { break }
                for def in defs {
                    if let live = await querySinglePid(mode: mode, pid: pid, def: def, values: &values) {
                        liveValuesCollected.append(live)
                    }
                }
            }
        }

        if !liveValuesCollected.isEmpty {
            broadcastValues(liveValuesCollected)
        }

        return TickRow(timestampISO: timestampISO, elapsedMs: elapsedMs, values: values)
    }

    private func querySinglePid(
        mode: String,
        pid: String,
        def: PidDef,
        values: inout [String: String]
    ) async -> LiveValue? {
        let request = mode + pid
        let response: String
        do {
            response = try await driver.sendDiagnosticRequest(request, timeout: 1.0)
        } catch is CancellationError {
            return nil
        } catch {
            bumpStrike(def.id)
            try? await Task.sleep(for: .nanoseconds(Int(interQueryGapNs)))
            return nil
        }

        try? await Task.sleep(for: .nanoseconds(Int(interQueryGapNs)))
        let normalized = response.uppercased().replacingOccurrences(of: " ", with: "")
        if normalized.contains("NODATA") || normalized.contains("STOPPED") {
            bumpStrike(def.id)
            return nil
        }
        guard let payload = extractPayload(response: response, mode: mode, pid: pid),
              !payload.isEmpty, !payload.allSatisfy({ $0 == 0xFF }) else {
            bumpStrike(def.id)
            return nil
        }

        strikes[def.id] = 0
        let evaluated = evaluator.evaluate(formula: def.formula, bytes: payload)
        let formatted = evaluated != nil ? Self.format(value: evaluated!) : HexParsing.hex(payload)
        values[def.id] = formatted
        let rate = customRates[def.id] ?? Self.defaultSamplingRate(for: def)

        return LiveValue(
            pidID: def.id,
            raw: HexParsing.hex(payload),
            value: evaluated,
            unit: def.unit,
            displayName: def.displayName,
            category: def.category,
            samplingRate: rate,
            timestamp: Date.now
        )
    }

    private func dedupeByQuery(_ pids: [PidDef]) -> [(mode: String, pid: String, defs: [PidDef])] {
        var keyOrder: [String] = []
        var byKey: [String: (String, String, [PidDef])] = [:]
        for pid in pids {
            let key = "\(pid.mode)\(pid.pid)".uppercased()
            if var existing = byKey[key] {
                existing.2.append(pid)
                byKey[key] = existing
            } else {
                byKey[key] = (pid.mode, pid.pid, [pid])
                keyOrder.append(key)
            }
        }
        return keyOrder.compactMap { byKey[$0] }
    }

    private func groupByEcu(_ pids: [PidDef]) -> [(String, [PidDef])] {
        var grouped: [String: [PidDef]] = [:]
        for pid in pids {
            grouped[pid.ecu, default: []].append(pid)
        }
        return grouped.keys.sorted().map { ($0, grouped[$0]!) }
    }

    private func bumpStrike(_ id: String) {
        let current = (strikes[id] ?? 0) + 1
        strikes[id] = current
        if current >= 3 { disabledPIDs.insert(id) }
    }

    private static func format(value v: Double) -> String {
        if v.rounded() == v && abs(v) < 1e9 {
            return String(Int(v))
        }
        let rounded = (v * 1000).rounded() / 1000
        return String(rounded)
    }

    private func extractPayload(response: String, mode: String, pid: String) -> [UInt8]? {
        guard let modeByte = UInt8(mode, radix: 16) else { return nil }
        let prefix = String(format: "%02X%@", modeByte + 0x40, pid.uppercased())
        let clean = response.uppercased().replacingOccurrences(of: " ", with: "")
        if let prefixRange = clean.range(of: prefix) {
            let after = String(clean[prefixRange.upperBound...])
            return HexParsing.bytes(after)
        }
        return nil
    }

    private func extractMultiPayloads(response: String, requestedPids: [String]) -> [String: [UInt8]]? {
        let clean = response.uppercased().replacingOccurrences(of: " ", with: "")
        guard clean.hasPrefix("41") else { return nil }
        guard let allBytes = HexParsing.bytes(clean), allBytes.count >= 2, allBytes[0] == 0x41 else { return nil }

        var result: [String: [UInt8]] = [:]
        var i = 1
        while i < allBytes.count {
            let currentPidHex = String(format: "%02X", allBytes[i])
            guard requestedPids.contains(currentPidHex) else {
                i += 1
                continue
            }

            // Déterminer la longueur attendue de ce PID (1, 2 ou 4 octets selon SAE J1979)
            let length: Int = {
                switch currentPidHex {
                case "00", "20", "40", "60", "80", "A0", "C0": return 4
                case "01": return 4 // Status since DTCs cleared (MIL / DTC count + monitors)
                case "03": return 2 // Fuel system status
                case "14", "15", "16", "17", "18", "19", "1A", "1B": return 2 // O2 sensors voltage / fuel trim
                case "0C", "10", "1F", "21", "22", "23", "31", "32", "3C", "3D", "3E", "3F", "42", "43", "44", "4D", "4E", "53", "54", "59", "5C", "5D", "5E", "63": return 2
                case "4F", "50", "51", "52": return 4
                default: return 1
                }
            }()

            let payloadStart = i + 1
            let payloadEnd = payloadStart + length
            if payloadEnd <= allBytes.count {
                result[currentPidHex] = Array(allBytes[payloadStart..<payloadEnd])
                i = payloadEnd
            } else {
                break
            }
        }

        return result.isEmpty ? nil : result
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
