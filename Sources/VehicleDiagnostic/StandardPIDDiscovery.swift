import Foundation
import VehicleCore
import VehicleTransport

/// Découverte automatique et séquentielle des PIDs OBD-II standards supportés par le calculateur moteur
public enum StandardPIDDiscovery {

    /// Balaye les masques de bits (`0100`, `0120`, `0140`, `0160`, `0180`, `01A0`, `01C0`)
    /// et énumère tous les identifiants de PID standardisés déclarés supportés par l'ECU.
    public static func discover(driver: VehicleInterface) async throws -> [String] {
        var supported: [Int] = []
        var nextRange = 0x00

        while nextRange <= 0xC0 {
            try Task.checkCancellation()
            let request = String(format: "01%02X", nextRange)
            let response: String
            do {
                response = try await driver.sendDiagnosticRequest(request, timeout: 3.0)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                break
            }

            guard let bitmap = parseBitmap(response: response, requestedPid: nextRange) else {
                break
            }

            for bit in 0..<32 {
                let mask = UInt32(0x80000000) >> bit
                if bitmap & mask != 0 {
                    supported.append(nextRange + 1 + bit)
                }
            }

            // Le 32e bit (0x00000001) indique si la plage suivante (nextRange + 0x20) est supportée (SAE J1979)
            let hasNextRange = (bitmap & 0x00000001) != 0
            if !hasNextRange {
                break
            }

            nextRange += 0x20
        }

        return supported.map { String(format: "%02X", $0) }
    }

    /// Extrait les 4 octets du bitmap de la réponse `41 XX BB BB BB BB`
    private static func parseBitmap(response: String, requestedPid: Int) -> UInt32? {
        guard let bytes = HexParsing.bytes(
            response
                .replacing(" ", with: "")
                .replacing("\n", with: "")
                .replacing("\r", with: "")
        ), bytes.count >= 6 else { return nil }

        let pp = UInt8(requestedPid)
        for i in 0...(bytes.count - 6) {
            if bytes[i] == 0x41 && bytes[i + 1] == pp {
                let b0 = UInt32(bytes[i + 2])
                let b1 = UInt32(bytes[i + 3])
                let b2 = UInt32(bytes[i + 4])
                let b3 = UInt32(bytes[i + 5])
                return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
            }
        }
        return nil
    }
}
