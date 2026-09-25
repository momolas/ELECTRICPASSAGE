import Foundation
import VehicleCore
import VehicleTransport

/// Sonde et teste quels PIDs d'un profil sont effectivement supportés et répondent sur le véhicule
public enum ProfileProbe: Sendable {

    /// Teste chaque PID du profil en direct sur l'interface véhicule.
    /// Retourne la liste des identifiants (`pids[].id`) qui reçoivent une réponse positive.
    public static func probe(driver: VehicleInterface, profile: Profile) async throws -> [String] {
        var supported: [String] = []
        var grouped: [String: [PidDef]] = [:]

        for pid in profile.pids {
            grouped[pid.ecu, default: []].append(pid)
        }

        for ecuName in grouped.keys.sorted() {
            try Task.checkCancellation()
            if let ecu = profile.ecus[ecuName] {
                _ = try? await driver.setTarget(txID: ecu.requestHeader, rxID: ecu.responseHeader)
            }
            for pidDef in grouped[ecuName] ?? [] {
                try Task.checkCancellation()
                let request = pidDef.mode + pidDef.pid
                let positiveResponseCode = try positiveResponseCode(mode: pidDef.mode, pid: pidDef.pid)
                do {
                    let response = try await driver.sendDiagnosticRequest(request, timeout: 1.5)
                    let normalized = response
                        .uppercased()
                        .replacing( " ", with: "")
                        .replacing( "\n", with: "")
                        .replacing( "\r", with: "")

                    if normalized.contains("NODATA") || normalized.contains("STOPPED") {
                        continue
                    }
                    if normalized.contains(positiveResponseCode) {
                        supported.append(pidDef.id)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    continue
                }
            }
        }
        return supported
    }

    private static func positiveResponseCode(mode: String, pid: String) throws -> String {
        guard let modeByte = UInt8(mode, radix: 16), modeByte <= 0xBF else { return "" }
        let positive = modeByte + 0x40
        return String(format: "%02X%@", positive, pid)
    }
}
