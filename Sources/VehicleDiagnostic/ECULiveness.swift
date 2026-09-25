import Foundation
import VehicleCore
import VehicleTransport

/// Vérification rapide et légère de la disponibilité et du réveil d'un calculateur (ECU Liveness)
public enum ECULiveness: Sendable {

    /// Retourne true si l'ECU répond positivement à la requête `0100` (`41 00 ...`).
    /// Retourne false en cas de timeout, NO_DATA, STOPPED ou réveil incomplet.
    public static func check(driver: VehicleInterface, timeout: TimeInterval = 4.0) async throws -> Bool {
        let response: String
        do {
            response = try await driver.sendDiagnosticRequest("0100", timeout: timeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return false
        }

        let normalized = response
            .uppercased()
            .replacing( " ", with: "")
            .replacing( "\n", with: "")
            .replacing( "\r", with: "")

        if normalized.contains("NODATA") ||
           normalized.contains("STOPPED") ||
           normalized.contains("UNABLETOCONNECT") ||
           normalized.contains("BUSINIT") ||
           normalized == "?" {
            return false
        }

        return normalized.contains("4100")
    }
}
