import Foundation

/// Module de calcul de grandeurs physiques virtuelles pour groupes motopropulseurs (Powertrain).
/// Dérive la puissance, le couple, la consommation instantanée et le rendement volumétrique (VE%)
/// à partir des flux de télémétrie capteurs normalisés (SAE J1979 Mode 01).
public enum PowertrainCalculations: Sendable {

    /// Constante de conversion DIN : 1 cheval-vapeur métrique (ch) = 735.49875 Watts
    public static let wattsPerMetricHorsepower: Double = 735.49875

    /// Densité standard de l'essence sans plomb à 15°C (g/L)
    public static let standardGasolineDensityGPerL: Double = 745.0

    /// Densité standard du gazole à 15°C (g/L)
    public static let standardDieselDensityGPerL: Double = 832.0

    /// Ratio stœchiométrique air/carburant standard pour moteur essence (14.7:1)
    public static let standardGasolineAFR: Double = 14.7

    /// Ratio stœchiométrique air/carburant standard pour moteur diesel (14.5:1)
    public static let standardDieselAFR: Double = 14.5

    /// Constante spécifique des gaz pour l'air sec : 287.058 J/(kg·K)
    public static let dryAirGasConstant: Double = 287.058

    /// Pouvoir calorifique inférieur standard de l'essence sans plomb (MJ/kg)
    public static let standardGasolineLhvMJPerKg: Double = 44.0

    /// Pouvoir calorifique inférieur standard du gazole (MJ/kg)
    public static let standardDieselLhvMJPerKg: Double = 42.8

    /// Facteur d'émission CO2 standard pour l'essence (g CO2 par gramme de carburant consommé)
    public static let standardGasolineCO2FactorPerGram: Double = 3.18

    /// Facteur d'émission CO2 standard pour le gazole (g CO2 par gramme de carburant consommé)
    public static let standardDieselCO2FactorPerGram: Double = 3.17

    /// Pression atmosphérique standard au niveau de la mer en kPa
    public static let standardAtmosphericPressureKpa: Double = 101.325

    // MARK: - Puissance & Couple

    /// Calcule la puissance mécanique instantanée (en kilowatts et chevaux DIN) à partir du couple et du régime.
    ///
    /// - Parameters:
    ///   - torqueNm: Couple moteur instantané en Newton-mètres (N.m).
    ///   - rpm: Régime moteur en tours par minute (RPM).
    /// - Returns: Tuple contenant la puissance en kW et en chevaux (ch).
    public static func instantaneousPower(torqueNm: Double, rpm: Double) -> (kw: Double, horsepower: Double) {
        guard torqueNm.isFinite, rpm.isFinite, rpm > 0, torqueNm > 0 else { return (0.0, 0.0) }
        let omega = (2.0 * Double.pi * rpm) / 60.0
        let watts = torqueNm * omega
        let kw = watts / 1000.0
        let hp = watts / wattsPerMetricHorsepower
        guard kw.isFinite, hp.isFinite else { return (0.0, 0.0) }
        return (kw, hp)
    }

    /// Calcule le couple moteur instantané (en N.m) à partir de la puissance en kW et du régime.
    public static func instantaneousTorque(powerKw: Double, rpm: Double) -> Double {
        guard powerKw.isFinite, rpm.isFinite, powerKw > 0, rpm > 0 else { return 0.0 }
        let omega = (2.0 * Double.pi * rpm) / 60.0
        let torque = (powerKw * 1000.0) / omega
        return torque.isFinite ? torque : 0.0
    }

    // MARK: - Consommation de Carburant

    /// Calcule le débit de carburant instantané en Litres par heure (L/h) et la consommation en L/100km.
    ///
    /// - Parameters:
    ///   - mafGPerSec: Débit massique d'air d'admission en grammes par seconde (g/s, PID 0x10).
    ///   - speedKmh: Vitesse véhicule en kilomètres par heure (km/h, PID 0x0D).
    ///   - afr: Ratio air/carburant réel ou commandé (ex: 14.7 pour essence).
    ///   - fuelDensityGPerL: Masse volumique du carburant en g/L (par défaut 745.0 g/L).
    /// - Returns: Débit en L/h et consommation en L/100km (nil si vitesse < 3 km/h).
    public static func instantaneousFuelConsumption(
        mafGPerSec: Double,
        speedKmh: Double,
        afr: Double = standardGasolineAFR,
        fuelDensityGPerL: Double = standardGasolineDensityGPerL
    ) -> (litersPerHour: Double, litersPer100Km: Double?) {
        guard mafGPerSec.isFinite, speedKmh.isFinite, afr.isFinite, fuelDensityGPerL.isFinite,
              mafGPerSec > 0, afr > 0, fuelDensityGPerL > 0 else {
            return (0.0, nil)
        }

        let fuelGramsPerSec = mafGPerSec / afr
        let litersPerHour = (fuelGramsPerSec * 3600.0) / fuelDensityGPerL
        guard litersPerHour.isFinite else { return (0.0, nil) }

        if speedKmh >= 3.0 {
            let litersPer100Km = (litersPerHour / speedKmh) * 100.0
            return (litersPerHour, litersPer100Km.isFinite ? litersPer100Km : nil)
        } else {
            return (litersPerHour, nil)
        }
    }

    // MARK: - Rendement Volumétrique (VE %)

    /// Estime le rendement volumétrique (VE %) d'un moteur atmosphérique ou suralimenté à 4 temps.
    ///
    /// Formule thermodynamique basée sur la loi des gaz parfaits :
    /// \(\text{VE} = \frac{\text{MAF}_{\text{réel}}}{\text{MAF}_{\text{théorique}}} \times 100\)
    ///
    /// - Parameters:
    ///   - mafGPerSec: Débit d'air mesuré par le débitmètre en g/s (PID 0x10).
    ///   - rpm: Régime moteur en tr/min (PID 0x0C).
    ///   - mapKpa: Pression absolue dans le collecteur d'admission en kPa (PID 0x0B).
    ///   - iatCelsius: Température de l'air d'admission en °C (PID 0x0F).
    ///   - displacementLiters: Cylindrée totale du moteur en Litres (ex: 1.6, 2.0).
    /// - Returns: Rendement volumétrique en pourcentage (ex: 85.4 pour 85.4%).
    public static func volumetricEfficiency(
        mafGPerSec: Double,
        rpm: Double,
        mapKpa: Double,
        iatCelsius: Double,
        displacementLiters: Double
    ) -> Double? {
        guard mafGPerSec.isFinite, rpm.isFinite, mapKpa.isFinite, iatCelsius.isFinite, displacementLiters.isFinite,
              mafGPerSec > 0, rpm > 0, mapKpa > 0, displacementLiters > 0 else { return nil }

        let tempKelvin = iatCelsius + 273.15
        guard tempKelvin.isFinite, tempKelvin > 0 else { return nil }

        // Pression en Pascals : 1 kPa = 1000 Pa
        let pressurePa = mapKpa * 1000.0

        // Masse volumique de l'air dans l'admission : rho = P / (R * T) [kg/m^3]
        let airDensityKgPerM3 = pressurePa / (dryAirGasConstant * tempKelvin)
        guard airDensityKgPerM3.isFinite else { return nil }

        // Volume aspiré par seconde pour un moteur à 4 temps : (Cylindrée m^3 * (RPM / 120))
        let displacementM3 = displacementLiters * 1e-3
        let aspiratedVolumeM3PerSec = displacementM3 * (rpm / 120.0)

        // Débit massique théorique en g/s (kg * 1000)
        let theoreticalMafGPerSec = (aspiratedVolumeM3PerSec * airDensityKgPerM3) * 1000.0

        guard theoreticalMafGPerSec.isFinite, theoreticalMafGPerSec > 1e-6 else { return nil }
        let ve = (mafGPerSec / theoreticalMafGPerSec) * 100.0
        guard ve.isFinite else { return nil }
        return max(0.0, ve)
    }

    // MARK: - Charge Moteur Estimée

    /// Calcule la charge moteur estimée (%) par rapport au couple de référence usine.
    public static func estimatedEngineLoad(actualTorqueNm: Double, referenceTorqueNm: Double) -> Double? {
        guard actualTorqueNm.isFinite, referenceTorqueNm.isFinite, referenceTorqueNm > 0 else { return nil }
        let load = (actualTorqueNm / referenceTorqueNm) * 100.0
        guard load.isFinite else { return nil }
        return max(0.0, min(100.0, load))
    }

    // MARK: - Consommation Spécifique (BSFC) & Rendement Thermique

    /// Calcule la consommation spécifique effective de carburant (BSFC - Brake Specific Fuel Consumption) en g/(kW·h).
    ///
    /// - Parameters:
    ///   - powerKw: Puissance moteur effective en kilowatts (kW).
    ///   - mafGPerSec: Débit massique d'air en g/s (PID 0x10).
    ///   - afr: Ratio air/carburant (par défaut 14.7:1 pour essence).
    /// - Returns: BSFC en g/(kW·h).
    public static func brakeSpecificFuelConsumption(
        powerKw: Double,
        mafGPerSec: Double,
        afr: Double = standardGasolineAFR
    ) -> Double? {
        guard powerKw.isFinite, mafGPerSec.isFinite, afr.isFinite,
              powerKw > 0.5, mafGPerSec > 0, afr > 0 else { return nil }
        let fuelGramsPerHour = (mafGPerSec / afr) * 3600.0
        let bsfc = fuelGramsPerHour / powerKw
        guard bsfc.isFinite, bsfc > 0 else { return nil }
        return bsfc
    }

    /// Calcule le rendement thermique global (Thermal Efficiency %) du moteur à partir de la puissance et du carburant injecté.
    ///
    /// Formule : \(\eta_{\text{th}} = \frac{3600}{\text{BSFC} \times \text{LHV}} \times 100\)
    ///
    /// - Parameters:
    ///   - powerKw: Puissance moteur en kW.
    ///   - mafGPerSec: Débit d'air en g/s.
    ///   - afr: Ratio air/carburant.
    ///   - lhvMJPerKg: Pouvoir calorifique inférieur du carburant en MJ/kg (par défaut 44.0 MJ/kg).
    /// - Returns: Rendement thermique en % (ex: 34.2 pour 34.2%).
    public static func thermalEfficiency(
        powerKw: Double,
        mafGPerSec: Double,
        afr: Double = standardGasolineAFR,
        lhvMJPerKg: Double = standardGasolineLhvMJPerKg
    ) -> Double? {
        guard let bsfc = brakeSpecificFuelConsumption(powerKw: powerKw, mafGPerSec: mafGPerSec, afr: afr),
              lhvMJPerKg.isFinite, lhvMJPerKg > 0 else { return nil }
        let eta = (3600.0 / (bsfc * lhvMJPerKg)) * 100.0
        guard eta.isFinite, eta > 0 else { return nil }
        return min(100.0, eta)
    }

    // MARK: - Émissions de CO2

    /// Calcule les émissions instantanées de CO2 en grammes par heure (g/h) et grammes par kilomètre (g/km).
    ///
    /// - Parameters:
    ///   - mafGPerSec: Débit massique d'air en g/s.
    ///   - speedKmh: Vitesse véhicule en km/h.
    ///   - afr: Ratio air/carburant.
    ///   - co2FactorPerGramFuel: Grammes de CO2 émis par gramme de carburant (par défaut 3.18 pour l'essence).
    /// - Returns: Tuple contenant le débit horaire en g/h et l'émission kilométrique en g/km.
    public static func instantaneousCO2Emissions(
        mafGPerSec: Double,
        speedKmh: Double,
        afr: Double = standardGasolineAFR,
        co2FactorPerGramFuel: Double = standardGasolineCO2FactorPerGram
    ) -> (gramsPerHour: Double, gramsPerKm: Double?) {
        guard mafGPerSec.isFinite, speedKmh.isFinite, afr.isFinite, co2FactorPerGramFuel.isFinite,
              mafGPerSec > 0, afr > 0, co2FactorPerGramFuel > 0 else {
            return (0.0, nil)
        }
        let fuelGramsPerHour = (mafGPerSec / afr) * 3600.0
        let gramsPerHour = fuelGramsPerHour * co2FactorPerGramFuel
        guard gramsPerHour.isFinite else { return (0.0, nil) }

        if speedKmh >= 3.0 {
            let gramsPerKm = gramsPerHour / speedKmh
            return (gramsPerHour, gramsPerKm.isFinite ? gramsPerKm : nil)
        } else {
            return (gramsPerHour, nil)
        }
    }

    // MARK: - Suralimentation & Pression Turbo (Boost Pressure)

    /// Calcule la pression relative de suralimentation (Boost en bar et psi) et le taux de compression compresseur.
    ///
    /// - Parameters:
    ///   - mapKpa: Pression absolue dans le collecteur d'admission en kPa (PID 0x0B).
    ///   - baroKpa: Pression barométrique ambiante en kPa (PID 0x33 ou 101.325 kPa par défaut).
    /// - Returns: Tuple (boostBar: bar relatif, boostPsi: psi relatif, pressureRatio: ratio absolu).
    public static func turboBoostPressure(
        mapKpa: Double,
        baroKpa: Double = standardAtmosphericPressureKpa
    ) -> (boostBar: Double, boostPsi: Double, pressureRatio: Double) {
        guard mapKpa.isFinite, baroKpa.isFinite, mapKpa >= 0, baroKpa > 0 else {
            return (0.0, 0.0, 1.0)
        }
        let relativeKpa = mapKpa - baroKpa
        let boostBar = relativeKpa / 100.0
        let boostPsi = boostBar * 14.50377
        let ratio = mapKpa / baroKpa
        return (boostBar, boostPsi, ratio.isFinite ? ratio : 1.0)
    }
}
