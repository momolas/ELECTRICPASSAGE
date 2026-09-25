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

    public private(set) var activeSessionName: String? = nil
    public private(set) var activePriority: BusPriority = .background
    public private(set) var isBusy: Bool = false

    private struct Waiter {
        let priority: BusPriority
        let sequence: UInt64
        let name: String
        let continuation: CheckedContinuation<Void, Never>
    }

    private var sequenceCounter: UInt64 = 0
    private var waiters: [Waiter] = []
    private var activeDepth: Int = 0

    public init() {}

    /// Tente ou attend l'acquisition du bus pour une opération critique.
    /// Garantit l'exclusion mutuelle stricte : aucune tâche concurrente ne peut s'exécuter sur le bus.
    /// Les tâches en attente sont réveillées par ordre décroissant de priorité (criticalExclusive > interactive > background)
    /// et selon un ordonnancement FIFO strict au sein d'un même échelon de priorité.
    public func acquire(priority: BusPriority = .interactive, name: String) async {
        if isBusy {
            if activeSessionName == name {
                // Réentrance autorisée pour la même session
                activeDepth += 1
                return
            }

            await withCheckedContinuation { continuation in
                sequenceCounter += 1
                let waiter = Waiter(priority: priority, sequence: sequenceCounter, name: name, continuation: continuation)
                waiters.append(waiter)
                waiters.sort {
                    if $0.priority != $1.priority {
                        return $0.priority > $1.priority
                    }
                    return $0.sequence < $1.sequence
                }
            }
            // En réveil par passage direct (direct lock handoff), isBusy reste true
            // et les métadonnées de session ont été assignées immédiatement lors du release().
        } else {
            isBusy = true
            activePriority = priority
            activeSessionName = name
            activeDepth = 0
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
            activeDepth = 0
            next.continuation.resume()
        } else {
            isBusy = false
            activeSessionName = nil
            activePriority = .background
            activeDepth = 0
        }
    }

    /// Exécute un bloc asynchrone avec réservation exclusive du bus.
    public func withExclusiveAccess<T: Sendable>(
        priority: BusPriority = .interactive,
        name: String,
        operation: @MainActor () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        await acquire(priority: priority, name: name)
        defer {
            release()
        }
        try Task.checkCancellation()
        return try await operation()
    }
}
