import Foundation
import Observation

/// Niveau de priorité des opérations accédant à l'interface véhicule / Panda.
public enum BusPriority: Int, Comparable, Sendable {
    case background = 0
    case interactive = 1
    case criticalExclusive = 2

    public static func < (lhs: BusPriority, rhs: BusPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Coordinateur d'accès au bus pour arbitrer et synchroniser les requêtes entre les différents modules
/// (Diagnostic, Sampler temps réel, Fuzzer, Actuateurs, Flashing).
@MainActor
@Observable
public final class BusCoordinator: Sendable {
    public static let shared = BusCoordinator()

    @TaskLocal public static var currentSessionToken: UUID? = nil

    public private(set) var activeSessionName: String? = nil
    public private(set) var activePriority: BusPriority = .background
    public private(set) var isBusy: Bool = false
    private var activeSessionToken: UUID? = nil

    private struct Waiter {
        let id: UUID
        let priority: BusPriority
        let sequence: UInt64
        let name: String
        let token: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var sequenceCounter: UInt64 = 0
    private var waiters: [Waiter] = []
    private var activeDepth: Int = 0

    public init() {}

    /// Tente ou attend l'acquisition du bus pour une opération critique.
    /// Retourne `true` si le verrou a été acquis, ou `false` si la tâche a été annulée avant d'obtenir le verrou.
    @discardableResult
    public func acquire(priority: BusPriority = .interactive, name: String, sessionToken: UUID? = nil) async -> Bool {
        if Task.isCancelled { return false }
        let token = sessionToken ?? BusCoordinator.currentSessionToken ?? UUID()

        if isBusy {
            // Réentrance autorisée UNIQUEMENT si le même token de session dynamique est présent
            if let activeToken = activeSessionToken, activeToken == token {
                activeDepth += 1
                VehicleLogger.shared.trace(.bus, "Reentrant bus lock acquired for '\(name)' (depth: \(activeDepth))")
                return true
            }

            VehicleLogger.shared.debug(.bus, "Bus busy (\(activeSessionName ?? "unknown")), queuing waiter '\(name)' (priority: \(priority.rawValue))")
            let waiterId = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    if Task.isCancelled {
                        continuation.resume(returning: false)
                        return
                    }
                    sequenceCounter += 1
                    let waiter = Waiter(
                        id: waiterId,
                        priority: priority,
                        sequence: sequenceCounter,
                        name: name,
                        token: token,
                        continuation: continuation
                    )
                    waiters.append(waiter)
                    waiters.sort {
                        if $0.priority != $1.priority {
                            return $0.priority > $1.priority
                        }
                        return $0.sequence < $1.sequence
                    }
                }
            } onCancel: {
                Task { @MainActor in
                    self.removeWaiter(id: waiterId)
                }
            }
        } else {
            isBusy = true
            activePriority = priority
            activeSessionName = name
            activeSessionToken = token
            activeDepth = 0
            VehicleLogger.shared.debug(.bus, "Bus lock acquired by '\(name)' (priority: \(priority.rawValue))")
            return true
        }
    }

    private func removeWaiter(id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let removed = waiters.remove(at: index)
            VehicleLogger.shared.notice(.bus, "Cancelled queued bus waiter '\(removed.name)'")
            removed.continuation.resume(returning: false)
        }
    }

    /// Libère l'accès au bus et transmet directement le verrou à la tâche la plus prioritaire en attente (Direct Lock Handoff).
    /// Empêche toute interception/préemption intempestive (barge-in) et élimine les inversions de priorité.
    public func release() {
        guard isBusy else { return }

        if activeDepth > 0 {
            activeDepth -= 1
            return
        }

        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            // Direct lock handoff : isBusy reste true, passage de propriété immédiat
            activePriority = next.priority
            activeSessionName = next.name
            activeSessionToken = next.token
            activeDepth = 0
            VehicleLogger.shared.debug(.bus, "Direct bus lock handoff to '\(next.name)' (priority: \(next.priority.rawValue))")
            next.continuation.resume(returning: true)
        } else {
            let releasedName = activeSessionName ?? "unknown"
            isBusy = false
            activeSessionName = nil
            activeSessionToken = nil
            activePriority = .background
            activeDepth = 0
            VehicleLogger.shared.debug(.bus, "Bus lock released by '\(releasedName)'")
        }
    }

    /// Exécute un bloc asynchrone avec réservation exclusive du bus.
    public func withExclusiveAccess<T: Sendable>(
        priority: BusPriority = .interactive,
        name: String,
        operation: @MainActor () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let token = BusCoordinator.currentSessionToken ?? UUID()

        if isBusy, let activeToken = activeSessionToken, activeToken == token {
            activeDepth += 1
            defer { activeDepth -= 1 }
            return try await operation()
        }

        let acquired = await acquire(priority: priority, name: name, sessionToken: token)
        guard acquired else {
            throw CancellationError()
        }
        defer {
            release()
        }
        try Task.checkCancellation()
        return try await BusCoordinator.$currentSessionToken.withValue(token) {
            try await operation()
        }
    }
}
