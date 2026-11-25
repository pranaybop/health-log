import Foundation
import HealthKit
import LogCore

/// The HealthKit side of the sync: one read request for every type, and the reads health.js made
/// through the Capacitor Health plugin, turned into HealthSample values in the plugin's units.
/// Like the web sync, a read that fails (a type you didn't allow, nothing recorded) is just empty.
final class HealthKitReader: @unchecked Sendable {
    let store = HKHealthStore()

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: Units (the plugin's defaults)

    enum Units {
        static let count = HKUnit.count()
        static let meter = HKUnit.meter()
        static let kcal = HKUnit.kilocalorie()
        static let perMinute = HKUnit.count().unitDivided(by: HKUnit.minute())
        static let kg = HKUnit.gramUnit(with: .kilo)
        static let percent = HKUnit.percent()
        static let ms = HKUnit.secondUnit(with: .milli)
        static let vo2 = HKUnit.literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: HKUnit.minute()))
        static let mgdl = HKUnit.gramUnit(with: .milli).unitDivided(by: HKUnit.literUnit(with: .deci))
        static let celsius = HKUnit.degreeCelsius()
        static let cm = HKUnit.meterUnit(with: .centi)
        static let minute = HKUnit.minute()
        static let liter = HKUnit.liter()
        static let mmHg = HKUnit.millimeterOfMercury()
    }

    // MARK: Authorization

    /// health.js HEALTH_CORE, and with `core` false everything in HEALTH_READ. Blood pressure is
    /// asked for as its two parts (HealthKit doesn't authorize the correlation type itself).
    static func readTypes(core: Bool) -> Set<HKObjectType> {
        var types: Set<HKObjectType> = [HKObjectType.workoutType(), HKCategoryType(.appleStandHour), HKCategoryType(.sleepAnalysis)]
        let coreIds: [HKQuantityTypeIdentifier] = [
            .stepCount, .distanceWalkingRunning, .activeEnergyBurned, .appleExerciseTime, .restingHeartRate,
            .heartRateVariabilitySDNN, .vo2Max, .bodyMass, .bodyFatPercentage,
        ]
        for id in coreIds { types.insert(HKQuantityType(id)) }
        if core { return types }
        let moreIds: [HKQuantityTypeIdentifier] = [
            .heartRate, .respiratoryRate, .oxygenSaturation, .bloodPressureSystolic, .bloodPressureDiastolic,
            .bloodGlucose, .bodyTemperature, .basalBodyTemperature, .appleSleepingWristTemperature, .height,
            .flightsClimbed, .distanceCycling, .basalEnergyBurned, .dietaryWater, .dietaryEnergyConsumed,
        ]
        for id in moreIds { types.insert(HKQuantityType(id)) }
        types.insert(HKCategoryType(.mindfulSession))
        if #available(iOS 18.0, *) {
            types.insert(HKObjectType.stateOfMindType())
        }
        return types
    }

    /// True when iOS would still show the permission sheet (never asked, or a type is new).
    func needsAuthorization() async -> Bool {
        do {
            let status = try await store.statusForAuthorizationRequest(toShare: [], read: Self.readTypes(core: false))
            return status == .shouldRequest
        } catch {
            return true
        }
    }

    /// One permission sheet for every type; if this iOS doesn't take the full set, the core set.
    /// Foreground only: the caller makes sure the app is active.
    func authorizeIfNeeded() async throws {
        guard await needsAuthorization() else { return }
        do {
            try await store.requestAuthorization(toShare: [], read: Self.readTypes(core: false))
        } catch {
            try await store.requestAuthorization(toShare: [], read: Self.readTypes(core: true))
        }
    }

    // MARK: Reads

    struct Read {
        var samples: [HealthSample] = []
        var raw = 0
    }

    /// Daily statistics over Central days (the plugin's queryAggregated with bucket "day").
    func stats(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ options: HKStatisticsOptions,
               _ start: Date, _ end: Date, _ startKey: String, _ endKey: String, on: Bool = true) async -> [String: HealthDayStat] {
        guard on, end > start else { return [:] }
        let type = HKQuantityType(id)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let store = self.store
        return await withCheckedContinuation { (cont: CheckedContinuation<[String: HealthDayStat], Never>) in
            let query = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate, options: options,
                                                    anchorDate: start, intervalComponents: DateComponents(day: 1))
            query.initialResultsHandler = { _, collection, error in
                var out: [String: HealthDayStat] = [:]
                if error == nil, let collection {
                    for s in collection.statistics() where s.startDate >= start && s.startDate < end {
                        var stat = HealthDayStat()
                        if options.contains(.cumulativeSum) { stat.sum = s.sumQuantity()?.doubleValue(for: unit) }
                        if options.contains(.discreteAverage) { stat.average = s.averageQuantity()?.doubleValue(for: unit) }
                        if options.contains(.discreteMin) { stat.min = s.minimumQuantity()?.doubleValue(for: unit) }
                        if options.contains(.discreteMax) { stat.max = s.maximumQuantity()?.doubleValue(for: unit) }
                        guard stat.hasValue else { continue }
                        let key = LogTime.dayKey(s.startDate)
                        if key >= startKey && key <= endKey { out[key] = stat }
                    }
                }
                cont.resume(returning: out)
            }
            store.execute(query)
        }
    }

    /// Samples overlapping [start, end], oldest first, at most `limit`.
    func samples(_ type: HKSampleType, _ start: Date, _ end: Date, limit: Int = HealthAggregate.sampleLimit) async -> [HKSample] {
        guard end > start else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let store = self.store
        return await withCheckedContinuation { (cont: CheckedContinuation<[HKSample], Never>) in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: limit, sortDescriptors: [sort]) { _, results, _ in
                cont.resume(returning: results ?? [])
            }
            store.execute(query)
        }
    }

    static func source(_ s: HKSample) -> String {
        let src = s.sourceRevision.source
        if !src.bundleIdentifier.isEmpty { return src.bundleIdentifier }
        return src.name.isEmpty ? "?" : src.name
    }

    func quantity(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ unitName: String,
                  _ start: Date, _ end: Date, on: Bool = true) async -> Read {
        guard on else { return Read() }
        let raw = await samples(HKQuantityType(id), start, end)
        var out = Read(raw: raw.count)
        for case let q as HKQuantitySample in raw where q.quantity.is(compatibleWith: unit) {
            let v = q.quantity.doubleValue(for: unit)
            guard v.isFinite else { continue }
            out.samples.append(HealthSample(start: q.startDate, end: q.endDate, value: v, unit: unitName, source: Self.source(q)))
        }
        return out
    }

    /// The plugin's names for sleep stages (core is "light").
    static func sleepState(_ value: Int) -> String? {
        switch value {
        case HKCategoryValueSleepAnalysis.inBed.rawValue: return "inBed"
        case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue: return "asleep"
        case HKCategoryValueSleepAnalysis.awake.rawValue: return "awake"
        case HKCategoryValueSleepAnalysis.asleepCore.rawValue: return "light"
        case HKCategoryValueSleepAnalysis.asleepDeep.rawValue: return "deep"
        case HKCategoryValueSleepAnalysis.asleepREM.rawValue: return "rem"
        default: return nil
        }
    }

    func sleep(_ start: Date, _ end: Date) async -> Read {
        let raw = await samples(HKCategoryType(.sleepAnalysis), start, end)
        var out = Read(raw: raw.count)
        for case let c as HKCategorySample in raw {
            let minutes = c.endDate.timeIntervalSince(c.startDate) / 60
            guard minutes.isFinite else { continue }
            out.samples.append(HealthSample(start: c.startDate, end: c.endDate, value: minutes, unit: "minute",
                                            source: Self.source(c), sleepState: Self.sleepState(c.value)))
        }
        return out
    }

    /// Stand hours: 1 for an hour you stood, 0 otherwise (summed per day per source).
    func standHours(_ start: Date, _ end: Date, on: Bool) async -> Read {
        guard on else { return Read() }
        let raw = await samples(HKCategoryType(.appleStandHour), start, end)
        var out = Read(raw: raw.count)
        for case let c as HKCategorySample in raw {
            let stood = c.value == HKCategoryValueAppleStandHour.stood.rawValue
            out.samples.append(HealthSample(start: c.startDate, end: c.endDate, value: stood ? 1 : 0, unit: "count", source: Self.source(c)))
        }
        return out
    }

    /// Mindful sessions as minutes.
    func mindful(_ start: Date, _ end: Date) async -> Read {
        let raw = await samples(HKCategoryType(.mindfulSession), start, end)
        var out = Read(raw: raw.count)
        for case let c as HKCategorySample in raw {
            let minutes = c.endDate.timeIntervalSince(c.startDate) / 60
            guard minutes.isFinite else { continue }
            out.samples.append(HealthSample(start: c.startDate, end: c.endDate, value: minutes, unit: "minute", source: Self.source(c)))
        }
        return out
    }

    /// Blood pressure correlations that have both parts.
    func bloodPressure(_ start: Date, _ end: Date) async -> Read {
        let raw = await samples(HKCorrelationType(.bloodPressure), start, end)
        var out = Read(raw: raw.count)
        let sysType = HKQuantityType(.bloodPressureSystolic)
        let diaType = HKQuantityType(.bloodPressureDiastolic)
        for case let c as HKCorrelation in raw {
            guard let sysSample = c.objects(for: sysType).first as? HKQuantitySample,
                  let diaSample = c.objects(for: diaType).first as? HKQuantitySample else { continue }
            let sys = sysSample.quantity.doubleValue(for: Units.mmHg)
            let dia = diaSample.quantity.doubleValue(for: Units.mmHg)
            guard sys.isFinite, dia.isFinite else { continue }
            out.samples.append(HealthSample(start: c.startDate, end: c.endDate, value: sys, unit: "mmHg", source: Self.source(c),
                                            systolic: sys, diastolic: dia))
        }
        return out
    }

    /// State of Mind valences (-1 to 1), iOS 18 and later.
    func stateOfMind(_ start: Date, _ end: Date) async -> Read {
        if #available(iOS 18.0, *) {
            let raw = await samples(HKObjectType.stateOfMindType(), start, end)
            var out = Read(raw: raw.count)
            for case let m as HKStateOfMind in raw where m.valence.isFinite {
                out.samples.append(HealthSample(start: m.startDate, end: m.endDate, value: m.valence, unit: "valence", source: Self.source(m)))
            }
            return out
        }
        return Read()
    }

    func workouts(_ start: Date, _ end: Date) async -> [HealthWorkoutSample] {
        let raw = await samples(HKObjectType.workoutType(), start, end, limit: HealthAggregate.workoutLimit)
        var out: [HealthWorkoutSample] = []
        for case let w as HKWorkout in raw {
            out.append(HealthWorkoutSample(
                start: w.startDate,
                end: w.endDate,
                type: Self.workoutName(w.workoutActivityType),
                durationSeconds: w.duration.isFinite ? Int(w.duration) : 0,
                distanceMeters: w.totalDistance?.doubleValue(for: Units.meter),
                energyKcal: w.totalEnergyBurned?.doubleValue(for: Units.kcal),
                indoor: Self.metadataText(w.metadata?[HKMetadataKeyIndoorWorkout])
            ))
        }
        return out
    }

    static func metadataText(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    // MARK: A window

    /// health.js collectWindow: read the days [startKey, endKey] and build their rows.
    ///   includeDays  read the per-day totals for log.daily_health
    ///   weightStart  read weigh-ins and body fat from this time (a scale may only sync weekly)
    ///   skipWeights  leave weigh-ins and body fat out
    func collect(startKey: String, endKey: String, includeDays: Bool, weightStart: Date?, skipWeights: Bool,
                 now: Date = Date()) async -> HealthBatch {
        let start = LogTime.startOfDay(startKey)
        let end = min(now, LogTime.startOfDay(LogTime.shift(endKey, 1)))
        // Sleep is read a little past both edges so a night is never cut in half.
        let sleepFrom = start.addingTimeInterval(-18 * 3600)
        let sleepTo = min(now, end.addingTimeInterval(14 * 3600))
        let weightFrom = weightStart ?? start
        let d = includeDays
        let w = !skipWeights
        let a = startKey
        let b = endKey

        async let steps = self.stats(.stepCount, Units.count, [.cumulativeSum], start, end, a, b, on: d)
        async let distance = self.stats(.distanceWalkingRunning, Units.meter, [.cumulativeSum], start, end, a, b, on: d)
        async let active = self.stats(.activeEnergyBurned, Units.kcal, [.cumulativeSum], start, end, a, b)
        async let restingHr = self.stats(.restingHeartRate, Units.perMinute, [.discreteAverage], start, end, a, b, on: d)
        async let heartRate = self.stats(.heartRate, Units.perMinute, [.discreteAverage, .discreteMin, .discreteMax], start, end, a, b)
        async let water = self.stats(.dietaryWater, Units.liter, [.cumulativeSum], start, end, a, b)
        async let dietary = self.stats(.dietaryEnergyConsumed, Units.kcal, [.cumulativeSum], start, end, a, b)
        async let exercise = self.quantity(.appleExerciseTime, Units.minute, "minute", start, end, on: d)
        async let stand = self.standHours(start, end, on: d)
        async let vo2 = self.quantity(.vo2Max, Units.vo2, "mL/min/kg", start, end, on: d)
        async let hrv = self.quantity(.heartRateVariabilitySDNN, Units.ms, "millisecond", start, end, on: d)
        async let sleepRead = self.sleep(sleepFrom, sleepTo)
        async let basal = self.quantity(.basalEnergyBurned, Units.kcal, "kilocalorie", start, end)
        async let flights = self.quantity(.flightsClimbed, Units.count, "count", start, end)
        async let cycling = self.quantity(.distanceCycling, Units.meter, "meter", start, end)
        async let glucose = self.quantity(.bloodGlucose, Units.mgdl, "mg/dL", start, end)
        async let bodyTemp = self.quantity(.bodyTemperature, Units.celsius, "celsius", start, end)
        async let basalTemp = self.quantity(.basalBodyTemperature, Units.celsius, "celsius", start, end)
        async let wristTemp = self.quantity(.appleSleepingWristTemperature, Units.celsius, "celsius", start, end)
        async let resp = self.quantity(.respiratoryRate, Units.perMinute, "bpm", start, end)
        async let spo2 = self.quantity(.oxygenSaturation, Units.percent, "percent", start, end)
        async let bpRead = self.bloodPressure(start, end)
        async let mindfulRead = self.mindful(start, end)
        async let mood = self.stateOfMind(start, end)
        async let height = self.quantity(.height, Units.cm, "centimeter", start, end)
        async let weights = self.quantity(.bodyMass, Units.kg, "kilogram", weightFrom, end, on: w)
        async let bodyFat = self.quantity(.bodyFatPercentage, Units.percent, "percent", weightFrom, end, on: w)
        async let workoutList = self.workouts(start, end)

        var s = HealthWindowSamples()
        s.steps = await steps
        s.distance = await distance
        s.active = await active
        s.restingHr = await restingHr
        s.heartRate = await heartRate
        s.water = await water
        s.dietary = await dietary
        let reads: [Read] = [
            await exercise, await stand, await vo2, await hrv, await sleepRead, await basal, await flights, await cycling,
            await glucose, await bodyTemp, await basalTemp, await wristTemp, await resp, await spo2, await bpRead,
            await mindfulRead, await mood, await height, await weights, await bodyFat,
        ]
        s.exercise = reads[0].samples
        s.stand = reads[1].samples
        s.vo2 = reads[2].samples
        s.hrv = reads[3].samples
        s.sleep = reads[4].samples
        s.basal = reads[5].samples
        s.flights = reads[6].samples
        s.cycling = reads[7].samples
        s.glucose = reads[8].samples
        s.bodyTemp = reads[9].samples
        s.basalTemp = reads[10].samples
        s.wristTemp = reads[11].samples
        s.resp = reads[12].samples
        s.spo2 = reads[13].samples
        s.bloodPressure = reads[14].samples
        s.mindful = reads[15].samples
        s.mood = reads[16].samples
        s.height = reads[17].samples
        s.weights = reads[18].samples
        s.bodyFat = reads[19].samples
        s.workouts = await workoutList
        s.maxCount = reads.map(\.raw).max() ?? 0
        s.truncated = reads.contains { $0.raw >= HealthAggregate.sampleLimit }
        return HealthAggregate.collect(s, startKey: startKey, endKey: endKey, includeDays: includeDays)
    }

    // MARK: Workout names

    /// The plugin's workout type names (WorkoutType.fromHKWorkoutActivityType), so workouts are
    /// named exactly like the ones the web sync already stored ("strengthTraining" for traditional
    /// strength training; types it didn't know, stair climbing among them, are "other").
    static func workoutName(_ t: HKWorkoutActivityType) -> String {
        switch t {
        case .running: return "running"
        case .cycling: return "cycling"
        case .walking: return "walking"
        case .swimming: return "swimming"
        case .yoga: return "yoga"
        case .traditionalStrengthTraining: return "strengthTraining"
        case .hiking: return "hiking"
        case .tennis: return "tennis"
        case .basketball: return "basketball"
        case .soccer: return "soccer"
        case .americanFootball: return "americanFootball"
        case .archery: return "archery"
        case .australianFootball: return "australianFootball"
        case .badminton: return "badminton"
        case .barre: return "barre"
        case .baseball: return "baseball"
        case .bowling: return "bowling"
        case .boxing: return "boxing"
        case .climbing: return "climbing"
        case .cooldown: return "cooldown"
        case .coreTraining: return "coreTraining"
        case .cricket: return "cricket"
        case .crossCountrySkiing: return "crossCountrySkiing"
        case .crossTraining: return "crossTraining"
        case .curling: return "curling"
        case .discSports: return "discSports"
        case .downhillSkiing: return "downhillSkiing"
        case .elliptical: return "elliptical"
        case .equestrianSports: return "equestrianSports"
        case .fencing: return "fencing"
        case .fishing: return "fishing"
        case .fitnessGaming: return "fitnessGaming"
        case .flexibility: return "flexibility"
        case .functionalStrengthTraining: return "functionalStrengthTraining"
        case .golf: return "golf"
        case .gymnastics: return "gymnastics"
        case .handball: return "handball"
        case .handCycling: return "handCycling"
        case .highIntensityIntervalTraining: return "highIntensityIntervalTraining"
        case .hockey: return "hockey"
        case .hunting: return "hunting"
        case .jumpRope: return "jumpRope"
        case .kickboxing: return "kickboxing"
        case .lacrosse: return "lacrosse"
        case .martialArts: return "martialArts"
        case .mindAndBody: return "mindAndBody"
        case .mixedCardio: return "mixedCardio"
        case .paddleSports: return "paddleSports"
        case .pickleball: return "pickleball"
        case .pilates: return "pilates"
        case .play: return "play"
        case .preparationAndRecovery: return "preparationAndRecovery"
        case .racquetball: return "racquetball"
        case .rowing: return "rowing"
        case .rugby: return "rugby"
        case .sailing: return "sailing"
        case .skatingSports: return "skatingSports"
        case .snowboarding: return "snowboarding"
        case .snowSports: return "snowSports"
        case .softball: return "softball"
        case .squash: return "squash"
        case .stairs: return "stairs"
        case .stepTraining: return "stepTraining"
        case .surfingSports: return "surfingSports"
        case .tableTennis: return "tableTennis"
        case .taiChi: return "taiChi"
        case .trackAndField: return "trackAndField"
        case .volleyball: return "volleyball"
        case .waterFitness: return "waterFitness"
        case .waterPolo: return "waterPolo"
        case .waterSports: return "waterSports"
        case .wheelchairRunPace: return "wheelchairRunPace"
        case .wheelchairWalkPace: return "wheelchairWalkPace"
        case .wrestling: return "wrestling"
        case .cardioDance: return "cardioDance"
        case .socialDance: return "socialDance"
        case .transition: return "transition"
        case .underwaterDiving: return "underwaterDiving"
        default:
            // The deprecated .dance has no non-deprecated spelling; compare its raw value (14).
            return t.rawValue == 14 ? "dance" : "other"
        }
    }
}
