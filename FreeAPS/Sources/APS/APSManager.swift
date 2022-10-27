import Combine
import Foundation
import LoopKit
import LoopKitUI
import OmniBLE
import OmniKit
import RileyLinkKit
import SwiftDate
import Swinject

protocol APSManager {
    func heartbeat(date: Date)
    func autotune() -> AnyPublisher<Autotune?, Never>
    func enactBolus(amount: Double, isSMB: Bool)
    var pumpManager: PumpManagerUI? { get set }
    var bluetoothManager: BluetoothStateManager? { get }
    var pumpDisplayState: CurrentValueSubject<PumpDisplayState?, Never> { get }
    var pumpName: CurrentValueSubject<String, Never> { get }
    var isLooping: CurrentValueSubject<Bool, Never> { get }
    var lastLoopDate: Date { get }
    var lastLoopDateSubject: PassthroughSubject<Date, Never> { get }
    var bolusProgress: CurrentValueSubject<Decimal?, Never> { get }
    var pumpExpiresAtDate: CurrentValueSubject<Date?, Never> { get }
    var isManualTempBasal: Bool { get }
    func enactTempBasal(rate: Double, duration: TimeInterval)
    func makeProfiles() -> AnyPublisher<Bool, Never>
    func determineBasal() -> AnyPublisher<Bool, Never>
    func determineBasalSync()
    func roundBolus(amount: Decimal) -> Decimal
    var lastError: CurrentValueSubject<Error?, Never> { get }
    func cancelBolus()
    func enactAnnouncement(_ announcement: Announcement)
}

enum APSError: LocalizedError {
    case pumpError(Error)
    case invalidPumpState(message: String)
    case glucoseError(message: String)
    case apsError(message: String)
    case deviceSyncError(message: String)
    case manualBasalTemp(message: String)

    var errorDescription: String? {
        switch self {
        case let .pumpError(error):
            return "Pump error: \(error.localizedDescription)"
        case let .invalidPumpState(message):
            return "Error: Invalid Pump State: \(message)"
        case let .glucoseError(message):
            return "Error: Invalid glucose: \(message)"
        case let .apsError(message):
            return "APS error: \(message)"
        case let .deviceSyncError(message):
            return "Sync error: \(message)"
        case let .manualBasalTemp(message):
            return "Manual Basal Temp : \(message)"
        }
    }
}

final class BaseAPSManager: APSManager, Injectable {
    private let processQueue = DispatchQueue(label: "BaseAPSManager.processQueue")
    @Injected() private var storage: FileStorage!
    @Injected() private var pumpHistoryStorage: PumpHistoryStorage!
    @Injected() private var alertHistoryStorage: AlertHistoryStorage!
    @Injected() private var glucoseStorage: GlucoseStorage!
    @Injected() private var tempTargetsStorage: TempTargetsStorage!
    @Injected() private var carbsStorage: CarbsStorage!
    @Injected() private var announcementsStorage: AnnouncementsStorage!
    @Injected() private var deviceDataManager: DeviceDataManager!
    @Injected() private var nightscout: NightscoutManager!
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var broadcaster: Broadcaster!
    @Persisted(key: "lastAutotuneDate") private var lastAutotuneDate = Date()
    @Persisted(key: "lastLoopDate") var lastLoopDate: Date = .distantPast {
        didSet {
            lastLoopDateSubject.send(lastLoopDate)
        }
    }

    private var openAPS: OpenAPS!

    private var lifetime = Lifetime()

    var pumpManager: PumpManagerUI? {
        get { deviceDataManager.pumpManager }
        set { deviceDataManager.pumpManager = newValue }
    }

    var bluetoothManager: BluetoothStateManager? { deviceDataManager.bluetoothManager }

    @Persisted(key: "isManualTempBasal") var isManualTempBasal: Bool = false

    let isLooping = CurrentValueSubject<Bool, Never>(false)
    let lastLoopDateSubject = PassthroughSubject<Date, Never>()
    let lastError = CurrentValueSubject<Error?, Never>(nil)

    let bolusProgress = CurrentValueSubject<Decimal?, Never>(nil)

    var pumpDisplayState: CurrentValueSubject<PumpDisplayState?, Never> {
        deviceDataManager.pumpDisplayState
    }

    var pumpName: CurrentValueSubject<String, Never> {
        deviceDataManager.pumpName
    }

    var pumpExpiresAtDate: CurrentValueSubject<Date?, Never> {
        deviceDataManager.pumpExpiresAtDate
    }

    var settings: FreeAPSSettings {
        get { settingsManager.settings }
        set { settingsManager.settings = newValue }
    }

    init(resolver: Resolver) {
        injectServices(resolver)
        openAPS = OpenAPS(storage: storage)
        subscribe()
        lastLoopDateSubject.send(lastLoopDate)

        isLooping
            .weakAssign(to: \.deviceDataManager.loopInProgress, on: self)
            .store(in: &lifetime)
    }

    private func subscribe() {
        deviceDataManager.recommendsLoop
            .receive(on: processQueue)
            .sink { [weak self] in
                self?.loop()
            }
            .store(in: &lifetime)
        pumpManager?.addStatusObserver(self, queue: processQueue)

        deviceDataManager.errorSubject
            .receive(on: processQueue)
            .map { APSError.pumpError($0) }
            .sink {
                self.processError($0)
            }
            .store(in: &lifetime)

        deviceDataManager.bolusTrigger
            .receive(on: processQueue)
            .sink { bolusing in
                if bolusing {
                    self.createBolusReporter()
                } else {
                    self.clearBolusReporter()
                }
            }
            .store(in: &lifetime)

        // manage a manual Temp Basal from OmniPod - Force loop() after stop a temp basal or finished
        deviceDataManager.manualTempBasal
            .receive(on: processQueue)
            .sink { manualBasal in
                if manualBasal {
                    self.isManualTempBasal = true
                } else {
                    if self.isManualTempBasal {
                        self.isManualTempBasal = false
                        self.loop()
                    }
                }
            }
            .store(in: &lifetime)
    }

    func heartbeat(date: Date) {
        deviceDataManager.heartbeat(date: date)
    }

    // Loop entry point
    private func loop() {
        guard !isLooping.value else {
            warning(.apsManager, "Already looping, skip")
            return
        }

        debug(.apsManager, "Starting loop")
        isLooping.send(true)
        determineBasal()
            .replaceEmpty(with: false)
            .flatMap { [weak self] success -> AnyPublisher<Void, Error> in
                guard let self = self, success else {
                    return Fail(error: APSError.apsError(message: "Determine basal failed")).eraseToAnyPublisher()
                }

                // Open loop completed
                guard self.settings.closedLoop else {
                    return Just(()).setFailureType(to: Error.self).eraseToAnyPublisher()
                }

                self.nightscout.uploadStatus()

                // Closed loop - enact suggested
                return self.enactSuggested()
            }
            .sink { [weak self] completion in
                guard let self = self else { return }
                if case let .failure(error) = completion {
                    self.loopCompleted(error: error)
                } else {
                    self.loopCompleted()
                }
            } receiveValue: {}
            .store(in: &lifetime)
    }

    // Loop exit point
    private func loopCompleted(error: Error? = nil) {
        isLooping.send(false)

        if let error = error {
            warning(.apsManager, "Loop failed with error: \(error.localizedDescription)")
            processError(error)
        } else {
            debug(.apsManager, "Loop succeeded")
            lastLoopDate = Date()
            lastError.send(nil)
        }

        if settings.closedLoop {
            reportEnacted(received: error == nil)
        }
    }

    private func verifyStatus() -> Error? {
        guard let pump = pumpManager else {
            return APSError.invalidPumpState(message: "Pump not set")
        }
        let status = pump.status.pumpStatus

        guard !status.bolusing else {
            return APSError.invalidPumpState(message: "Pump is bolusing")
        }

        guard !status.suspended else {
            return APSError.invalidPumpState(message: "Pump suspended")
        }

        let reservoir = storage.retrieve(OpenAPS.Monitor.reservoir, as: Decimal.self) ?? 100
        guard reservoir >= 0 else {
            return APSError.invalidPumpState(message: "Reservoir is empty")
        }

        return nil
    }

    private func autosens() -> AnyPublisher<Bool, Never> {
        guard let autosens = storage.retrieve(OpenAPS.Settings.autosense, as: Autosens.self),
              (autosens.timestamp ?? .distantPast).addingTimeInterval(30.minutes.timeInterval) > Date()
        else {
            return openAPS.autosense()
                .map { $0 != nil }
                .eraseToAnyPublisher()
        }

        return Just(false).eraseToAnyPublisher()
    }

    func determineBasal() -> AnyPublisher<Bool, Never> {
        debug(.apsManager, "Start determine basal")
        guard let glucose = storage.retrieve(OpenAPS.Monitor.glucose, as: [BloodGlucose].self), glucose.isNotEmpty else {
            debug(.apsManager, "Not enough glucose data")
            processError(APSError.glucoseError(message: "Not enough glucose data"))
            return Just(false).eraseToAnyPublisher()
        }

        let lastGlucoseDate = glucoseStorage.lastGlucoseDate()
        guard lastGlucoseDate >= Date().addingTimeInterval(-12.minutes.timeInterval) else {
            debug(.apsManager, "Glucose data is stale")
            processError(APSError.glucoseError(message: "Glucose data is stale"))
            return Just(false).eraseToAnyPublisher()
        }

        guard glucoseStorage.isGlucoseNotFlat() else {
            debug(.apsManager, "Glucose data is too flat")
            processError(APSError.glucoseError(message: "Glucose data is too flat"))
            return Just(false).eraseToAnyPublisher()
        }

        let now = Date()
        let temp = currentTemp(date: now)

        let mainPublisher = makeProfiles()
            .flatMap { _ in self.autosens() }
            .flatMap { _ in self.dailyAutotune() }
            .flatMap { _ in self.openAPS.determineBasal(currentTemp: temp, clock: now) }
            .map { suggestion -> Bool in
                if let suggestion = suggestion {
                    DispatchQueue.main.async {
                        self.broadcaster.notify(SuggestionObserver.self, on: .main) {
                            $0.suggestionDidUpdate(suggestion)
                        }
                    }
                }

                return suggestion != nil
            }
            .eraseToAnyPublisher()

        if temp.duration == 0,
           settings.closedLoop,
           settingsManager.preferences.unsuspendIfNoTemp,
           let pump = pumpManager,
           pump.status.pumpStatus.suspended
        {
            return pump.resumeDelivery()
                .flatMap { _ in mainPublisher }
                .replaceError(with: false)
                .eraseToAnyPublisher()
        }

        return mainPublisher
    }

    func determineBasalSync() {
        determineBasal().cancellable().store(in: &lifetime)
    }

    func makeProfiles() -> AnyPublisher<Bool, Never> {
        openAPS.makeProfiles(useAutotune: settings.useAutotune)
            .map { tunedProfile in
                if let basalProfile = tunedProfile?.basalProfile {
                    self.processQueue.async {
                        self.broadcaster.notify(BasalProfileObserver.self, on: self.processQueue) {
                            $0.basalProfileDidChange(basalProfile)
                        }
                    }
                }

                return tunedProfile != nil
            }
            .eraseToAnyPublisher()
    }

    func roundBolus(amount: Decimal) -> Decimal {
        guard let pump = pumpManager else { return amount }
        let rounded = Decimal(pump.roundToSupportedBolusVolume(units: Double(amount)))
        let maxBolus = Decimal(pump.roundToSupportedBolusVolume(units: Double(settingsManager.pumpSettings.maxBolus)))
        return min(rounded, maxBolus)
    }

    private var bolusReporter: DoseProgressReporter?

    func enactBolus(amount: Double, isSMB: Bool) {
        if let error = verifyStatus() {
            processError(error)
            processQueue.async {
                self.broadcaster.notify(BolusFailureObserver.self, on: self.processQueue) {
                    $0.bolusDidFail()
                }
            }
            return
        }

        guard let pump = pumpManager else { return }

        let roundedAmout = pump.roundToSupportedBolusVolume(units: amount)

        debug(.apsManager, "Enact bolus \(roundedAmout), manual \(!isSMB)")

        pump.enactBolus(units: roundedAmout, automatic: isSMB).sink { completion in
            if case let .failure(error) = completion {
                warning(.apsManager, "Bolus failed with error: \(error.localizedDescription)")
                self.processError(APSError.pumpError(error))
                if !isSMB {
                    self.processQueue.async {
                        self.broadcaster.notify(BolusFailureObserver.self, on: self.processQueue) {
                            $0.bolusDidFail()
                        }
                    }
                }
            } else {
                debug(.apsManager, "Bolus succeeded")
                if !isSMB {
                    self.determineBasal().sink { _ in }.store(in: &self.lifetime)
                }
                self.bolusProgress.send(0)
            }
        } receiveValue: { _ in }
            .store(in: &lifetime)
    }

    func cancelBolus() {
        guard let pump = pumpManager, pump.status.pumpStatus.bolusing else { return }
        debug(.apsManager, "Cancel bolus")
        pump.cancelBolus().sink { completion in
            if case let .failure(error) = completion {
                debug(.apsManager, "Bolus cancellation failed with error: \(error.localizedDescription)")
                self.processError(APSError.pumpError(error))
            } else {
                debug(.apsManager, "Bolus cancelled")
            }

            self.bolusReporter?.removeObserver(self)
            self.bolusReporter = nil
            self.bolusProgress.send(nil)
        } receiveValue: { _ in }
            .store(in: &lifetime)
    }

    func enactTempBasal(rate: Double, duration: TimeInterval) {
        if let error = verifyStatus() {
            processError(error)
            return
        }

        guard let pump = pumpManager else { return }

        // unable to do temp basal during manual temp basal 😁
        if isManualTempBasal {
            processError(APSError.manualBasalTemp(message: "Loop not possible during the manual basal temp"))
            return
        }

        debug(.apsManager, "Enact temp basal \(rate) - \(duration)")

        let roundedAmout = pump.roundToSupportedBasalRate(unitsPerHour: rate)
        pump.enactTempBasal(unitsPerHour: roundedAmout, for: duration) { error in
            if let error = error {
                debug(.apsManager, "Temp Basal failed with error: \(error.localizedDescription)")
                self.processError(APSError.pumpError(error))
            } else {
                debug(.apsManager, "Temp Basal succeeded")
                let temp = TempBasal(duration: Int(duration / 60), rate: Decimal(rate), temp: .absolute, timestamp: Date())
                self.storage.save(temp, as: OpenAPS.Monitor.tempBasal)
                if rate == 0, duration == 0 {
                    self.pumpHistoryStorage.saveCancelTempEvents()
                }
            }
        }
    }

    func dailyAutotune() -> AnyPublisher<Bool, Never> {
        guard settings.useAutotune else {
            return Just(false).eraseToAnyPublisher()
        }

        let now = Date()

        guard lastAutotuneDate.isBeforeDate(now, granularity: .day) else {
            return Just(false).eraseToAnyPublisher()
        }
        lastAutotuneDate = now

        return autotune().map { $0 != nil }.eraseToAnyPublisher()
    }

    func autotune() -> AnyPublisher<Autotune?, Never> {
        openAPS.autotune().eraseToAnyPublisher()
    }

    func enactAnnouncement(_ announcement: Announcement) {
        guard let action = announcement.action else {
            warning(.apsManager, "Invalid Announcement action")
            return
        }

        guard let pump = pumpManager else {
            warning(.apsManager, "Pump is not set")
            return
        }

        debug(.apsManager, "Start enact announcement: \(action)")

        switch action {
        case let .bolus(amount):
            if let error = verifyStatus() {
                processError(error)
                return
            }
            let roundedAmount = pump.roundToSupportedBolusVolume(units: Double(amount))
            pump.enactBolus(units: roundedAmount, activationType: .manualRecommendationAccepted) { error in
                if let error = error {
                    // warning(.apsManager, "Announcement Bolus failed with error: \(error.localizedDescription)")
                    switch error {
                    case .uncertainDelivery:
                        // Do not generate notification on uncertain delivery error
                        break
                    default:
                        // Do not generate notifications for automatic boluses that fail.
                        warning(.apsManager, "Announcement Bolus failed with error: \(error.localizedDescription)")
                    }

                } else {
                    debug(.apsManager, "Announcement Bolus succeeded")
                    self.announcementsStorage.storeAnnouncements([announcement], enacted: true)
                    self.bolusProgress.send(0)
                }
            }
        case let .pump(pumpAction):
            switch pumpAction {
            case .suspend:
                if let error = verifyStatus() {
                    processError(error)
                    return
                }
                pump.suspendDelivery { error in
                    if let error = error {
                        debug(.apsManager, "Pump not suspended by Announcement: \(error.localizedDescription)")
                    } else {
                        debug(.apsManager, "Pump suspended by Announcement")
                        self.announcementsStorage.storeAnnouncements([announcement], enacted: true)
                        self.nightscout.uploadStatus()
                    }
                }
            case .resume:
                guard pump.status.pumpStatus.suspended else {
                    return
                }
                pump.resumeDelivery { error in
                    if let error = error {
                        warning(.apsManager, "Pump not resumed by Announcement: \(error.localizedDescription)")
                    } else {
                        debug(.apsManager, "Pump resumed by Announcement")
                        self.announcementsStorage.storeAnnouncements([announcement], enacted: true)
                        self.nightscout.uploadStatus()
                    }
                }
            }
        case let .looping(closedLoop):
            settings.closedLoop = closedLoop
            debug(.apsManager, "Closed loop \(closedLoop) by Announcement")
            announcementsStorage.storeAnnouncements([announcement], enacted: true)
        case let .tempbasal(rate, duration):
            if let error = verifyStatus() {
                processError(error)
                return
            }
            // unable to do temp basal during manual temp basal 😁
            if isManualTempBasal {
                processError(APSError.manualBasalTemp(message: "Loop not possible during the manual basal temp"))
                return
            }
            guard !settings.closedLoop else {
                return
            }
            let roundedRate = pump.roundToSupportedBasalRate(unitsPerHour: Double(rate))
            pump.enactTempBasal(unitsPerHour: roundedRate, for: TimeInterval(duration) * 60) { error in
                if let error = error {
                    warning(.apsManager, "Announcement TempBasal failed with error: \(error.localizedDescription)")
                } else {
                    debug(.apsManager, "Announcement TempBasal succeeded")
                    self.announcementsStorage.storeAnnouncements([announcement], enacted: true)
                }
            }
        }
    }

    private func currentTemp(date: Date) -> TempBasal {
        let defaultTemp = { () -> TempBasal in
            guard let temp = storage.retrieve(OpenAPS.Monitor.tempBasal, as: TempBasal.self) else {
                return TempBasal(duration: 0, rate: 0, temp: .absolute, timestamp: Date())
            }
            let delta = Int((date.timeIntervalSince1970 - temp.timestamp.timeIntervalSince1970) / 60)
            let duration = max(0, temp.duration - delta)
            return TempBasal(duration: duration, rate: temp.rate, temp: .absolute, timestamp: date)
        }()

        guard let state = pumpManager?.status.basalDeliveryState else { return defaultTemp }
        switch state {
        case .active:
            return TempBasal(duration: 0, rate: 0, temp: .absolute, timestamp: date)
        case let .tempBasal(dose):
            let rate = Decimal(dose.unitsPerHour)
            let durationMin = max(0, Int((dose.endDate.timeIntervalSince1970 - date.timeIntervalSince1970) / 60))
            return TempBasal(duration: durationMin, rate: rate, temp: .absolute, timestamp: date)
        default:
            return defaultTemp
        }
    }

    private func enactSuggested() -> AnyPublisher<Void, Error> {
        guard let suggested = storage.retrieve(OpenAPS.Enact.suggested, as: Suggestion.self) else {
            return Fail(error: APSError.apsError(message: "Suggestion not found")).eraseToAnyPublisher()
        }

        guard Date().timeIntervalSince(suggested.deliverAt ?? .distantPast) < Config.eхpirationInterval else {
            return Fail(error: APSError.apsError(message: "Suggestion expired")).eraseToAnyPublisher()
        }

        guard let pump = pumpManager else {
            return Fail(error: APSError.apsError(message: "Pump not set")).eraseToAnyPublisher()
        }

        // unable to do temp basal during manual temp basal 😁
        if isManualTempBasal {
            return Fail(error: APSError.manualBasalTemp(message: "Loop not possible during the manual basal temp"))
                .eraseToAnyPublisher()
        }

        let basalPublisher: AnyPublisher<Void, Error> = Deferred { () -> AnyPublisher<Void, Error> in
            if let error = self.verifyStatus() {
                return Fail(error: error).eraseToAnyPublisher()
            }

            guard let rate = suggested.rate, let duration = suggested.duration else {
                // It is OK, no temp required
                debug(.apsManager, "No temp required")
                return Just(()).setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
            }
            return pump.enactTempBasal(unitsPerHour: Double(rate), for: TimeInterval(duration * 60)).map { _ in
                let temp = TempBasal(duration: duration, rate: rate, temp: .absolute, timestamp: Date())
                self.storage.save(temp, as: OpenAPS.Monitor.tempBasal)
                return ()
            }
            .eraseToAnyPublisher()
        }.eraseToAnyPublisher()

        let bolusPublisher: AnyPublisher<Void, Error> = Deferred { () -> AnyPublisher<Void, Error> in
            if let error = self.verifyStatus() {
                return Fail(error: error).eraseToAnyPublisher()
            }
            guard let units = suggested.units else {
                // It is OK, no bolus required
                debug(.apsManager, "No bolus required")
                return Just(()).setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
            }
            return pump.enactBolus(units: Double(units), automatic: true).map { _ in
                self.bolusProgress.send(0)
                return ()
            }
            .eraseToAnyPublisher()
        }.eraseToAnyPublisher()

        return basalPublisher.flatMap { bolusPublisher }.eraseToAnyPublisher()
    }

    private func reportEnacted(received: Bool) {
        if let suggestion = storage.retrieve(OpenAPS.Enact.suggested, as: Suggestion.self), suggestion.deliverAt != nil {
            var enacted = suggestion
            enacted.timestamp = Date()
            enacted.recieved = received

            storage.save(enacted, as: OpenAPS.Enact.enacted)

            // Create a tdd.json
            tdd(enacted_: enacted)

            // Create a dailyStats.json
            dailyStats()

            debug(.apsManager, "Suggestion enacted. Received: \(received)")
            DispatchQueue.main.async {
                self.broadcaster.notify(EnactedSuggestionObserver.self, on: .main) {
                    $0.enactedSuggestionDidUpdate(enacted)
                }
            }
            nightscout.uploadStatus()
        }
    }

    func tdd(enacted_: Suggestion) {
        // Add to tdd.json:
        let preferences = settingsManager.preferences
        let currentTDD = enacted_.tdd ?? 0
        let file = OpenAPS.Monitor.tdd
        let tdd = TDD(
            TDD: currentTDD,
            timestamp: Date(),
            id: UUID().uuidString
        )
        var uniqEvents: [TDD] = []
        storage.transaction { storage in
            storage.append(tdd, to: file, uniqBy: \.id)
            uniqEvents = storage.retrieve(file, as: [TDD].self)?
                .filter { $0.timestamp.addingTimeInterval(14.days.timeInterval) > Date() }
                .sorted { $0.timestamp > $1.timestamp } ?? []
            var total: Decimal = 0
            var indeces: Decimal = 0
            for uniqEvent in uniqEvents {
                if uniqEvent.TDD > 0 {
                    total += uniqEvent.TDD
                    indeces += 1
                }
            }
            let entriesPast2hours = storage.retrieve(file, as: [TDD].self)?
                .filter { $0.timestamp.addingTimeInterval(2.hours.timeInterval) > Date() }
                .sorted { $0.timestamp > $1.timestamp } ?? []
            var totalAmount: Decimal = 0
            var nrOfIndeces: Decimal = 0
            for entry in entriesPast2hours {
                if entry.TDD > 0 {
                    totalAmount += entry.TDD
                    nrOfIndeces += 1
                }
            }
            if indeces == 0 {
                indeces = 1
            }
            if nrOfIndeces == 0 {
                nrOfIndeces = 1
            }
            let average14 = total / indeces
            let average2hours = totalAmount / nrOfIndeces
            let weight = preferences.weightPercentage
            let weighted_average = weight * average2hours + (1 - weight) * average14
            let averages = TDD_averages(
                average_total_data: average14,
                weightedAverage: weighted_average,
                past2hoursAverage: average2hours,
                date: Date()
            )
            storage.save(averages, as: OpenAPS.Monitor.tdd_averages)
            storage.save(Array(uniqEvents), as: file)
        }
    }

    func dailyStats() {
        // Add to dailyStats.JSON
        let preferences = settingsManager.preferences
        let carbs = storage.retrieve(OpenAPS.Monitor.carbHistory, as: [CarbsEntry].self)
        let tdds = storage.retrieve(OpenAPS.Monitor.tdd, as: [TDD].self)
        let currentTDD = tdds?[0].TDD

        var carbTotal: Decimal = 0
        for each in carbs! {
            if each.carbs != 0 {
                carbTotal += each.carbs
            }
        }

        var algo_ = "oref0"
        if preferences.enableChris, preferences.useNewFormula {
            algo_ = "Dynamic ISF, Logarithmic Formula"
        } else if !preferences.useNewFormula, preferences.enableChris {
            algo_ = "Dynamic ISF, Original Formula"
        }
        let af = preferences.adjustmentFactor
        let insulin_type = preferences.curve
        var buildDate: Date {
            if let infoPath = Bundle.main.path(forResource: "Info", ofType: "plist"),
               let infoAttr = try? FileManager.default.attributesOfItem(atPath: infoPath),
               let infoDate = infoAttr[.modificationDate] as? Date
            {
                return infoDate
            }
            return Date()
        }
        let nsObject: AnyObject? = Bundle.main.infoDictionary!["CFBundleShortVersionString"] as AnyObject
        let version = nsObject as! String
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        let branch = Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String
        let pump_ = pumpManager?.localizedTitle ?? ""
        let cgm = settingsManager.settings.cgm
        let file = OpenAPS.Monitor.dailyStats
        let date_ = Date()
        var iPa: Decimal = 75
        if preferences.useCustomPeakTime {
            iPa = preferences.insulinPeakTime
        } else if preferences.curve.rawValue == "rapid-acting" {
            iPa = 65
        } else if preferences.curve.rawValue == "ultra-rapid" {
            iPa = 50
        }

        // HbA1c string:
        let stats = storage.retrieve(OpenAPS.Monitor.dailyStats, as: [DailyStats].self)
        let length__ = stats?.count ?? 0
        var string7Days = ""
        var string14Days = ""
        var stringTotal = ""

        switch length__ {
        case 7...:
            string7Days = " HbA1c for previous 7 days: \(tir().HbA1cIFCC_7) mmol/mol / \(tir().HbA1cNGSP_7) %."
            fallthrough
        case 14...:
            string14Days = " HbA1c for previous 14 days: \(tir().HbA1cIFCC_14) mmol/mol / \(tir().HbA1cNGSP_14) %."
            fallthrough
        case 2...:
            stringTotal =
                " HbA1c for total number of days(\(length__)): \(tir().HbA1cIFCC_total) mmol/mol / \(tir().HbA1cNGSP_total) %."
        default:
            stringTotal = ""
        }

        let HbA1c_string =
            "Estimated HbA1c: \(tir().HbA1cIFCC) mmol/mol / \(tir().HbA1cNGSP) % and Average Blood Glucose: \(tir().averageGlucose) mg/dl / \(round(Double(tir().averageGlucose * 0.0555) * 10) / 10) mmol/l for the previous day, 00:00-23:59." +
            string7Days + string14Days + stringTotal

        let dailystat = DailyStats(
            date: date_,
            FAX_Build_Version: version,
            FAX_Build_Number: build ?? "1",
            FAX_Branch: branch ?? "N/A",
            FAX_Build_Date: buildDate,
            Algorithm: algo_,
            AdjustmentFactor: af,
            Pump: pump_,
            CGM: cgm.rawValue,
            insulinType: insulin_type.rawValue,
            peakActivityTime: iPa,
            TDD: currentTDD ?? 0,
            Carbs_24h: carbTotal,
            Hypoglucemias_Percentage: tir().hypos,
            TIR_Percentage: tir().TIR,
            Hyperglucemias_Percentage: tir().hypers,
            BG_daily_Average_mg_dl: tir().averageGlucose,
            HbA1c: HbA1c_string,
            id: UUID().uuidString
        )

        var newEntries: [DailyStats] = []

        // If file is empty
        let file_3 = loadFileFromStorage(name: OpenAPS.Monitor.dailyStats)
        var isJSONempty = false
        if file_3.rawJSON.isEmpty {
            isJSONempty = true
        }

        let now = Date()
        let calender = Calendar.current

        // If current local time is 23:41 or later
        if calender.component(.hour, from: now) > 22,
           calender.component(.minute, from: now) > 40
        {
            if isJSONempty {
                storage.save(dailystat, as: file)
            } else {
                storage.transaction { storage in
                    storage.append(dailystat, to: file, uniqBy: \.id)
                    newEntries = storage.retrieve(file, as: [DailyStats].self)?
                        .filter { $0.date.addingTimeInterval(1.days.timeInterval) < now }
                        .sorted { $0.date > $1.date } ?? []
                    storage.save(Array(newEntries), as: file)
                }
            }
        }
    }

    // Time In Range (%), Average Glucose (24 hours) and HbA1c
    func tir()
        -> (
            averageGlucose: Decimal,
            hypos: Decimal,
            hypers: Decimal,
            TIR: Decimal,
            HbA1cIFCC: Decimal,
            HbA1cNGSP: Decimal,
            HbA1cIFCC_7: Decimal,
            HbA1cNGSP_7: Decimal,
            HbA1cIFCC_14: Decimal,
            HbA1cNGSP_14: Decimal,
            HbA1cIFCC_total: Decimal,
            HbA1cNGSP_total: Decimal
        )
    {
        let glucose = storage.retrieve(OpenAPS.Monitor.glucose, as: [BloodGlucose].self)

        let length_ = glucose?.count ?? 0
        let endIndex = length_ - 1

        guard length_ != 0 else {
            return (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        }

        var bg: Decimal = 0
        var nr_bgs: Decimal = 0

        for entry in glucose! {
            if entry.glucose! > 0 {
                bg += Decimal(entry.glucose!)
                nr_bgs += 1
            }
        }
        var averageGlucose = bg / nr_bgs
        // Round
        averageGlucose = Decimal(round(Double(averageGlucose)))

        // If more than l day of stats:
        let stats = storage.retrieve(OpenAPS.Monitor.dailyStats, as: [DailyStats].self)
        
        var avgS: Decimal = 0
        var nrAvgs: Decimal = 0
        var sevenDaysAvg: Decimal = 0
        var fourteenDaysAvg: Decimal = 0
        var totalDataAvg: Decimal = 0
        let arraysInjson = stats?.count ?? 0

        if arraysInjson > 1 {
            for entry in stats! {
                if stats?.BG_daily_Average_mg_dl != nil {
                    avgS += entry.BG_daily_Average_mg_dl
                    print("Average: \(entry.BG_daily_Average_mg_dl)")
                    nrAvgs += 1

                    if nrAvgs >= 1 {
                        totalDataAvg = avgS / nrAvgs
                    }
                    if nrAvgs == 7 {
                        sevenDaysAvg = avgS / nrAvgs
                    }
                    if nrAvgs == 14 {
                        fourteenDaysAvg = avgS / nrAvgs
                    }
                }
            }
        }

        let fullTime = glucose![0].date - glucose![endIndex].date
        var timeInHypo: Decimal = 0
        var timeInHyper: Decimal = 0
        var hypos: Decimal = 0
        var hypers: Decimal = 0
        var i = -1

        var lastIndex = false

        while i < endIndex {
            i += 1

            let currentTime = glucose![i].date
            var previousTime = currentTime

            if i + 1 <= endIndex {
                previousTime = glucose![i + 1].date
            } else {
                lastIndex = true
            }

            if glucose![i].glucose! < 72, !lastIndex {
                timeInHypo += currentTime - previousTime
            } else if glucose![i].glucose! > 180, !lastIndex {
                timeInHyper += currentTime - previousTime
            }
        }

        if timeInHypo == 0 {
            hypos = 0
        } else { hypos = (timeInHypo / fullTime) * 100
        }

        if timeInHyper == 0 {
            hypers = 0
        } else { hypers = (timeInHyper / fullTime) * 100
        }

        // round to 1 decimal
        let hypoRounded = round(Double(hypos) * 10) / 10
        let hyperRounded = round(Double(hypers) * 10) / 10
        let TIRrounded = round((100 - (hypoRounded + hyperRounded)) * 10) / 10

        // HbA1c estimation (%, mmol/mol
        let NGSPa1CStatisticValue = (46.7 + averageGlucose) / 28.7 // NGSP (%)
        let IFCCa1CStatisticValue = 10.929 *
            (NGSPa1CStatisticValue - 2.152) // IFCC (mmol/mol)  A1C(mmol/mol) = 10.929 * (A1C(%) - 2.15)
        // 7 days
        let NGSPa1CStatisticValue_7 = (46.7 + sevenDaysAvg) / 28.7
        let IFCCa1CStatisticValue_7 = 10.929 * (NGSPa1CStatisticValue_7 - 2.152)
        // 14 days
        let NGSPa1CStatisticValue_14 = (46.7 + fourteenDaysAvg) / 28.7
        let IFCCa1CStatisticValue_14 = 10.929 * (NGSPa1CStatisticValue_14 - 2.152)
        // A
        let NGSPa1CStatisticValue_total = (46.7 + totalDataAvg) / 28.7
        let IFCCa1CStatisticValue_total = 10.929 * (NGSPa1CStatisticValue_total - 2.152)

        // Round
        let HbA1cRoundedIFCC = round(Double(IFCCa1CStatisticValue) * 10) / 10
        let HbA1cRoundedNGSP = round(Double(NGSPa1CStatisticValue) * 10) / 10
        let HbA1cRoundedIFCC_7 = round(Double(IFCCa1CStatisticValue_7) * 10) / 10
        let HbA1cRoundedNGSP_7 = round(Double(NGSPa1CStatisticValue_7) * 10) / 10
        let HbA1cRoundedIFCC_14 = round(Double(IFCCa1CStatisticValue_14) * 10) / 10
        let HbA1cRoundedNGSP_14 = round(Double(NGSPa1CStatisticValue_14) * 10) / 10
        let HbA1cRoundedIFCC_total = round(Double(IFCCa1CStatisticValue_total) * 10) / 10
        let HbA1cRoundedNGSP_total = round(Double(NGSPa1CStatisticValue_total) * 10) / 10

        // For testing. See in Xcode console each loop.
        /*
         print(
             "Average Glucose: \(averageGlucose) mg/dl, TIR: \(TIRrounded) %, Hypos: \(hypoRounded) %, Hypers: \(hyperRounded) %, HbA1c : \(HbA1cRoundedIFCC) mmol/mol / \(HbA1cRoundedNGSP) %"
         )
         */

        return (
            averageGlucose,
            Decimal(hypoRounded),
            Decimal(hyperRounded),
            Decimal(TIRrounded),
            Decimal(HbA1cRoundedIFCC),
            Decimal(HbA1cRoundedNGSP),
            Decimal(HbA1cRoundedIFCC_7),
            Decimal(HbA1cRoundedNGSP_7),
            Decimal(HbA1cRoundedIFCC_14),
            Decimal(HbA1cRoundedNGSP_14),
            Decimal(HbA1cRoundedIFCC_total),
            Decimal(HbA1cRoundedNGSP_total)
        )
    }

    private func loadFileFromStorage(name: String) -> RawJSON {
        storage.retrieveRaw(name) ?? OpenAPS.defaults(for: name)
    }

    private func processError(_ error: Error) {
        warning(.apsManager, "\(error.localizedDescription)")
        lastError.send(error)
    }

    private func createBolusReporter() {
        bolusReporter = pumpManager?.createBolusProgressReporter(reportingOn: processQueue)
        bolusReporter?.addObserver(self)
    }

    private func updateStatus() {
        debug(.apsManager, "force update status")
        guard let pump = pumpManager else {
            return
        }

        if let omnipod = pump as? OmnipodPumpManager {
            omnipod.getPodStatus { _ in }
        }
        if let omnipodBLE = pump as? OmniBLEPumpManager {
            omnipodBLE.getPodStatus { _ in }
        }
    }

    private func clearBolusReporter() {
        bolusReporter?.removeObserver(self)
        bolusReporter = nil
        processQueue.asyncAfter(deadline: .now() + 0.5) {
            self.bolusProgress.send(nil)
            self.updateStatus()
        }
    }
}

private extension PumpManager {
    func enactTempBasal(unitsPerHour: Double, for duration: TimeInterval) -> AnyPublisher<DoseEntry?, Error> {
        Future { promise in
            self.enactTempBasal(unitsPerHour: unitsPerHour, for: duration) { error in
                if let error = error {
                    debug(.apsManager, "Temp basal failed: \(unitsPerHour) for: \(duration)")
                    promise(.failure(error))
                } else {
                    debug(.apsManager, "Temp basal succeded: \(unitsPerHour) for: \(duration)")
                    promise(.success(nil))
                }
            }
        }
        .mapError { APSError.pumpError($0) }
        .eraseToAnyPublisher()
    }

    func enactBolus(units: Double, automatic: Bool) -> AnyPublisher<DoseEntry?, Error> {
        Future { promise in
            // convert automatic
            let automaticValue = automatic ? BolusActivationType.automatic : BolusActivationType.manualRecommendationAccepted

            self.enactBolus(units: units, activationType: automaticValue) { error in
                if let error = error {
                    debug(.apsManager, "Bolus failed: \(units)")
                    promise(.failure(error))
                } else {
                    debug(.apsManager, "Bolus succeded: \(units)")
                    promise(.success(nil))
                }
            }
        }
        .mapError { APSError.pumpError($0) }
        .eraseToAnyPublisher()
    }

    func cancelBolus() -> AnyPublisher<DoseEntry?, Error> {
        Future { promise in
            self.cancelBolus { result in
                switch result {
                case let .success(dose):
                    debug(.apsManager, "Cancel Bolus succeded")
                    promise(.success(dose))
                case let .failure(error):
                    debug(.apsManager, "Cancel Bolus failed")
                    promise(.failure(error))
                }
            }
        }
        .mapError { APSError.pumpError($0) }
        .eraseToAnyPublisher()
    }

    func suspendDelivery() -> AnyPublisher<Void, Error> {
        Future { promise in
            self.suspendDelivery { error in
                if let error = error {
                    promise(.failure(error))
                } else {
                    promise(.success(()))
                }
            }
        }
        .mapError { APSError.pumpError($0) }
        .eraseToAnyPublisher()
    }

    func resumeDelivery() -> AnyPublisher<Void, Error> {
        Future { promise in
            self.resumeDelivery { error in
                if let error = error {
                    promise(.failure(error))
                } else {
                    promise(.success(()))
                }
            }
        }
        .mapError { APSError.pumpError($0) }
        .eraseToAnyPublisher()
    }
}

extension BaseAPSManager: PumpManagerStatusObserver {
    func pumpManager(_: PumpManager, didUpdate status: PumpManagerStatus, oldStatus _: PumpManagerStatus) {
        let percent = Int((status.pumpBatteryChargeRemaining ?? 1) * 100)
        let battery = Battery(
            percent: percent,
            voltage: nil,
            string: percent > 10 ? .normal : .low,
            display: status.pumpBatteryChargeRemaining != nil
        )
        storage.save(battery, as: OpenAPS.Monitor.battery)
        storage.save(status.pumpStatus, as: OpenAPS.Monitor.status)
    }
}

extension BaseAPSManager: DoseProgressObserver {
    func doseProgressReporterDidUpdate(_ doseProgressReporter: DoseProgressReporter) {
        bolusProgress.send(Decimal(doseProgressReporter.progress.percentComplete))
        if doseProgressReporter.progress.isComplete {
            clearBolusReporter()
        }
    }
}

extension PumpManagerStatus {
    var pumpStatus: PumpStatus {
        let bolusing = bolusState != .noBolus
        let suspended = basalDeliveryState?.isSuspended ?? true
        let type = suspended ? StatusType.suspended : (bolusing ? .bolusing : .normal)
        return PumpStatus(status: type, bolusing: bolusing, suspended: suspended, timestamp: Date())
    }
}
