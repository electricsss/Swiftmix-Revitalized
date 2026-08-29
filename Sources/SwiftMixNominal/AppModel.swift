import Combine
import CoreMIDI
import Foundation
import ServiceManagement
import SwiftMixCore

struct BankRoute: Codable, Equatable {
    var sourceUniqueID: MIDIUniqueID?
    var sourceName: String?
    var destinationUniqueID: MIDIUniqueID?
    var destinationName: String?
}

struct BankRuntimeState: Identifiable {
    let bank: Int
    var sourceConnected = false
    var destinationConnected = false
    var online = false
    var lastReplyUptime: TimeInterval?
    var connectionGeneration: UInt = 0

    var id: Int { bank }
}

struct ObservedFader: Equatable {
    let bank: Int
    let fader: Int
    let value: Int
    let date: Date

    var channel: Int {
        bank * 8 + fader + 1
    }
}

private struct OutboundFaderCommand {
    let value: Int
    let sentUptime: TimeInterval
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var sources: [MIDIEndpointInfo] = []
    @Published private(set) var destinations: [MIDIEndpointInfo] = []
    @Published private(set) var routes: [BankRoute]
    @Published private(set) var runtimeStates: [BankRuntimeState]
    @Published private(set) var lastObservedFader: ObservedFader?

    @Published private(set) var channelCount: Int
    @Published private(set) var nominalValue: Int
    @Published private(set) var tolerance: Int
    @Published private(set) var nominalLockEnabled: Bool
    @Published private(set) var nominalVerified: Bool
    @Published private(set) var launchAtLoginEnabled: Bool
    @Published private(set) var transmissionEnabled: Bool
    @Published private(set) var automaticTransmissionAuthorized: Bool
    @Published private(set) var dawTakeoverEnabled = false
    @Published private(set) var dawMIDIChannel: Int
    @Published private(set) var dawControllerBase: Int
    @Published private(set) var localEchoDetected = false
    @Published private(set) var commissioningPhase: CommissioningSequencePhase = .idle
    @Published private(set) var commissioningCompletedChannels = 0
    @Published private(set) var commissioningPassedThisSession = false
    @Published private(set) var lastIssue: String?

    private enum DefaultsKey {
        static let routes = "bankRoutes"
        static let channelCount = "channelCount"
        static let nominalValue = "nominalValue"
        static let tolerance = "nominalTolerance"
        static let lockEnabled = "nominalLockEnabled"
        static let nominalVerified = "nominalVerified"
        static let automaticTransmissionAuthorized = "automaticHUITransmissionAuthorized"
        static let dawMIDIChannel = "dawTakeoverMIDIChannel"
        static let dawControllerBase = "dawTakeoverControllerBase"
    }

    private let defaults: UserDefaults
    private let midi: CoreMIDIService
    private var streamParsers = Array(repeating: MIDIMessageStreamParser(), count: 4)
    private var huiParsers = Array(repeating: HUIFaderParser(), count: 4)
    private var keepaliveTask: Task<Void, Never>?
    private var commissioningTask: Task<Void, Never>?
    private var commissioningSequence: CommissioningSequence?
    private var recentFaderCommands: [Int: OutboundFaderCommand] = [:]
    private var vegasNextChannel = 0
    private var vegasStartedUptime: TimeInterval?
    private var lastReassertionUptime = -Double.infinity
    private var refreshWorkItem: DispatchWorkItem?
    private var hasStarted = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let savedChannelCount = defaults.integer(forKey: DefaultsKey.channelCount)
        channelCount = [8, 16, 24, 32].contains(savedChannelCount) ? savedChannelCount : 32

        if defaults.object(forKey: DefaultsKey.nominalValue) == nil {
            nominalValue = HUI.defaultNominalValue
        } else {
            nominalValue = min(
                max(defaults.integer(forKey: DefaultsKey.nominalValue), HUI.minimumFaderValue),
                HUI.maximumFaderValue
            )
        }

        if defaults.object(forKey: DefaultsKey.tolerance) == nil {
            tolerance = 32
        } else {
            tolerance = min(max(defaults.integer(forKey: DefaultsKey.tolerance), 0), 512)
        }

        if defaults.object(forKey: DefaultsKey.lockEnabled) == nil {
            nominalLockEnabled = true
        } else {
            nominalLockEnabled = defaults.bool(forKey: DefaultsKey.lockEnabled)
        }
        nominalVerified = defaults.bool(forKey: DefaultsKey.nominalVerified)

        var savedRoutes: [BankRoute]
        if let data = defaults.data(forKey: DefaultsKey.routes),
           let decoded = try? JSONDecoder().decode([BankRoute].self, from: data) {
            savedRoutes = Array(decoded.prefix(4))
            while savedRoutes.count < 4 {
                savedRoutes.append(BankRoute())
            }
        } else {
            savedRoutes = Array(repeating: BankRoute(), count: 4)
        }
        routes = savedRoutes

        let savedAutomaticTransmissionAuthorization = defaults.bool(
            forKey: DefaultsKey.automaticTransmissionAuthorized
        )
        automaticTransmissionAuthorized = savedAutomaticTransmissionAuthorization
        transmissionEnabled = savedAutomaticTransmissionAuthorization
        dawMIDIChannel = defaults.object(forKey: DefaultsKey.dawMIDIChannel) == nil
            ? 1
            : min(max(defaults.integer(forKey: DefaultsKey.dawMIDIChannel), 1), 16)
        dawControllerBase = defaults.object(forKey: DefaultsKey.dawControllerBase) == nil
            ? 16
            : min(max(defaults.integer(forKey: DefaultsKey.dawControllerBase), 0), 96)
        runtimeStates = (0..<4).map { BankRuntimeState(bank: $0) }
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled

        midi = CoreMIDIService()
        midi.setTransmissionEnabled(transmissionEnabled)
        if let setupError = midi.setupError {
            lastIssue = setupError
        } else if let dawSetupError = midi.dawSetupError {
            lastIssue = dawSetupError
        }

        midi.onBytes = { [weak self] event in
            DispatchQueue.main.async {
                self?.process(event: event)
            }
        }
        midi.onTopologyChanged = { [weak self] in
            self?.handleTopologyChanged()
        }
    }

    deinit {
        midi.setTransmissionEnabled(false)
        keepaliveTask?.cancel()
        commissioningTask?.cancel()
        refreshWorkItem?.cancel()
    }

    var activeBankCount: Int {
        channelCount / 8
    }

    var isCommissioningActive: Bool {
        switch commissioningPhase {
        case .testing, .vegas:
            return true
        case .idle, .failed:
            return false
        }
    }

    var isVegasMode: Bool {
        commissioningPhase == .vegas
    }

    var hasUnsafeActiveMode: Bool {
        isCommissioningActive || dawTakeoverEnabled
    }

    var lockIsArmed: Bool {
        transmissionEnabled
            && nominalLockEnabled
            && nominalVerified
            && !localEchoDetected
            && !isCommissioningActive
            && !dawTakeoverEnabled
    }

    /// The icon is bright only when normal nominal lock control is verified and
    /// every active bank is exchanging HUI keepalives. Test modes remain dim.
    var menuBarIconIsActive: Bool {
        lockIsArmed
            && runtimeStates.prefix(activeBankCount).count == activeBankCount
            && runtimeStates.prefix(activeBankCount).allSatisfy { $0.online }
    }

    var statusLine: String {
        switch commissioningPhase {
        case let .testing(channel, target):
            return "Commissioning channel \(channel + 1)/32: \(targetDescription(target))"
        case .vegas:
            return "Vegas mode active — use Stop to return all faders to nominal"
        case let .failed(failure):
            return failureDescription(failure)
        case .idle:
            break
        }

        if dawTakeoverEnabled {
            return "DAW Takeover active — CC \(dawControllerBase)–\(dawControllerBase + 31) on MIDI channel \(dawMIDIChannel)"
        }
        if localEchoDetected {
            return "MIDI loopback detected — all outgoing MIDI was disabled"
        }
        if !transmissionEnabled {
            return "Monitor only — all outgoing MIDI is disabled"
        }
        if !nominalLockEnabled {
            return "Nominal Lock is disabled"
        }
        if !nominalVerified {
            return "Calibration must be verified before the lock can activate"
        }

        let activeStates = runtimeStates.prefix(activeBankCount)
        if let missing = activeStates.first(where: { !$0.sourceConnected || !$0.destinationConnected }) {
            return "Waiting for ipMIDI endpoints for bank \(missing.bank + 1)"
        }
        if let offline = activeStates.first(where: { !$0.online }) {
            return "Lock armed; waiting for HUI reply from bank \(offline.bank + 1)"
        }
        if !activeRoutesAreDistinct {
            return "Each bank must use a distinct MIDI input and output"
        }
        return "Nominal Lock active on all \(channelCount) channels"
    }

    var commissioningStatusLine: String {
        switch commissioningPhase {
        case let .testing(channel, target):
            return "Channel \(channel + 1) of 32: waiting for \(targetDescription(target)) report. \(commissioningCompletedChannels) channels have returned to nominal."
        case .vegas:
            return "All 32 channels reported nominal. Vegas wave is running continuously, one channel command at a time."
        case let .failed(failure):
            return failureDescription(failure)
        case .idle:
            if commissioningPassedThisSession {
                return "The full 32-channel exercise passed in this session."
            }
            return "Not running."
        }
    }

    var canApplyNominal: Bool {
        lockIsArmed
            && allActiveBanksOnline
            && activeRoutesAreDistinct
            && runtimeStates.prefix(activeBankCount).allSatisfy { $0.destinationConnected }
    }

    var canTestFirstFader: Bool {
        transmissionEnabled
            && !isCommissioningActive
            && !dawTakeoverEnabled
            && !localEchoDetected
            && runtimeStates.first?.destinationConnected == true
            && runtimeStates.first?.online == true
    }

    var canVerifyNominal: Bool {
        transmissionEnabled
            && !isCommissioningActive
            && !dawTakeoverEnabled
            && !localEchoDetected
            && allActiveBanksOnline
            && activeRoutesAreDistinct
    }

    var canStartCommissioningTest: Bool {
        commissioningBlockReason == nil
    }

    var canEnableDAWTakeover: Bool {
        dawTakeoverBlockReason == nil
    }

    var dawTakeoverBlockReason: String? {
        if dawTakeoverEnabled {
            return nil
        }
        if isCommissioningActive {
            return "Stop the commissioning routine first."
        }
        if channelCount != 32 {
            return "Set the channel count to 32."
        }
        if !transmissionEnabled {
            return "Enable HUI transmission first."
        }
        if localEchoDetected {
            return "Fix the detected MIDI loopback and rescan."
        }
        if !nominalVerified {
            return "Physically verify nominal first."
        }
        if !commissioningPassedThisSession && !automaticTransmissionAuthorized {
            return "Complete the 32-channel commissioning exercise first."
        }
        if !allActiveBanksOnline {
            return "All four HUI banks must be online."
        }
        if !activeRoutesAreDistinct {
            return "Banks 1–4 must use distinct MIDI inputs and outputs."
        }
        if let dawSetupError = midi.dawSetupError {
            return dawSetupError
        }
        return nil
    }

    var commissioningBlockReason: String? {
        if isCommissioningActive {
            return "A commissioning routine is already running."
        }
        if dawTakeoverEnabled {
            return "Exit DAW Takeover before commissioning."
        }
        if channelCount != 32 {
            return "Set the channel count to 32 before running the full-desk test."
        }
        if !transmissionEnabled {
            return "Enable HUI transmission for this session first."
        }
        if localEchoDetected {
            return "Fix the detected MIDI loopback and rescan before testing."
        }
        if !nominalVerified {
            return "Physically verify the nominal 0 dB value first."
        }
        if let missing = runtimeStates.prefix(4).first(where: {
            !$0.sourceConnected || !$0.destinationConnected
        }) {
            return "Bank \(missing.bank + 1) does not have both MIDI endpoints."
        }
        if let offline = runtimeStates.prefix(4).first(where: { !$0.online }) {
            return "Bank \(offline.bank + 1) has not replied to HUI keepalive."
        }
        if !activeRoutesAreDistinct {
            return "Banks 1–4 must use four distinct MIDI inputs and four distinct outputs."
        }
        return nil
    }

    private var allActiveBanksOnline: Bool {
        runtimeStates.prefix(activeBankCount).count == activeBankCount
            && runtimeStates.prefix(activeBankCount).allSatisfy {
                $0.sourceConnected && $0.destinationConnected && $0.online
            }
    }

    private var activeRoutesAreDistinct: Bool {
        let activeRoutes = Array(routes.prefix(activeBankCount))
        let sourceIDs = activeRoutes.compactMap(\.sourceUniqueID)
        let destinationIDs = activeRoutes.compactMap(\.destinationUniqueID)
        return sourceIDs.count == activeBankCount
            && destinationIDs.count == activeBankCount
            && Set(sourceIDs).count == activeBankCount
            && Set(destinationIDs).count == activeBankCount
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        refreshEndpointsAndReconnect()
        keepaliveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard !Task.isCancelled else { break }
                self?.keepaliveTick()
            }
        }
    }

    func enableHUITransmissionForSession() {
        guard !transmissionEnabled else { return }

        localEchoDetected = false
        transmissionEnabled = true
        midi.setTransmissionEnabled(true)
        lastReassertionUptime = ProcessInfo.processInfo.systemUptime
        lastIssue = nil
        refreshEndpointsAndReconnect()
    }

    /// Closes the transport gate before cancelling any work. This intentionally
    /// sends no nominal restoration or cleanup packet.
    func disableAllMIDITransmission() {
        let interruptedTest = isCommissioningActive
        let interruptedDAWTakeover = dawTakeoverEnabled
        midi.setDAWOutputEnabled(false)
        midi.setTransmissionEnabled(false)
        transmissionEnabled = false
        dawTakeoverEnabled = false
        automaticTransmissionAuthorized = false
        defaults.set(false, forKey: DefaultsKey.automaticTransmissionAuthorized)
        cancelCommissioningWithoutRestoration()

        for bank in runtimeStates.indices {
            runtimeStates[bank].online = false
            runtimeStates[bank].lastReplyUptime = nil
        }

        if interruptedTest || interruptedDAWTakeover {
            lastIssue = "Active control was stopped immediately. No restoration command was sent; visually check every fader before reconnecting audio."
        }
    }

    func setDAWMIDIChannel(_ value: Int) {
        guard !dawTakeoverEnabled else { return }
        dawMIDIChannel = min(max(value, 1), 16)
        defaults.set(dawMIDIChannel, forKey: DefaultsKey.dawMIDIChannel)
    }

    func setDAWControllerBase(_ value: Int) {
        guard !dawTakeoverEnabled else { return }
        dawControllerBase = min(max(value, 0), 96)
        defaults.set(dawControllerBase, forKey: DefaultsKey.dawControllerBase)
    }

    func enableDAWTakeover() {
        guard dawTakeoverBlockReason == nil else {
            lastIssue = dawTakeoverBlockReason
            return
        }

        midi.setDAWOutputEnabled(true)
        dawTakeoverEnabled = true
        lastIssue = nil
    }

    func stopDAWTakeoverAndRestoreNominal() {
        guard dawTakeoverEnabled else { return }

        midi.setDAWOutputEnabled(false)
        dawTakeoverEnabled = false
        if restoreAllActiveFadersToNominal() {
            lastIssue = "DAW Takeover ended and CoreMIDI accepted nominal commands for all 32 faders. Visually confirm the desk before reconnecting audio."
        } else {
            lastIssue = "DAW Takeover ended, but nominal restoration was incomplete. Keep audio disconnected and inspect the desk."
        }
    }

    func setAutomaticTransmissionAuthorized(_ enabled: Bool) {
        if enabled, !commissioningPassedThisSession {
            lastIssue = "Automatic HUI transmission can be enabled only after the full 32-channel exercise reaches Vegas mode in this session."
            return
        }

        automaticTransmissionAuthorized = enabled
        defaults.set(enabled, forKey: DefaultsKey.automaticTransmissionAuthorized)
        lastIssue = nil
    }

    func setChannelCount(_ value: Int) {
        guard !isCommissioningActive,
              !dawTakeoverEnabled,
              [8, 16, 24, 32].contains(value),
              value != channelCount else { return }
        invalidateAuthorizationForRouteChange()
        channelCount = value
        defaults.set(value, forKey: DefaultsKey.channelCount)
        refreshEndpointsAndReconnect()
    }

    func setNominalValue(_ value: Int) {
        guard !isCommissioningActive, !dawTakeoverEnabled else { return }
        let clamped = min(max(value, HUI.minimumFaderValue), HUI.maximumFaderValue)
        guard clamped != nominalValue else { return }

        nominalValue = clamped
        nominalVerified = false
        commissioningPassedThisSession = false
        defaults.set(clamped, forKey: DefaultsKey.nominalValue)
        defaults.set(false, forKey: DefaultsKey.nominalVerified)
        if automaticTransmissionAuthorized {
            automaticTransmissionAuthorized = false
            defaults.set(false, forKey: DefaultsKey.automaticTransmissionAuthorized)
            lastIssue = "Changing nominal invalidated automatic HUI authorization. Recommission the desk before enabling it again."
        }
    }

    func setTolerance(_ value: Int) {
        guard !isCommissioningActive, !dawTakeoverEnabled else { return }
        let clamped = min(max(value, 0), 512)
        tolerance = clamped
        defaults.set(clamped, forKey: DefaultsKey.tolerance)
    }

    func setNominalLockEnabled(_ enabled: Bool) {
        guard !hasUnsafeActiveMode else {
            lastIssue = "Nominal Lock cannot be changed while commissioning or DAW Takeover is active."
            return
        }

        nominalLockEnabled = enabled
        defaults.set(enabled, forKey: DefaultsKey.lockEnabled)

        if canApplyNominal {
            applyNominalToAllFaders()
        }
    }

    func verifyNominalAndArm() {
        guard canVerifyNominal else {
            lastIssue = "All configured HUI banks must be online before nominal can be verified and sent to the desk."
            return
        }

        nominalVerified = true
        nominalLockEnabled = true
        defaults.set(true, forKey: DefaultsKey.nominalVerified)
        defaults.set(true, forKey: DefaultsKey.lockEnabled)
        applyNominalToAllFaders()
    }

    func invalidateNominalVerification() {
        guard !hasUnsafeActiveMode else { return }
        nominalVerified = false
        commissioningPassedThisSession = false
        automaticTransmissionAuthorized = false
        defaults.set(false, forKey: DefaultsKey.nominalVerified)
        defaults.set(false, forKey: DefaultsKey.automaticTransmissionAuthorized)
    }

    func useLastObservedAsNominal() {
        guard let lastObservedFader else { return }
        setNominalValue(lastObservedFader.value)
    }

    /// Explicit calibration action. This can affect the analog level on channel 1.
    func testNominalOnFirstFader() {
        guard canTestFirstFader else {
            lastIssue = "Bank 1 must be online with transmission enabled and no MIDI loopback."
            return
        }
        if sendFader(bank: 0, fader: 0, value: nominalValue) {
            lastIssue = nil
        }
    }

    func applyNominalToAllFaders() {
        guard lockIsArmed else {
            lastIssue = "Nominal Lock is not fully armed, so no fader commands were sent."
            return
        }
        guard allActiveBanksOnline else {
            lastIssue = "Every active HUI bank must be online before applying nominal."
            return
        }

        if restoreAllActiveFadersToNominal() {
            lastIssue = nil
        } else if lastIssue == nil {
            lastIssue = "Nominal could not be sent to every configured bank."
        }
    }

    func startFullDeskCommissioningTest() {
        guard commissioningBlockReason == nil else {
            lastIssue = commissioningBlockReason
            return
        }

        var sequence = CommissioningSequence(
            channelCount: 32,
            nominalValue: nominalValue,
            nominalTolerance: tolerance
        )
        let action = sequence.start(at: ProcessInfo.processInfo.systemUptime)
        streamParsers = Array(repeating: MIDIMessageStreamParser(), count: 4)
        huiParsers = Array(repeating: HUIFaderParser(), count: 4)
        recentFaderCommands.removeAll()
        commissioningSequence = sequence
        commissioningPhase = sequence.phase
        commissioningCompletedChannels = 0
        vegasNextChannel = 0
        vegasStartedUptime = nil
        lastIssue = nil

        commissioningTask?.cancel()
        commissioningTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000)
                guard !Task.isCancelled else { break }
                self?.commissioningTick()
            }
        }

        handleCommissioningAction(action)
    }

    /// Normal stop: cancel the producer first, then attempt to return all 32
    /// faders to verified nominal. HUI transmission remains enabled afterward.
    func stopCommissioningAndRestoreNominal() {
        guard isCommissioningActive else { return }

        commissioningTask?.cancel()
        commissioningTask = nil
        commissioningSequence?.stop()
        commissioningSequence = nil
        commissioningPhase = .idle
        commissioningCompletedChannels = 0
        vegasStartedUptime = nil

        if restoreAllActiveFadersToNominal() {
            lastIssue = "CoreMIDI accepted nominal restoration commands for all 32 faders. This does not prove physical movement; visually confirm every fader before reconnecting audio."
        } else {
            lastIssue = "The test stopped, but CoreMIDI did not accept every nominal restoration command. Keep audio disconnected and inspect the desk."
        }
    }

    func selectSource(bank: Int, uniqueID: MIDIUniqueID?) {
        guard !hasUnsafeActiveMode, routes.indices.contains(bank) else { return }
        let endpoint = sources.first { $0.uniqueID == uniqueID }
        invalidateAuthorizationForRouteChange()
        routes[bank].sourceUniqueID = endpoint?.uniqueID
        routes[bank].sourceName = endpoint?.name
        localEchoDetected = false
        saveRoutes()
        refreshEndpointsAndReconnect()
    }

    func selectDestination(bank: Int, uniqueID: MIDIUniqueID?) {
        guard !hasUnsafeActiveMode, routes.indices.contains(bank) else { return }
        let endpoint = destinations.first { $0.uniqueID == uniqueID }
        invalidateAuthorizationForRouteChange()
        routes[bank].destinationUniqueID = endpoint?.uniqueID
        routes[bank].destinationName = endpoint?.name
        localEchoDetected = false
        saveRoutes()
        refreshEndpointsAndReconnect()
    }

    func autoConfigureIPMIDIPorts() {
        guard !hasUnsafeActiveMode else { return }
        invalidateAuthorizationForRouteChange()
        routes = Array(repeating: BankRoute(), count: 4)
        localEchoDetected = false
        saveRoutes()
        refreshEndpointsAndReconnect()
    }

    func rescanEndpoints() {
        guard !hasUnsafeActiveMode else { return }
        localEchoDetected = false
        refreshEndpointsAndReconnect()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }

            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            if enabled, SMAppService.mainApp.status == .requiresApproval {
                lastIssue = "Launch at Login requires approval in System Settings > General > Login Items."
            } else {
                lastIssue = nil
            }
        } catch {
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            lastIssue = "Launch at Login could not be changed: \(error.localizedDescription)"
        }
    }

    func clearLastIssue() {
        lastIssue = nil
    }

    func noteQuitBlockedDuringActiveControl() {
        lastIssue = "Quit was blocked because commissioning or DAW Takeover is active. Use the mode’s normal Stop action to return nominal, or explicitly use Emergency Stop before quitting."
    }

    func endpointName(forSource uniqueID: MIDIUniqueID?) -> String? {
        guard let uniqueID else { return nil }
        return sources.first { $0.uniqueID == uniqueID }?.name
    }

    func endpointName(forDestination uniqueID: MIDIUniqueID?) -> String? {
        guard let uniqueID else { return nil }
        return destinations.first { $0.uniqueID == uniqueID }?.name
    }

    private func handleTopologyChanged() {
        if isCommissioningActive {
            cancelCommissioningWithoutRestoration()
            lastIssue = "CoreMIDI topology changed during commissioning. The routine stopped without sending restoration through a possibly stale route; keep audio disconnected and inspect the faders."
        } else if dawTakeoverEnabled {
            midi.setDAWOutputEnabled(false)
            dawTakeoverEnabled = false
            lastIssue = "CoreMIDI topology changed during DAW Takeover. Takeover stopped without sending restoration through a possibly stale route; keep audio disconnected and inspect the faders."
        }
        scheduleEndpointRefresh()
    }

    private func scheduleEndpointRefresh() {
        refreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.refreshEndpointsAndReconnect()
            }
        }
        refreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    private func refreshEndpointsAndReconnect() {
        let snapshot = midi.endpointSnapshot()
        sources = snapshot.sources
        destinations = snapshot.destinations

        var routeWasUpdated = false
        for bank in 0..<4 {
            guard bank < activeBankCount else {
                let connection = midi.configure(bank: bank, source: nil, destination: nil)
                runtimeStates[bank].sourceConnected = false
                runtimeStates[bank].destinationConnected = false
                runtimeStates[bank].online = false
                runtimeStates[bank].lastReplyUptime = nil
                runtimeStates[bank].connectionGeneration = connection.generation
                continue
            }

            let source = resolveEndpoint(
                uniqueID: routes[bank].sourceUniqueID,
                savedName: routes[bank].sourceName,
                bank: bank,
                candidates: sources
            )
            let destination = resolveEndpoint(
                uniqueID: routes[bank].destinationUniqueID,
                savedName: routes[bank].destinationName,
                bank: bank,
                candidates: destinations
            )

            if let source,
               routes[bank].sourceUniqueID != source.uniqueID
                || routes[bank].sourceName != source.name {
                routes[bank].sourceUniqueID = source.uniqueID
                routes[bank].sourceName = source.name
                routeWasUpdated = true
            }
            if let destination,
               routes[bank].destinationUniqueID != destination.uniqueID
                || routes[bank].destinationName != destination.name {
                routes[bank].destinationUniqueID = destination.uniqueID
                routes[bank].destinationName = destination.name
                routeWasUpdated = true
            }

            let connection = midi.configure(bank: bank, source: source, destination: destination)
            runtimeStates[bank].sourceConnected = connection.sourceConnected
            runtimeStates[bank].destinationConnected = connection.destinationConnected
            runtimeStates[bank].online = false
            runtimeStates[bank].lastReplyUptime = nil
            runtimeStates[bank].connectionGeneration = connection.generation
            streamParsers[bank] = MIDIMessageStreamParser()
            huiParsers[bank] = HUIFaderParser()
        }

        if routeWasUpdated {
            invalidateAuthorizationForRouteChange()
            saveRoutes()
        }

        lastReassertionUptime = ProcessInfo.processInfo.systemUptime
        guard transmissionEnabled else { return }
        for bank in 0..<activeBankCount where runtimeStates[bank].destinationConnected {
            let status = midi.send(HUI.pingRequest.bytes, toBank: bank)
            if let status, status != noErr {
                lastIssue = "Initial HUI keepalive failed for bank \(bank + 1) (OSStatus \(status))."
            }
        }
    }

    private func resolveEndpoint(
        uniqueID: MIDIUniqueID?,
        savedName: String?,
        bank: Int,
        candidates: [MIDIEndpointInfo]
    ) -> MIDIEndpointInfo? {
        if let uniqueID, let exactID = candidates.first(where: { $0.uniqueID == uniqueID }) {
            return exactID
        }
        if let savedName, let exactName = candidates.first(where: { $0.name == savedName }) {
            return exactName
        }

        if let savedName, !savedName.localizedCaseInsensitiveContains("ipmidi") {
            return nil
        }

        let ipMIDICandidates = candidates.filter {
            $0.name.localizedCaseInsensitiveContains("ipmidi")
        }
        let portNumber = bank + 1
        if let namedPort = ipMIDICandidates.first(where: {
            let numberComponents = $0.name.components(separatedBy: CharacterSet.decimalDigits.inverted)
            return numberComponents.contains(String(portNumber))
        }) {
            return namedPort
        }
        if ipMIDICandidates.indices.contains(bank) {
            return ipMIDICandidates[bank]
        }
        return nil
    }

    private func process(event: MIDIIngressEvent) {
        let bank = event.bank
        guard (0..<activeBankCount).contains(bank),
              runtimeStates[bank].connectionGeneration == event.generation else {
            return
        }

        let messages = streamParsers[bank].consume(event.bytes)
        for message in messages {
            if message == HUI.pingRequest {
                localEchoDetected = true
                if isCommissioningActive {
                    abortCommissioning(
                        reason: "Outgoing HUI data appeared on the selected input during commissioning, indicating a MIDI loopback.",
                        attemptNominalRestoration: true
                    )
                } else {
                    lastIssue = "Outgoing HUI ping was received on bank \(bank + 1). Fix the ipMIDI loopback before enabling fader control."
                }
                let loopbackIssue = lastIssue
                disableAllMIDITransmission()
                lastIssue = loopbackIssue
                continue
            }

            let events = huiParsers[bank].consume(message)
            for huiEvent in events {
                switch huiEvent {
                case .pingReply:
                    runtimeStates[bank].lastReplyUptime = event.receivedUptime
                    runtimeStates[bank].online = true
                case let .faderPosition(fader, value):
                    lastObservedFader = ObservedFader(
                        bank: bank,
                        fader: fader,
                        value: value,
                        date: Date()
                    )

                    let channel = bank * 8 + fader
                    if isCommissioningActive {
                        if !isImmediateCommandEcho(
                            channel: channel,
                            value: value,
                            receivedUptime: event.receivedUptime
                        ) {
                            processCommissioningReport(
                                channel: channel,
                                value: value,
                                receivedUptime: event.receivedUptime
                            )
                        }
                    } else if dawTakeoverEnabled {
                        sendDAWPosition(channel: channel, value: value)
                    } else {
                        let policy = NominalLockPolicy(
                            nominalValue: nominalValue,
                            tolerance: tolerance
                        )
                        if let restoreValue = policy.restoreValue(
                            observedValue: value,
                            lockIsArmed: lockIsArmed
                        ) {
                            _ = sendFader(bank: bank, fader: fader, value: restoreValue)
                        }
                    }
                case let .faderTouch(fader, touched):
                    if dawTakeoverEnabled {
                        sendDAWTouch(channel: bank * 8 + fader, touched: touched)
                    }
                }
            }
        }
    }

    private func processCommissioningReport(
        channel: Int,
        value: Int,
        receivedUptime: TimeInterval
    ) {
        guard var sequence = commissioningSequence,
              let action = sequence.observe(
                channel: channel,
                value: value,
                at: receivedUptime
              ) else {
            return
        }

        commissioningSequence = sequence
        commissioningPhase = sequence.phase
        commissioningCompletedChannels = sequence.completedChannelCount
        handleCommissioningAction(action)
    }

    private func commissioningTick() {
        guard isCommissioningActive, transmissionEnabled else {
            commissioningTask?.cancel()
            commissioningTask = nil
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        switch commissioningPhase {
        case .testing:
            guard var sequence = commissioningSequence,
                  let action = sequence.tick(at: now) else {
                return
            }
            commissioningSequence = sequence
            commissioningPhase = sequence.phase
            commissioningCompletedChannels = sequence.completedChannelCount
            handleCommissioningAction(action)
        case .vegas:
            guard allActiveBanksOnline, let vegasStartedUptime else {
                abortCommissioning(
                    reason: "A HUI bank went offline during Vegas mode.",
                    attemptNominalRestoration: true
                )
                return
            }

            let wave = VegasWave(channelCount: 32)
            let channel = vegasNextChannel
            let value = wave.value(channel: channel, elapsed: now - vegasStartedUptime)
            if !sendGlobalFader(channel: channel, value: value) {
                abortCommissioning(
                    reason: "CoreMIDI rejected a Vegas-mode command for channel \(channel + 1).",
                    attemptNominalRestoration: true
                )
                return
            }
            vegasNextChannel = (channel + 1) % 32
        case .idle, .failed:
            commissioningTask?.cancel()
            commissioningTask = nil
        }
    }

    private func handleCommissioningAction(_ action: CommissioningSequenceAction) {
        switch action {
        case let .send(channel, value):
            guard sendGlobalFader(channel: channel, value: value) else {
                abortCommissioning(
                    reason: "CoreMIDI rejected the exercise command for channel \(channel + 1).",
                    attemptNominalRestoration: true
                )
                return
            }
        case .enterVegas:
            commissioningPassedThisSession = true
            vegasStartedUptime = ProcessInfo.processInfo.systemUptime
            vegasNextChannel = 0
        case let .failed(failure):
            abortCommissioning(
                reason: failureDescription(failure),
                attemptNominalRestoration: true
            )
        }
    }

    private func abortCommissioning(
        reason: String,
        attemptNominalRestoration: Bool
    ) {
        commissioningTask?.cancel()
        commissioningTask = nil
        commissioningSequence?.stop()
        commissioningSequence = nil
        commissioningPhase = .idle
        commissioningCompletedChannels = 0
        vegasStartedUptime = nil

        if attemptNominalRestoration, transmissionEnabled, nominalVerified {
            if restoreAllActiveFadersToNominal() {
                lastIssue = "\(reason) CoreMIDI accepted a nominal restoration for all 32 faders; visually verify the desk before reconnecting audio."
            } else {
                lastIssue = "\(reason) Nominal restoration was incomplete; keep audio disconnected and inspect the desk."
            }
        } else {
            lastIssue = "\(reason) No nominal restoration was sent; keep audio disconnected and inspect the desk."
        }
    }

    private func cancelCommissioningWithoutRestoration() {
        commissioningTask?.cancel()
        commissioningTask = nil
        commissioningSequence?.stop()
        commissioningSequence = nil
        commissioningPhase = .idle
        commissioningCompletedChannels = 0
        vegasStartedUptime = nil
    }

    private func isImmediateCommandEcho(
        channel: Int,
        value: Int,
        receivedUptime: TimeInterval
    ) -> Bool {
        guard let command = recentFaderCommands[channel],
              command.value == value,
              receivedUptime >= command.sentUptime else {
            return false
        }
        return receivedUptime - command.sentUptime < 0.05
    }

    private func keepaliveTick() {
        let now = ProcessInfo.processInfo.systemUptime

        guard transmissionEnabled else {
            for bank in 0..<activeBankCount {
                runtimeStates[bank].online = false
                runtimeStates[bank].lastReplyUptime = nil
            }
            return
        }

        for bank in 0..<activeBankCount {
            if runtimeStates[bank].destinationConnected {
                let status = midi.send(HUI.pingRequest.bytes, toBank: bank)
                if let status, status != noErr {
                    lastIssue = "HUI keepalive failed for bank \(bank + 1) (OSStatus \(status))."
                }
            }

            if let lastReply = runtimeStates[bank].lastReplyUptime {
                runtimeStates[bank].online = now - lastReply < 2.5
            } else {
                runtimeStates[bank].online = false
            }
        }

        if isCommissioningActive, !allActiveBanksOnline {
            abortCommissioning(
                reason: "A HUI bank stopped replying during commissioning.",
                attemptNominalRestoration: true
            )
            return
        }

        if dawTakeoverEnabled, !allActiveBanksOnline {
            midi.setDAWOutputEnabled(false)
            dawTakeoverEnabled = false
            lastIssue = "A HUI bank stopped replying, so DAW Takeover was stopped. No restoration was sent through the unverified connection; inspect the desk."
            return
        }

        if lockIsArmed, allActiveBanksOnline, now - lastReassertionUptime >= 5 {
            applyNominalToAllFaders()
        }
    }

    private func sendDAWPosition(channel: Int, value: Int) {
        let mapping = DAWTakeoverMapping(
            midiChannel: dawMIDIChannel - 1,
            controllerBase: dawControllerBase
        )
        guard let message = try? mapping.positionMessage(fader: channel, value: value),
              let status = midi.sendToDAW([message.bytes]),
              status == noErr else {
            lastIssue = "Could not publish channel \(channel + 1) to the DAW virtual MIDI input."
            return
        }
    }

    private func sendDAWTouch(channel: Int, touched: Bool) {
        let mapping = DAWTakeoverMapping(
            midiChannel: dawMIDIChannel - 1,
            controllerBase: dawControllerBase
        )
        guard let message = try? mapping.touchMessage(fader: channel, touched: touched),
              let status = midi.sendToDAW([message.bytes]),
              status == noErr else {
            lastIssue = "Could not publish channel \(channel + 1) touch state to the DAW virtual MIDI input."
            return
        }
    }

    private func restoreAllActiveFadersToNominal() -> Bool {
        guard transmissionEnabled, nominalVerified else { return false }

        var allMessagesSent = true
        for bank in 0..<activeBankCount {
            guard runtimeStates[bank].destinationConnected else {
                allMessagesSent = false
                continue
            }
            for fader in 0..<8 {
                if !sendFader(bank: bank, fader: fader, value: nominalValue) {
                    allMessagesSent = false
                }
            }
        }

        if allMessagesSent {
            lastReassertionUptime = ProcessInfo.processInfo.systemUptime
        }
        return allMessagesSent
    }

    @discardableResult
    private func sendGlobalFader(channel: Int, value: Int) -> Bool {
        guard (0..<channelCount).contains(channel) else {
            lastIssue = "Invalid global fader channel \(channel + 1)."
            return false
        }
        return sendFader(bank: channel / 8, fader: channel % 8, value: value)
    }

    @discardableResult
    private func sendFader(bank: Int, fader: Int, value: Int) -> Bool {
        guard transmissionEnabled else {
            lastIssue = "Outgoing MIDI is disabled."
            return false
        }
        guard runtimeStates.indices.contains(bank), runtimeStates[bank].destinationConnected else {
            lastIssue = "Bank \(bank + 1) has no connected MIDI destination."
            return false
        }
        guard let messages = try? HUI.faderPosition(fader: fader, value: value) else {
            lastIssue = "Invalid HUI fader command for bank \(bank + 1), fader \(fader + 1)."
            return false
        }

        let sentUptime = ProcessInfo.processInfo.systemUptime
        guard let status = midi.send(messages.map(\.bytes), toBank: bank), status == noErr else {
            lastIssue = "Could not send to bank \(bank + 1), fader \(fader + 1)."
            return false
        }

        recentFaderCommands[bank * 8 + fader] = OutboundFaderCommand(
            value: value,
            sentUptime: sentUptime
        )
        return true
    }

    private func invalidateAuthorizationForRouteChange() {
        guard commissioningPassedThisSession || automaticTransmissionAuthorized else { return }

        commissioningPassedThisSession = false
        automaticTransmissionAuthorized = false
        defaults.set(false, forKey: DefaultsKey.automaticTransmissionAuthorized)
        midi.setDAWOutputEnabled(false)
        midi.setTransmissionEnabled(false)
        transmissionEnabled = false
        dawTakeoverEnabled = false
        for bank in runtimeStates.indices {
            runtimeStates[bank].online = false
            runtimeStates[bank].lastReplyUptime = nil
        }
        lastIssue = "The MIDI routing changed, so commissioning authorization was revoked and all outgoing MIDI was disabled. Re-test the new route before authorizing startup transmission."
    }

    private func targetDescription(_ target: FaderExerciseTarget) -> String {
        switch target {
        case .maximum:
            return "maximum"
        case .minimum:
            return "minimum (−∞)"
        case .nominal:
            return "verified nominal"
        }
    }

    private func failureDescription(_ failure: CommissioningSequenceFailure) -> String {
        switch failure {
        case let .timedOut(channel, target):
            return "Channel \(channel + 1) did not report \(targetDescription(target)) before the 8-second timeout."
        }
    }

    private func saveRoutes() {
        if let data = try? JSONEncoder().encode(routes) {
            defaults.set(data, forKey: DefaultsKey.routes)
        }
    }
}
