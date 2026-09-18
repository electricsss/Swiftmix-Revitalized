import AppKit
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
    var lastActivityUptime: TimeInterval?
    var connectionGeneration: UInt = 0

    var id: Int { bank }
}

struct StoredFaderScene: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    let positions: [Int]
    let createdAt: Date
}

enum FaderLevelPreset: Int, CaseIterable, Identifiable {
    case zero = 0
    case minus5 = -5
    case minus10 = -10
    case minus15 = -15
    case minus20 = -20

    var id: Int { rawValue }

    var displayName: String {
        rawValue == 0 ? "0 dB" : "\(rawValue) dB"
    }
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
    @Published private(set) var ethernetServices: [EthernetNetworkService]
    @Published private(set) var selectedEthernetServiceID: String?
    @Published private(set) var selectedEthernetServiceName: String?
    @Published private(set) var selectedEthernetBSDName: String?
    @Published private(set) var routes: [BankRoute]
    @Published private(set) var runtimeStates: [BankRuntimeState]
    @Published private(set) var lastObservedFader: ObservedFader?
    @Published private(set) var scenes: [StoredFaderScene]
    @Published private(set) var activeSceneID: UUID?
    @Published private(set) var sceneCaptureEnabled = false
    @Published private(set) var calibratedFaderLevels: [Int: Int]
    @Published private(set) var activeFaderLevel: FaderLevelPreset?

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
    @Published private(set) var dawTakeoverProfile: DAWTakeoverProfile
    @Published private(set) var dawBankSelection: DAWBankSelection
    @Published private(set) var dawCloseGraceSecondsRemaining: Int?
    @Published private(set) var dawFadersResting = false
    @Published private(set) var dawCloseOverrideActive = false
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
        static let selectedEthernetServiceID = "selectedEthernetNetworkServiceID"
        static let selectedEthernetServiceName = "selectedEthernetNetworkServiceName"
        static let selectedEthernetBSDName = "selectedEthernetBSDInterfaceName"
        static let dawMIDIChannel = "dawTakeoverMIDIChannel"
        static let dawControllerBase = "dawTakeoverControllerBase"
        static let dawTakeoverProfile = "dawTakeoverProfile"
        static let dawBankSelection = "dawBankSelection"
        static let legacyLogicHUIBankSelection = "logicHUIBankSelection"
        static let scenes = "storedFaderScenes"
        static let calibratedFaderLevels = "calibratedFaderLevels"
    }

    private let defaults: UserDefaults
    private let midi: CoreMIDIService
    private let ethernetMonitor: EthernetNetworkServiceMonitor
    private var streamParsers = Array(repeating: MIDIMessageStreamParser(), count: 4)
    private var huiParsers = Array(repeating: HUIFaderParser(), count: 4)
    private var bankLastActivityUptimes = Array<TimeInterval?>(repeating: nil, count: 4)
    private var keepaliveTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var dawCloseDeadlineUptime: TimeInterval?
    private enum DeskExerciseStage {
        case maximum
        case low
        case nominal
    }

    private var commissioningTask: Task<Void, Never>?
    private var commissioningSequence: CommissioningSequence?
    private var deskExerciseStage: DeskExerciseStage?
    private var deskExerciseStageStartedUptime: TimeInterval?
    private var recentFaderCommands: [Int: OutboundFaderCommand] = [:]
    private var touchedChannels = Set<Int>()
    private var sceneCapturePositions: [Int]?
    private var commandedBankValues = Array(
        repeating: Array(repeating: HUI.defaultNominalValue, count: 8),
        count: 4
    )
    private var vegasNextChannel = 0
    private var vegasStartedUptime: TimeInterval?
    private var vegasEndsUptime: TimeInterval?
    private var vegasLightsAreOn = false
    private var vegasLastLightChangeUptime = -Double.infinity
    // Dynamic-store callbacks request immediate full refreshes. While traffic is
    // active, service identity and HUI keepalive are refreshed every 300 ms,
    // matching the cadence observed in the successful Logic-compatible stream.
    private static let keepaliveIntervalNanoseconds: UInt64 = 300_000_000
    private static let huiActivityTimeout: TimeInterval = 2.5
    private static let candidateTestActivityTimeout: TimeInterval = 15
    private static let directEthernetValidationInterval: TimeInterval = 0.1
    private static let nominalReassertionInterval: TimeInterval = 5 * 60
    private static let deskExerciseStageDuration: TimeInterval = 3
    private static let deskExerciseLowValue = 300
    private static let vegasDuration: TimeInterval = 60
    private static let vegasLightInterval: TimeInterval = 0.25
    private static let dawCloseGraceDuration: TimeInterval = 15

    private var lastReassertionUptime = -Double.infinity
    private var lastDirectEthernetValidationUptime = -Double.infinity
    private var refreshWorkItem: DispatchWorkItem?
    private var hasStarted = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let ethernetMonitor = EthernetNetworkServiceMonitor()
        let initialEthernetServices = ethernetMonitor.services()
        let savedEthernetServiceID = defaults.string(forKey: DefaultsKey.selectedEthernetServiceID)
        let savedEthernetBSDName = defaults.string(forKey: DefaultsKey.selectedEthernetBSDName)
        self.ethernetMonitor = ethernetMonitor
        ethernetServices = initialEthernetServices
        selectedEthernetServiceID = savedEthernetServiceID
        selectedEthernetServiceName = defaults.string(forKey: DefaultsKey.selectedEthernetServiceName)
        selectedEthernetBSDName = savedEthernetBSDName

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

        // Nominal Lock is deliberately session-only. Every launch starts
        // inactive so no lock correction or nominal push occurs until the user
        // explicitly chooses to enable it for the current session.
        nominalLockEnabled = false
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
        let selectedService = savedEthernetServiceID.flatMap { selectedID in
            initialEthernetServices.first(where: { $0.id == selectedID })
        }
        let selectedServiceIdentityMatches = savedEthernetBSDName.map { savedBSDName in
            selectedService?.bsdName == savedBSDName
        } == true
        let selectedServiceCanOpenTransmission = selectedServiceIdentityMatches
            && selectedService?.isActive == true
        transmissionEnabled = savedAutomaticTransmissionAuthorization
            && selectedServiceCanOpenTransmission
        dawMIDIChannel = defaults.object(forKey: DefaultsKey.dawMIDIChannel) == nil
            ? 1
            : min(max(defaults.integer(forKey: DefaultsKey.dawMIDIChannel), 1), 16)
        dawControllerBase = defaults.object(forKey: DefaultsKey.dawControllerBase) == nil
            ? 16
            : min(max(defaults.integer(forKey: DefaultsKey.dawControllerBase), 0), 96)
        dawTakeoverProfile = defaults.string(forKey: DefaultsKey.dawTakeoverProfile)
            .flatMap(DAWTakeoverProfile.init(rawValue:)) ?? .genericLinear
        let savedDAWBankSelection = defaults.string(forKey: DefaultsKey.dawBankSelection)
            ?? defaults.string(forKey: DefaultsKey.legacyLogicHUIBankSelection)
        dawBankSelection = savedDAWBankSelection.flatMap(DAWBankSelection.init(rawValue:)) ?? .all
        dawCloseGraceSecondsRemaining = nil
        if let sceneData = defaults.data(forKey: DefaultsKey.scenes),
           let decodedScenes = try? JSONDecoder().decode([StoredFaderScene].self, from: sceneData) {
            scenes = decodedScenes.filter { scene in
                scene.positions.count == 32
                    && scene.positions.allSatisfy {
                        (HUI.minimumFaderValue...HUI.maximumFaderValue).contains($0)
                    }
            }
        } else {
            scenes = []
        }
        activeSceneID = nil
        activeFaderLevel = nil
        let savedFaderLevels = defaults.dictionary(forKey: DefaultsKey.calibratedFaderLevels)
            as? [String: Int] ?? [:]
        calibratedFaderLevels = Dictionary(uniqueKeysWithValues: savedFaderLevels.compactMap { key, value in
            guard let decibels = Int(key),
                  FaderLevelPreset(rawValue: decibels) != nil,
                  decibels != 0,
                  (HUI.minimumFaderValue...HUI.maximumFaderValue).contains(value) else {
                return nil
            }
            return (decibels, value)
        })
        runtimeStates = (0..<4).map { BankRuntimeState(bank: $0) }
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled

        midi = CoreMIDIService()
        midi.configureNativeEthernet(interfaceBSDName: selectedService?.bsdName)
        commandedBankValues = Array(
            repeating: Array(repeating: nominalValue, count: 8),
            count: 4
        )
        midi.setTransmissionEnabled(transmissionEnabled)
        if let setupError = midi.setupError {
            lastIssue = setupError
        } else if let dawSetupError = midi.dawSetupError {
            lastIssue = dawSetupError
        } else if savedAutomaticTransmissionAuthorization, !selectedServiceCanOpenTransmission {
            if let savedEthernetBSDName,
               let currentBSDName = selectedService?.bsdName,
               currentBSDName != savedEthernetBSDName {
                lastIssue = "Saved automatic transmission authorization was not used because the selected service ID now resolves to \(currentBSDName), not the authorized \(savedEthernetBSDName). This session remains monitor only."
            } else if savedEthernetBSDName == nil, selectedService != nil {
                lastIssue = "Saved automatic transmission authorization was not used because this installation has no persisted BSD identity for the selected service. The current identity must be recorded before transmission can be enabled."
            } else {
                lastIssue = "Saved automatic transmission authorization was not used because the exact selected Ethernet service and BSD interface are unavailable or inactive. This session remains monitor only until you explicitly enable transmission."
            }
        }

        midi.onBytes = { [weak self] event in
            DispatchQueue.main.async {
                self?.process(event: event)
            }
        }
        midi.onTopologyChanged = { [weak self] in
            self?.handleTopologyChanged()
        }
        ethernetMonitor.onChange = { [weak self] in
            Task { @MainActor in
                self?.handleEthernetConfigurationChanged()
            }
        }
        ethernetMonitor.startMonitoring()
    }

    deinit {
        midi.setTransmissionEnabled(false)
        keepaliveTask?.cancel()
        commissioningTask?.cancel()
        refreshWorkItem?.cancel()
        let notificationCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            notificationCenter.removeObserver(observer)
        }
    }

    var activeBankCount: Int {
        channelCount / 8
    }

    var selectedEthernetService: EthernetNetworkService? {
        guard let selectedEthernetServiceID else { return nil }
        return ethernetServices.first { $0.id == selectedEthernetServiceID }
    }

    var selectedEthernetServiceStatusLine: String {
        if let service = selectedEthernetService {
            let activity = service.isActive ? "active" : "inactive"
            let addresses = service.ipv4Addresses.isEmpty
                ? "no IPv4 address"
                : "IPv4: \(service.ipv4Addresses.joined(separator: ", "))"
            let identity = selectedEthernetBSDName.map { savedBSDName in
                savedBSDName == service.bsdName
                    ? ""
                    : " · authorized BSD was \(savedBSDName)"
            } ?? " · BSD identity not yet recorded"
            return "\(service.displayName) · \(service.bsdName)\(identity) · \(activity) · \(addresses)"
        }

        if selectedEthernetServiceID != nil {
            let savedName = selectedEthernetServiceName ?? "Saved Ethernet service"
            let savedBSD = selectedEthernetBSDName.map { " · \($0)" } ?? ""
            return "\(savedName)\(savedBSD) · unavailable (the saved service ID was not found)"
        }

        return "Select an Ethernet service"
    }

    var canEnableHUITransmission: Bool {
        huiTransmissionBlockerText == nil
    }

    var huiTransmissionBlockerText: String? {
        guard selectedEthernetServiceID != nil else {
            return "Select an Ethernet service before enabling HUI transmission."
        }
        guard let service = selectedEthernetService else {
            return "The exact selected Ethernet service is unavailable. Rescan or explicitly choose a service; the app will not substitute another interface."
        }
        guard let selectedEthernetBSDName else {
            return "The selected service has no recorded BSD interface identity. Rescan to record it; automatic transmission remains blocked during this migration."
        }
        guard service.bsdName == selectedEthernetBSDName else {
            return "The selected service ID now resolves to \(service.bsdName), not the authorized \(selectedEthernetBSDName). Transmission authorization has been revoked."
        }
        guard service.isActive else {
            return "The selected Ethernet service '\(service.displayName)' (\(service.bsdName)) is inactive. Connect and enable it, then rescan."
        }
        if let setupError = midi.setupError {
            return setupError
        }
        return nil
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
        isCommissioningActive || dawTakeoverEnabled || sceneCaptureEnabled
    }

    var activeScene: StoredFaderScene? {
        guard let activeSceneID else { return nil }
        return scenes.first { $0.id == activeSceneID }
    }

    var canManageScenes: Bool {
        transmissionEnabled
            && !isCommissioningActive
            && !dawTakeoverEnabled
            && !localEchoDetected
            && allActiveBanksOnline
            && activeBankCount == 4
            && nominalVerified
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
    /// every active bank has sent recent valid HUI traffic. Test modes remain dim.
    var menuBarIconIsActive: Bool {
        lockIsArmed
            && runtimeStates.prefix(activeBankCount).count == activeBankCount
            && runtimeStates.prefix(activeBankCount).allSatisfy { $0.online }
    }

    var statusLine: String {
        if let ethernetBlocker = huiTransmissionBlockerText {
            return "Ethernet safety interlock: \(ethernetBlocker)"
        }

        switch commissioningPhase {
        case let .testing(_, target):
            return "Full-desk exercise: \(targetDescription(target))"
        case .vegas:
            return "Vegas mode active for one minute — use Stop to return all faders to nominal"
        case let .failed(failure):
            return failureDescription(failure)
        case .idle:
            break
        }

        if sceneCaptureEnabled {
            return "Scene capture unlocked — move faders, then name and save the scene"
        }
        if dawTakeoverEnabled {
            if dawFadersResting {
                return "DAW closed — selected SwiftMix banks are resting with transmission suspended"
            }
            if let seconds = dawCloseGraceSecondsRemaining {
                return "DAW closed — SwiftMix banks will rest in \(seconds) seconds unless overridden"
            }
            if dawCloseOverrideActive {
                return "DAW closed — engineer override is keeping the HUI bridge active"
            }
            switch dawTakeoverProfile {
            case .logicProHUI:
                return "Logic Pro HUI Bridge active: \(dawBankSelection.displayName)"
            case .proToolsHUI:
                return "Pro Tools HUI Bridge active: \(dawBankSelection.displayName)"
            case .genericLinear, .abletonLive:
                return "DAW Takeover active: \(dawBankSelection.displayName) — CC \(dawControllerBase)–\(dawControllerBase + 31) on MIDI channel \(dawMIDIChannel)"
            }
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
            return "Waiting for SwiftMix Ethernet ports for bank \(missing.bank + 1)"
        }
        if let offline = activeStates.first(where: { !$0.online }) {
            return "Lock armed; waiting for HUI activity from bank \(offline.bank + 1)"
        }
        if !activeRoutesAreDistinct {
            return "Each bank must use a distinct MIDI input and output"
        }
        if let activeScene {
            return "Scene Lock active: \(activeScene.name)"
        }
        if let activeFaderLevel, activeFaderLevel != .zero {
            return "Fader level lock active at \(activeFaderLevel.displayName) on all \(channelCount) channels"
        }
        return "Nominal Lock active on all \(channelCount) channels"
    }

    var commissioningStatusLine: String {
        switch commissioningPhase {
        case let .testing(_, target):
            return "All 32 faders: \(targetDescription(target)). Watch the desk and keep hands clear."
        case .vegas:
            return "Vegas mode is running a one-minute fader wave and flashing all channel-strip lights."
        case let .failed(failure):
            return failureDescription(failure)
        case .idle:
            if commissioningPassedThisSession {
                return "The full 32-channel exercise passed in this session."
            }
            return "Not running."
        }
    }

    var canSetFaderLevel: Bool {
        transmissionEnabled
            && nominalVerified
            && !localEchoDetected
            && !isCommissioningActive
            && !dawTakeoverEnabled
            && !sceneCaptureEnabled
            && allActiveBanksOnline
            && activeRoutesAreDistinct
            && runtimeStates.prefix(activeBankCount).allSatisfy { $0.destinationConnected }
    }

    var canApplyNominal: Bool {
        lockIsArmed
            && allActiveBanksOnline
            && activeRoutesAreDistinct
            && runtimeStates.prefix(activeBankCount).allSatisfy { $0.destinationConnected }
    }

    var canTestFirstFader: Bool {
        testCandidateBlockReason == nil
    }

    var testCandidateBlockReason: String? {
        if isCommissioningActive {
            return "Stop the commissioning routine first."
        }
        if sceneCaptureEnabled {
            return "Save or cancel the scene capture first."
        }
        if dawTakeoverEnabled {
            return "Exit DAW Takeover first."
        }
        if !transmissionEnabled {
            return "Enable HUI transmission for this session first."
        }
        if localEchoDetected {
            return "Fix the detected MIDI loopback and rescan."
        }
        guard let bank = runtimeStates.first,
              bank.sourceConnected,
              bank.destinationConnected else {
            return "Bank 1 requires both MIDI input and output endpoints."
        }
        guard let lastActivity = bankLastActivityUptimes[0],
              ProcessInfo.processInfo.systemUptime - lastActivity
                < Self.candidateTestActivityTimeout else {
            return "Move or touch a fader in Bank 1 (channels 1–8), then start the test within 15 seconds."
        }
        return nil
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
        if let unavailable = dawBankSelection.bankIndices.first(where: {
            !runtimeStates[$0].sourceConnected
                || !runtimeStates[$0].destinationConnected
                || !runtimeStates[$0].online
        }) {
            return "Selected DAW Bank \(unavailable + 1) must be online."
        }
        if !routesAreDistinct(banks: dawBankSelection.bankIndices) {
            return "Selected DAW banks must use distinct MIDI inputs and outputs."
        }
        if dawTakeoverProfile.usesBidirectionalHUIBridge,
           let dawSetupError = midi.dawSetupError {
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
        if sceneCaptureEnabled {
            return "Save or cancel the scene capture before commissioning."
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
            return "Bank \(offline.bank + 1) has not sent valid HUI activity recently."
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
        routesAreDistinct(banks: Array(0..<activeBankCount))
    }

    private func routesAreDistinct(banks: [Int]) -> Bool {
        let activeRoutes = banks.compactMap { routes.indices.contains($0) ? routes[$0] : nil }
        let sourceIDs = activeRoutes.compactMap(\.sourceUniqueID)
        let destinationIDs = activeRoutes.compactMap(\.destinationUniqueID)
        return sourceIDs.count == banks.count
            && destinationIDs.count == banks.count
            && Set(sourceIDs).count == banks.count
            && Set(destinationIDs).count == banks.count
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        installDAWLifecycleObservers()

        refreshEthernetServices(enforceSafetyInterlock: true)
        refreshEndpointsAndReconnect(ethernetAlreadyValidated: true)
        keepaliveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.keepaliveIntervalNanoseconds)
                guard !Task.isCancelled else { break }
                self?.keepaliveTick()
            }
        }
    }

    private func installDAWLifecycleObservers() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            Task { @MainActor in
                self?.handleDAWTerminated(application)
            }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            Task { @MainActor in
                self?.handleDAWLaunched(application)
            }
        })
    }

    private func applicationMatchesSelectedDAW(_ application: NSRunningApplication) -> Bool {
        let bundleIdentifier = application.bundleIdentifier?.lowercased() ?? ""
        let name = application.localizedName?.lowercased() ?? ""
        switch dawTakeoverProfile {
        case .logicProHUI:
            return bundleIdentifier == "com.apple.logic10" || name == "logic pro"
        case .proToolsHUI:
            return bundleIdentifier == "com.avid.protools" || name == "pro tools"
        case .abletonLive:
            return bundleIdentifier.hasPrefix("com.ableton.live") || name.hasPrefix("ableton live")
        case .genericLinear:
            return false
        }
    }

    private func handleDAWTerminated(_ application: NSRunningApplication) {
        guard dawTakeoverEnabled,
              dawTakeoverProfile.usesBidirectionalHUIBridge,
              applicationMatchesSelectedDAW(application) else { return }
        dawCloseOverrideActive = false
        dawFadersResting = false
        dawCloseGraceSecondsRemaining = Int(Self.dawCloseGraceDuration)
        dawCloseDeadlineUptime = ProcessInfo.processInfo.systemUptime
            + Self.dawCloseGraceDuration
    }

    private func handleDAWLaunched(_ application: NSRunningApplication) {
        guard dawTakeoverEnabled,
              applicationMatchesSelectedDAW(application) else { return }
        midi.setTransmissionSuspended(false, banks: dawBankSelection.bankIndices)
        dawCloseDeadlineUptime = nil
        dawCloseGraceSecondsRemaining = nil
        dawFadersResting = false
        dawCloseOverrideActive = false
        lastIssue = nil
    }

    func overrideDAWCloseRest() {
        guard dawTakeoverEnabled, dawCloseGraceSecondsRemaining != nil else { return }
        midi.setTransmissionSuspended(false, banks: dawBankSelection.bankIndices)
        dawCloseDeadlineUptime = nil
        dawCloseGraceSecondsRemaining = nil
        dawFadersResting = false
        dawCloseOverrideActive = true
        lastIssue = nil
    }

    private func clearDAWCloseState(resumeTransmission: Bool) {
        if resumeTransmission {
            midi.setTransmissionSuspended(false, banks: dawBankSelection.bankIndices)
        }
        dawCloseDeadlineUptime = nil
        dawCloseGraceSecondsRemaining = nil
        dawFadersResting = false
        dawCloseOverrideActive = false
    }

    func enableHUITransmissionForSession() {
        guard !transmissionEnabled else { return }

        guard refreshEthernetServices(enforceSafetyInterlock: false) else { return }
        guard canEnableHUITransmission else {
            lastIssue = huiTransmissionBlockerText
            return
        }

        localEchoDetected = false
        transmissionEnabled = true
        midi.setTransmissionEnabled(true)
        lastReassertionUptime = ProcessInfo.processInfo.systemUptime
        lastIssue = nil
        refreshEndpointsAndReconnect(ethernetAlreadyValidated: true)
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
        clearDAWCloseState(resumeTransmission: false)
        automaticTransmissionAuthorized = false
        defaults.set(false, forKey: DefaultsKey.automaticTransmissionAuthorized)
        cancelCommissioningWithoutRestoration()
        sceneCaptureEnabled = false
        sceneCapturePositions = nil

        for bank in runtimeStates.indices {
            bankLastActivityUptimes[bank] = nil
            runtimeStates[bank].online = false
            runtimeStates[bank].lastActivityUptime = nil
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

    func setDAWTakeoverProfile(_ profile: DAWTakeoverProfile) {
        guard !dawTakeoverEnabled else { return }
        midi.deactivateHUIBridge()
        dawTakeoverProfile = profile
        defaults.set(profile.rawValue, forKey: DefaultsKey.dawTakeoverProfile)
    }

    func setDAWBankSelection(_ selection: DAWBankSelection) {
        guard !dawTakeoverEnabled else { return }
        midi.deactivateHUIBridge()
        dawBankSelection = selection
        defaults.set(selection.rawValue, forKey: DefaultsKey.dawBankSelection)
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

        if dawTakeoverProfile.usesBidirectionalHUIBridge {
            let bridgeDAW: HUIBridgeDAW = dawTakeoverProfile == .proToolsHUI
                ? .proTools
                : .logicPro
            guard midi.activateHUIBridge(banks: dawBankSelection.bankIndices, daw: bridgeDAW) else {
                lastIssue = midi.dawSetupError ?? "Could not create the selected HUI bridge port pairs."
                return
            }
        }
        midi.setTransmissionSuspended(false, banks: dawBankSelection.bankIndices)
        midi.setDAWOutputEnabled(true)
        dawTakeoverEnabled = true
        clearDAWCloseState(resumeTransmission: true)
        lastIssue = nil
    }

    func stopDAWTakeoverAndRestoreNominal() {
        guard dawTakeoverEnabled else { return }

        let banksToRestore = dawBankSelection.bankIndices
        clearDAWCloseState(resumeTransmission: true)
        midi.setDAWOutputEnabled(false)
        dawTakeoverEnabled = false
        let restoredNominal = restoreBanksToNominal(banksToRestore)
        guard transmissionEnabled else { return }
        if restoredNominal {
            let restoredChannels = banksToRestore.count * 8
            lastIssue = "DAW Takeover ended and the active transport accepted nominal commands for \(restoredChannels) selected faders. Visually confirm the desk before reconnecting audio."
        } else {
            lastIssue = "DAW Takeover ended, but nominal restoration was incomplete. Keep audio disconnected and inspect the desk."
        }
    }

    func setAutomaticTransmissionAuthorized(_ enabled: Bool) {
        if enabled {
            guard refreshEthernetServices(enforceSafetyInterlock: true) else { return }
            guard commissioningPassedThisSession else {
                lastIssue = "Automatic HUI transmission can be enabled only after the full-desk maximum, low, and nominal exercise completes in this session."
                return
            }
            guard canEnableHUITransmission else {
                lastIssue = huiTransmissionBlockerText
                return
            }
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
        commandedBankValues = Array(
            repeating: Array(repeating: clamped, count: 8),
            count: 4
        )
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

    func beginSceneCapture() {
        guard canManageScenes else {
            lastIssue = "All four native banks must be online with transmission enabled before capturing a scene."
            return
        }
        nominalLockEnabled = false
        defaults.set(false, forKey: DefaultsKey.lockEnabled)
        activeSceneID = nil
        activeFaderLevel = nil
        sceneCapturePositions = commandedBankValues.flatMap { $0 }
        sceneCaptureEnabled = true
        lastIssue = "Scene capture is unlocked. Move the desired faders, enter a name, then save the scene."
    }

    func cancelSceneCapture() {
        guard sceneCaptureEnabled else { return }
        sceneCaptureEnabled = false
        sceneCapturePositions = nil
        lastIssue = nil
    }

    func saveCapturedScene(name: String) {
        guard sceneCaptureEnabled, let positions = sceneCapturePositions else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            lastIssue = "Enter a name before saving the scene."
            return
        }
        let scene = StoredFaderScene(
            id: UUID(),
            name: trimmedName,
            positions: positions,
            createdAt: Date()
        )
        scenes.append(scene)
        scenes.sort { $0.createdAt < $1.createdAt }
        persistScenes()
        sceneCaptureEnabled = false
        sceneCapturePositions = nil
        lastIssue = "Saved scene ‘\(scene.name)’. Faders remain unlocked until you recall a scene or enable Nominal Lock."
    }

    func recallScene(id: UUID) {
        guard canManageScenes,
              let scene = scenes.first(where: { $0.id == id }) else {
            lastIssue = "The scene cannot be recalled until all four banks are online and idle."
            return
        }
        sceneCaptureEnabled = false
        sceneCapturePositions = nil
        for bank in 0..<4 {
            commandedBankValues[bank] = Array(scene.positions[(bank * 8)..<((bank + 1) * 8)])
            guard sendBankSnapshot(bank: bank) else {
                lastIssue = "Scene recall stopped because Bank \(bank + 1) rejected its snapshot. Keep audio isolated and inspect the desk."
                return
            }
        }
        activeSceneID = scene.id
        activeFaderLevel = nil
        nominalLockEnabled = true
        defaults.set(true, forKey: DefaultsKey.lockEnabled)
        lastReassertionUptime = ProcessInfo.processInfo.systemUptime
        lastIssue = "Recalled and locked scene ‘\(scene.name)’."
    }

    func deleteScene(id: UUID) {
        guard !isCommissioningActive, !dawTakeoverEnabled else { return }
        scenes.removeAll { $0.id == id }
        if activeSceneID == id {
            activeSceneID = nil
            nominalLockEnabled = false
        }
        persistScenes()
    }

    func setNominalLockEnabled(_ enabled: Bool) {
        guard !hasUnsafeActiveMode else {
            lastIssue = "Nominal Lock cannot be changed while commissioning or DAW Takeover is active."
            return
        }

        nominalLockEnabled = enabled
        if enabled {
            activeSceneID = nil
            sceneCaptureEnabled = false
            sceneCapturePositions = nil
        } else {
            activeFaderLevel = nil
        }
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
        activeSceneID = nil
        activeFaderLevel = .zero
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

    func rawValue(for preset: FaderLevelPreset) -> Int? {
        preset == .zero ? nominalValue : calibratedFaderLevels[preset.rawValue]
    }

    func setCalibratedFaderLevel(_ preset: FaderLevelPreset, rawValue: Int?) {
        guard preset != .zero, !hasUnsafeActiveMode else { return }
        if let rawValue {
            guard (HUI.minimumFaderValue...HUI.maximumFaderValue).contains(rawValue) else {
                lastIssue = "Raw HUI values must be between \(HUI.minimumFaderValue) and \(HUI.maximumFaderValue)."
                return
            }
            calibratedFaderLevels[preset.rawValue] = rawValue
        } else {
            calibratedFaderLevels.removeValue(forKey: preset.rawValue)
        }
        let stored = Dictionary(uniqueKeysWithValues: calibratedFaderLevels.map {
            (String($0.key), $0.value)
        })
        defaults.set(stored, forKey: DefaultsKey.calibratedFaderLevels)
    }

    func applyFaderLevel(_ preset: FaderLevelPreset) {
        guard let value = rawValue(for: preset) else {
            lastIssue = "Calibrate the \(preset.displayName) raw HUI value in Settings before using this preset."
            return
        }
        guard canSetFaderLevel else {
            lastIssue = "Fader presets require verified calibration, enabled transmission, and all configured banks online and idle."
            return
        }

        activeSceneID = nil
        sceneCaptureEnabled = false
        sceneCapturePositions = nil
        nominalLockEnabled = true
        defaults.set(true, forKey: DefaultsKey.lockEnabled)

        var sentAllBanks = true
        for bank in 0..<activeBankCount {
            commandedBankValues[bank] = Array(repeating: value, count: 8)
            if !sendBankSnapshot(bank: bank) {
                sentAllBanks = false
                break
            }
        }
        if sentAllBanks {
            activeFaderLevel = preset
            lastReassertionUptime = ProcessInfo.processInfo.systemUptime
            lastIssue = nil
        } else if transmissionEnabled {
            lastIssue = "The \(preset.displayName) preset could not be sent to every configured bank."
        }
    }

    /// Explicit calibration action. This can affect the analog level on channel 1.
    func testNominalOnFirstFader() {
        if let blockReason = testCandidateBlockReason {
            lastIssue = blockReason
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
            activeFaderLevel = .zero
            lastIssue = nil
        } else if lastIssue == nil {
            lastIssue = "Nominal could not be sent to every configured bank."
        }
    }

    func startVegasMode() {
        guard commissioningBlockReason == nil else {
            lastIssue = commissioningBlockReason
            return
        }

        commissioningTask?.cancel()
        commissioningSequence = nil
        deskExerciseStage = nil
        deskExerciseStageStartedUptime = nil
        recentFaderCommands.removeAll()
        touchedChannels.removeAll()
        commissioningCompletedChannels = 0
        vegasNextChannel = 0
        vegasLightsAreOn = false
        vegasLastLightChangeUptime = -Double.infinity
        lastIssue = nil

        let now = ProcessInfo.processInfo.systemUptime
        vegasStartedUptime = now
        vegasEndsUptime = now + Self.vegasDuration
        commissioningPhase = .vegas

        guard sendVegasLights(on: true) else {
            abortCommissioning(
                reason: "The active transport rejected the Vegas-mode light command.",
                attemptNominalRestoration: true
            )
            return
        }
        vegasLightsAreOn = true
        vegasLastLightChangeUptime = now

        commissioningTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000)
                guard !Task.isCancelled else { break }
                self?.commissioningTick()
            }
        }
    }

    func startFullDeskCommissioningTest() {
        guard commissioningBlockReason == nil else {
            lastIssue = commissioningBlockReason
            return
        }

        streamParsers = Array(repeating: MIDIMessageStreamParser(), count: 4)
        huiParsers = Array(repeating: HUIFaderParser(), count: 4)
        recentFaderCommands.removeAll()
        touchedChannels.removeAll()
        commissioningSequence = nil
        commissioningCompletedChannels = 0
        vegasNextChannel = 0
        vegasStartedUptime = nil
        lastIssue = nil

        let now = ProcessInfo.processInfo.systemUptime
        deskExerciseStage = .maximum
        deskExerciseStageStartedUptime = now
        commissioningPhase = .testing(channel: 0, target: .maximum)
        guard sendAllFaders(value: HUI.maximumFaderValue) else {
            abortCommissioning(
                reason: "The active transport rejected the full-desk maximum command.",
                attemptNominalRestoration: true
            )
            return
        }

        commissioningTask?.cancel()
        commissioningTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000)
                guard !Task.isCancelled else { break }
                self?.commissioningTick()
            }
        }
    }

    /// Normal stop: cancel the producer first, then attempt to return all 32
    /// faders to verified nominal. HUI transmission remains enabled afterward.
    func stopCommissioningAndRestoreNominal() {
        guard isCommissioningActive else { return }

        commissioningTask?.cancel()
        commissioningTask = nil
        commissioningSequence?.stop()
        commissioningSequence = nil
        deskExerciseStage = nil
        deskExerciseStageStartedUptime = nil
        commissioningPhase = .idle
        commissioningCompletedChannels = 0
        vegasStartedUptime = nil
        vegasEndsUptime = nil
        _ = sendVegasLights(on: false)
        vegasLightsAreOn = false

        let restoredNominal = restoreAllActiveFadersToNominal()
        guard transmissionEnabled else { return }
        if restoredNominal {
            lastIssue = "The active transport accepted nominal restoration commands for all 32 faders. This does not prove physical movement; visually confirm every fader before reconnecting audio."
        } else {
            lastIssue = "The test stopped, but CoreMIDI did not accept every nominal restoration command. Keep audio disconnected and inspect the desk."
        }
    }

    func selectEthernetService(id: String?) {
        guard !hasUnsafeActiveMode, id != selectedEthernetServiceID else { return }

        let newService = id.flatMap { selectedID in
            ethernetServices.first { $0.id == selectedID }
        }
        guard id == nil || newService != nil else {
            lastIssue = "The requested Ethernet service is no longer available. Rescan and make an explicit selection."
            return
        }

        revokeEthernetBoundAuthorizationWithoutRestoration()
        selectedEthernetServiceID = newService?.id
        selectedEthernetServiceName = newService?.displayName
        selectedEthernetBSDName = newService?.bsdName
        persistSelectedEthernetService()
        midi.configureNativeEthernet(interfaceBSDName: newService?.bsdName)
        refreshEndpointsAndReconnect(ethernetAlreadyValidated: true)
        lastIssue = "The Ethernet service selection changed. Native SwiftMix Ethernet ports were rebound to the selected interface. Outgoing MIDI remains stopped until explicitly enabled and recommissioned."
    }

    func rescanEthernetServices() {
        guard !hasUnsafeActiveMode else { return }
        refreshEthernetServices(enforceSafetyInterlock: true)
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

    func autoConfigureEthernetPorts() {
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

    private func handleEthernetConfigurationChanged() {
        refreshEthernetServices(enforceSafetyInterlock: true)
    }

    /// Returns false when an identity migration/change was discovered or an
    /// active transmission interlock was tripped. Callers enabling a session
    /// must then require a new explicit action.
    @discardableResult
    private func refreshEthernetServices(enforceSafetyInterlock: Bool) -> Bool {
        let refreshedServices = ethernetMonitor.services()
        if refreshedServices != ethernetServices {
            ethernetServices = refreshedServices
        }

        guard let selectedEthernetServiceID else { return true }
        guard let currentService = ethernetServices.first(where: {
            $0.id == selectedEthernetServiceID
        }) else {
            if enforceSafetyInterlock, transmissionEnabled {
                tripEthernetSafetyInterlock()
                return false
            }
            return true
        }

        if let authorizedBSDName = selectedEthernetBSDName {
            guard currentService.bsdName == authorizedBSDName else {
                handleEthernetBSDIdentityChange(
                    currentService: currentService,
                    previousBSDName: authorizedBSDName
                )
                return false
            }
        } else {
            recordMigratedEthernetBSDIdentity(currentService: currentService)
            return false
        }

        if currentService.displayName != selectedEthernetServiceName {
            selectedEthernetServiceName = currentService.displayName
            persistSelectedEthernetService()
        }

        if currentService.isActive {
            lastDirectEthernetValidationUptime = ProcessInfo.processInfo.systemUptime
        }

        guard enforceSafetyInterlock, transmissionEnabled else { return true }
        guard currentService.isActive else {
            tripEthernetSafetyInterlock()
            return false
        }
        return true
    }

    private func enforceEthernetSafetyBeforeSend() -> Bool {
        guard transmissionEnabled else { return false }
        guard let selectedEthernetServiceID,
              let authorizedBSDName = selectedEthernetBSDName,
              let cachedService = ethernetServices.first(where: {
                  $0.id == selectedEthernetServiceID
              }) else {
            tripEthernetSafetyInterlock()
            return false
        }

        guard cachedService.bsdName == authorizedBSDName else {
            handleEthernetBSDIdentityChange(
                currentService: cachedService,
                previousBSDName: authorizedBSDName
            )
            return false
        }
        guard cachedService.isActive else {
            tripEthernetSafetyInterlock()
            return false
        }

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastDirectEthernetValidationUptime
            >= Self.directEthernetValidationInterval {
            lastDirectEthernetValidationUptime = now
            guard ethernetMonitor.interfaceIsCurrentlyActive(bsdName: authorizedBSDName) else {
                // Close first; refresh afterward only to improve displayed state
                // or detect an identity change. No send follows this failure.
                tripEthernetSafetyInterlock()
                refreshEthernetServices(enforceSafetyInterlock: false)
                return false
            }
        }
        return transmissionEnabled
    }

    private func handleEthernetBSDIdentityChange(
        currentService: EthernetNetworkService,
        previousBSDName: String
    ) {
        let previousName = selectedEthernetServiceName ?? "Selected Ethernet service"

        // Revoke and close before recording the newly observed identity.
        revokeEthernetBoundAuthorizationWithoutRestoration()
        selectedEthernetServiceName = currentService.displayName
        selectedEthernetBSDName = currentService.bsdName
        persistSelectedEthernetService()

        lastIssue = "\(previousName) kept service ID \(currentService.id), but its underlying BSD interface changed from \(previousBSDName) to \(currentService.bsdName). The CoreMIDI gate was closed without restoration, active control was stopped, and commissioning/startup authorization was revoked before the new identity was recorded. Explicitly enable and recommission this identity before authorizing automatic transmission."
    }

    private func recordMigratedEthernetBSDIdentity(
        currentService: EthernetNetworkService
    ) {
        let hadAuthorizationOrControl = transmissionEnabled
            || commissioningPassedThisSession
            || automaticTransmissionAuthorized
            || hasUnsafeActiveMode
        if hadAuthorizationOrControl {
            revokeEthernetBoundAuthorizationWithoutRestoration()
        }

        selectedEthernetServiceName = currentService.displayName
        selectedEthernetBSDName = currentService.bsdName
        persistSelectedEthernetService()
        lastDirectEthernetValidationUptime = -Double.infinity

        if hadAuthorizationOrControl {
            lastIssue = "Recorded \(currentService.bsdName) as the BSD identity for the selected Ethernet service. Existing commissioning/startup authorization was revoked and transmission remained closed because the previous authorization was not tied to a BSD interface. Explicitly enable and recommission before authorizing automatic transmission."
        } else {
            lastIssue = "Recorded \(currentService.bsdName) as the BSD identity for the selected Ethernet service. Transmission remains disabled; review the identity and explicitly enable it when safe."
        }
    }

    private func tripEthernetSafetyInterlock() {
        guard transmissionEnabled else { return }

        let selectedDescription = selectedEthernetServiceName
            ?? selectedEthernetService?.displayName
            ?? "The selected Ethernet service"
        let availability = selectedEthernetService == nil
            ? "is no longer available"
            : "became inactive"

        // Close the CoreMIDI gate before cancelling producers or changing any
        // UI state. No cleanup/restoration may traverse an unverified route.
        midi.setTransmissionEnabled(false)
        transmissionEnabled = false
        dawTakeoverEnabled = false
        clearDAWCloseState(resumeTransmission: false)
        cancelCommissioningWithoutRestoration()
        recentFaderCommands.removeAll()
        markAllRuntimeBanksOffline()
        lastDirectEthernetValidationUptime = -Double.infinity

        lastIssue = "\(selectedDescription) \(availability). The Ethernet safety interlock closed all CoreMIDI transmission before further keepalive, fader, or DAW output. Commissioning/DAW control stopped without restoration; inspect the desk. This session will not resume automatically—explicitly enable transmission again after the exact service is active."
    }

    private func revokeEthernetBoundAuthorizationWithoutRestoration() {
        // Identity changes revoke authorization before new identity information
        // is persisted and intentionally send no restoration through either route.
        midi.setTransmissionEnabled(false)
        transmissionEnabled = false
        dawTakeoverEnabled = false
        clearDAWCloseState(resumeTransmission: false)
        cancelCommissioningWithoutRestoration()
        recentFaderCommands.removeAll()
        markAllRuntimeBanksOffline()
        lastDirectEthernetValidationUptime = -Double.infinity
        commissioningPassedThisSession = false
        automaticTransmissionAuthorized = false
        defaults.set(false, forKey: DefaultsKey.automaticTransmissionAuthorized)
    }

    private func markAllRuntimeBanksOffline() {
        touchedChannels.removeAll()
        sceneCaptureEnabled = false
        sceneCapturePositions = nil
        for bank in runtimeStates.indices {
            bankLastActivityUptimes[bank] = nil
            runtimeStates[bank].online = false
            runtimeStates[bank].lastActivityUptime = nil
        }
    }

    private func persistSelectedEthernetService() {
        if let selectedEthernetServiceID {
            defaults.set(selectedEthernetServiceID, forKey: DefaultsKey.selectedEthernetServiceID)
        } else {
            defaults.removeObject(forKey: DefaultsKey.selectedEthernetServiceID)
        }
        if let selectedEthernetServiceName {
            defaults.set(selectedEthernetServiceName, forKey: DefaultsKey.selectedEthernetServiceName)
        } else {
            defaults.removeObject(forKey: DefaultsKey.selectedEthernetServiceName)
        }
        if let selectedEthernetBSDName {
            defaults.set(selectedEthernetBSDName, forKey: DefaultsKey.selectedEthernetBSDName)
        } else {
            defaults.removeObject(forKey: DefaultsKey.selectedEthernetBSDName)
        }
    }

    private func handleTopologyChanged() {
        if isCommissioningActive {
            cancelCommissioningWithoutRestoration()
            lastIssue = "CoreMIDI topology changed during commissioning. The routine stopped without sending restoration through a possibly stale route; keep audio disconnected and inspect the faders."
        } else if dawTakeoverEnabled {
            midi.setDAWOutputEnabled(false)
            dawTakeoverEnabled = false
            clearDAWCloseState(resumeTransmission: false)
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

    private func refreshEndpointsAndReconnect(
        ethernetAlreadyValidated: Bool = false
    ) {
        midi.configureNativeEthernet(interfaceBSDName: selectedEthernetBSDName)
        let snapshot = midi.endpointSnapshot()
        touchedChannels.removeAll()
        bankLastActivityUptimes = Array(repeating: nil, count: 4)
        sources = snapshot.sources
        destinations = snapshot.destinations

        var routeWasUpdated = false
        for bank in 0..<4 {
            guard bank < activeBankCount else {
                let connection = midi.configure(bank: bank, source: nil, destination: nil)
                runtimeStates[bank].sourceConnected = false
                runtimeStates[bank].destinationConnected = false
                runtimeStates[bank].online = false
                runtimeStates[bank].lastActivityUptime = nil
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
            runtimeStates[bank].lastActivityUptime = nil
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
        if !ethernetAlreadyValidated {
            guard refreshEthernetServices(enforceSafetyInterlock: true),
                  transmissionEnabled else { return }
        }
        for bank in 0..<activeBankCount where runtimeStates[bank].destinationConnected {
            guard initializeBank(bank) else {
                guard transmissionEnabled else { return }
                lastIssue = "Logic-compatible HUI initialization failed for bank \(bank + 1)."
                continue
            }
            if nominalVerified, nominalLockEnabled, !sendBankSnapshot(bank: bank) {
                guard transmissionEnabled else { return }
                lastIssue = "Initial full-fader snapshot failed for bank \(bank + 1)."
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

        let portNumber = bank + 1
        if let nativePort = candidates.first(where: {
            $0.name == "SwiftMix Ethernet Port \(portNumber)"
        }) {
            return nativePort
        }

        let ipMIDICandidates = candidates.filter {
            $0.name.localizedCaseInsensitiveContains("ipmidi")
        }
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

        if dawTakeoverEnabled,
           dawTakeoverProfile.usesBidirectionalHUIBridge,
           dawBankSelection.bankIndices.contains(bank) {
            guard let status = midi.sendHUIToBridge(event.bytes, bank: bank), status == noErr else {
                lastIssue = "Could not forward SwiftMix Bank \(bank + 1) HUI traffic to the selected DAW."
                return
            }
        }

        let messages = streamParsers[bank].consume(event.bytes)
        for message in messages {
            let isHostLEDMessage = message.bytes.count == 3
                && message.bytes[0] == 0xB0
                && (message.bytes[1] == 0x0C || message.bytes[1] == 0x2C)
            if message == HUI.pingRequest || isHostLEDMessage {
                localEchoDetected = true
                if isCommissioningActive {
                    abortCommissioning(
                        reason: "Outgoing HUI data appeared on the selected input during commissioning, indicating a MIDI loopback.",
                        attemptNominalRestoration: true
                    )
                } else {
                    lastIssue = "Outgoing HUI host traffic was received on bank \(bank + 1). Disable MIDI/network loopback before enabling fader control."
                }
                let loopbackIssue = lastIssue
                disableAllMIDITransmission()
                lastIssue = loopbackIssue
                continue
            }

            let events = huiParsers[bank].consume(message)
            for huiEvent in events {
                recordHUIActivity(bank: bank, receivedUptime: event.receivedUptime)

                switch huiEvent {
                case .pingReply:
                    break
                case let .faderPosition(fader, value):
                    lastObservedFader = ObservedFader(
                        bank: bank,
                        fader: fader,
                        value: value,
                        date: Date()
                    )

                    let channel = bank * 8 + fader
                    if sceneCaptureEnabled, sceneCapturePositions?.indices.contains(channel) == true {
                        sceneCapturePositions?[channel] = value
                    }
                    if isCommissioningActive {
                        if event.isNativeEthernet || !isImmediateCommandEcho(
                            channel: channel,
                            value: value,
                            receivedUptime: event.receivedUptime
                        ) {
                            processCommissioningReport(
                                channel: channel,
                                value: value,
                                receivedUptime: event.receivedUptime,
                                trustedDirectTargetReport: event.isNativeEthernet
                            )
                        }
                    } else if dawTakeoverEnabled,
                              !dawTakeoverProfile.usesBidirectionalHUIBridge,
                              dawBankSelection.bankIndices.contains(bank) {
                        sendDAWPosition(channel: channel, value: value)
                    } else {
                        let policy = NominalLockPolicy(
                            nominalValue: lockTarget(for: channel),
                            tolerance: tolerance
                        )
                        if !touchedChannels.contains(channel),
                           let restoreValue = policy.restoreValue(
                               observedValue: value,
                               lockIsArmed: lockIsArmed
                           ) {
                            _ = sendFader(bank: bank, fader: fader, value: restoreValue)
                        }
                    }
                case let .faderTouch(fader, touched):
                    let channel = bank * 8 + fader
                    if touched {
                        touchedChannels.insert(channel)
                    } else {
                        touchedChannels.remove(channel)
                    }

                    if dawTakeoverEnabled,
                       !dawTakeoverProfile.usesBidirectionalHUIBridge,
                       dawBankSelection.bankIndices.contains(bank) {
                        sendDAWTouch(channel: channel, touched: touched)
                    } else if !touched, lockIsArmed {
                        let bankChannels = (bank * 8)..<((bank + 1) * 8)
                        if !bankChannels.contains(where: touchedChannels.contains) {
                            _ = sendFader(bank: bank, fader: fader, value: lockTarget(for: channel))
                        }
                    }
                }
            }
        }
    }

    private func recordHUIActivity(bank: Int, receivedUptime: TimeInterval) {
        bankLastActivityUptimes[bank] = receivedUptime
        if !runtimeStates[bank].online {
            runtimeStates[bank].lastActivityUptime = receivedUptime
            runtimeStates[bank].online = true
        }
    }

    private func processCommissioningReport(
        channel: Int,
        value: Int,
        receivedUptime: TimeInterval,
        trustedDirectTargetReport: Bool
    ) {
        guard var sequence = commissioningSequence,
              let action = sequence.observe(
                channel: channel,
                value: value,
                at: receivedUptime,
                trustedDirectTargetReport: trustedDirectTargetReport
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
            guard let stage = deskExerciseStage,
                  let stageStarted = deskExerciseStageStartedUptime,
                  now - stageStarted >= Self.deskExerciseStageDuration else {
                return
            }

            switch stage {
            case .maximum:
                guard sendAllFaders(value: Self.deskExerciseLowValue) else {
                    abortCommissioning(
                        reason: "The active transport rejected the full-desk low command.",
                        attemptNominalRestoration: true
                    )
                    return
                }
                deskExerciseStage = .low
                deskExerciseStageStartedUptime = now
                commissioningPhase = .testing(channel: 0, target: .minimum)
            case .low:
                guard sendAllFaders(value: nominalValue) else {
                    abortCommissioning(
                        reason: "The active transport rejected the full-desk nominal command.",
                        attemptNominalRestoration: true
                    )
                    return
                }
                deskExerciseStage = .nominal
                deskExerciseStageStartedUptime = now
                commissioningPhase = .testing(channel: 0, target: .nominal)
            case .nominal:
                commissioningTask?.cancel()
                commissioningTask = nil
                deskExerciseStage = nil
                deskExerciseStageStartedUptime = nil
                commissioningPhase = .idle
                commissioningCompletedChannels = 32
                commissioningPassedThisSession = true
                lastReassertionUptime = now
                lastIssue = "Full-desk exercise completed maximum → raw 300 → verified nominal. Visually confirm all 32 faders completed the movement."
            }
        case .vegas:
            guard allActiveBanksOnline,
                  let vegasStartedUptime,
                  let vegasEndsUptime else {
                abortCommissioning(
                    reason: "A HUI bank went offline during Vegas mode.",
                    attemptNominalRestoration: true
                )
                return
            }

            if now >= vegasEndsUptime {
                commissioningTask?.cancel()
                commissioningTask = nil
                commissioningPhase = .idle
                self.vegasStartedUptime = nil
                self.vegasEndsUptime = nil
                let lightsOff = sendVegasLights(on: false)
                vegasLightsAreOn = false
                let restoredNominal = restoreAllActiveFadersToNominal()
                if lightsOff && restoredNominal {
                    lastIssue = "Vegas mode completed after one minute. All lights were switched off and the active transport accepted nominal restoration for all 32 faders; visually verify the desk."
                } else {
                    lastIssue = "Vegas mode ended, but the light shutdown or nominal restoration was incomplete. Keep audio disconnected and inspect the desk."
                }
                return
            }

            if now - vegasLastLightChangeUptime >= Self.vegasLightInterval {
                let lightsOn = !vegasLightsAreOn
                guard sendVegasLights(on: lightsOn) else {
                    abortCommissioning(
                        reason: "The active transport rejected a Vegas-mode light command.",
                        attemptNominalRestoration: true
                    )
                    return
                }
                vegasLightsAreOn = lightsOn
                vegasLastLightChangeUptime = now
            }

            let wave = VegasWave(channelCount: 32)
            let channel = vegasNextChannel
            let value = wave.value(channel: channel, elapsed: now - vegasStartedUptime)
            if !sendGlobalFader(channel: channel, value: value) {
                guard transmissionEnabled else { return }
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
                guard transmissionEnabled else { return }
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
        deskExerciseStage = nil
        deskExerciseStageStartedUptime = nil
        commissioningPhase = .idle
        commissioningCompletedChannels = 0
        vegasStartedUptime = nil
        vegasEndsUptime = nil
        if transmissionEnabled { _ = sendVegasLights(on: false) }
        vegasLightsAreOn = false

        if attemptNominalRestoration, transmissionEnabled, nominalVerified {
            let restoredNominal = restoreAllActiveFadersToNominal()
            guard transmissionEnabled else { return }
            if restoredNominal {
                lastIssue = "\(reason) The active transport accepted a nominal restoration for all 32 faders; visually verify the desk before reconnecting audio."
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
        deskExerciseStage = nil
        deskExerciseStageStartedUptime = nil
        commissioningPhase = .idle
        commissioningCompletedChannels = 0
        vegasStartedUptime = nil
        vegasEndsUptime = nil
        vegasLightsAreOn = false
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

        if let deadline = dawCloseDeadlineUptime {
            let remaining = max(0, Int(ceil(deadline - now)))
            if remaining == 0 {
                midi.setTransmissionSuspended(true, banks: dawBankSelection.bankIndices)
                dawCloseDeadlineUptime = nil
                dawCloseGraceSecondsRemaining = nil
                dawFadersResting = true
                dawCloseOverrideActive = false
            } else if dawCloseGraceSecondsRemaining != remaining {
                dawCloseGraceSecondsRemaining = remaining
            }
        }

        if transmissionEnabled {
            guard refreshEthernetServices(enforceSafetyInterlock: true),
                  transmissionEnabled else { return }

            for bank in 0..<activeBankCount where runtimeStates[bank].destinationConnected {
                if dawFadersResting && dawBankSelection.bankIndices.contains(bank) {
                    continue
                }
                guard enforceEthernetSafetyBeforeSend() else { return }
                let status = midi.send(HUI.pingRequest.bytes, toBank: bank)
                if let status, status != noErr {
                    lastIssue = "HUI keepalive failed for bank \(bank + 1) (OSStatus \(status))."
                }
            }
        }

        for bank in 0..<activeBankCount {
            let isOnline = bankLastActivityUptimes[bank].map {
                now - $0 < Self.huiActivityTimeout
            } ?? false
            if runtimeStates[bank].online != isOnline {
                runtimeStates[bank].online = isOnline
                runtimeStates[bank].lastActivityUptime = bankLastActivityUptimes[bank]
            }
        }

        if isCommissioningActive, !allActiveBanksOnline {
            abortCommissioning(
                reason: "A HUI bank stopped sending valid activity during commissioning.",
                attemptNominalRestoration: true
            )
            return
        }

        if dawTakeoverEnabled, !dawFadersResting, !allActiveBanksOnline {
            midi.setDAWOutputEnabled(false)
            dawTakeoverEnabled = false
            clearDAWCloseState(resumeTransmission: false)
            lastIssue = "A HUI bank stopped sending valid activity, so DAW Takeover was stopped. No restoration was sent through the unverified connection; inspect the desk."
            return
        }

        if lockIsArmed,
           allActiveBanksOnline,
           now - lastReassertionUptime >= Self.nominalReassertionInterval {
            reassertNominalOnUntouchedBanks()
        }
    }

    private func sendDAWPosition(channel: Int, value: Int) {
        guard enforceEthernetSafetyBeforeSend() else { return }
        let mapping = DAWTakeoverMapping(
            midiChannel: dawMIDIChannel - 1,
            controllerBase: dawControllerBase,
            profile: dawTakeoverProfile
        )
        guard let message = try? mapping.positionMessage(fader: channel, value: value),
              let status = midi.sendToDAW([message.bytes]),
              status == noErr else {
            lastIssue = "Could not publish channel \(channel + 1) to the DAW virtual MIDI input."
            return
        }
    }

    private func sendDAWTouch(channel: Int, touched: Bool) {
        guard enforceEthernetSafetyBeforeSend() else { return }
        let mapping = DAWTakeoverMapping(
            midiChannel: dawMIDIChannel - 1,
            controllerBase: dawControllerBase,
            profile: dawTakeoverProfile
        )
        guard let message = try? mapping.touchMessage(fader: channel, touched: touched),
              let status = midi.sendToDAW([message.bytes]),
              status == noErr else {
            lastIssue = "Could not publish channel \(channel + 1) touch state to the DAW virtual MIDI input."
            return
        }
    }

    private func sendVegasLights(on: Bool) -> Bool {
        guard transmissionEnabled, enforceEthernetSafetyBeforeSend() else { return false }
        let messages = HUI.channelStripLights(on: on).map(\.bytes)
        for bank in 0..<4 {
            guard runtimeStates.indices.contains(bank),
                  runtimeStates[bank].destinationConnected,
                  midi.send(messages, toBank: bank) == noErr else {
                return false
            }
        }
        return true
    }

    private func initializeBank(_ bank: Int) -> Bool {
        guard transmissionEnabled,
              enforceEthernetSafetyBeforeSend(),
              runtimeStates.indices.contains(bank),
              runtimeStates[bank].destinationConnected else {
            return false
        }

        let initializationStatus = midi.send(
            HUI.bankInitialization.map(\.bytes),
            toBank: bank
        )
        guard initializationStatus == noErr else { return false }

        let pingStatus = midi.send(HUI.pingRequest.bytes, toBank: bank)
        return pingStatus == noErr
    }

    private func sendBankSnapshot(bank: Int) -> Bool {
        guard transmissionEnabled,
              enforceEthernetSafetyBeforeSend(),
              commandedBankValues.indices.contains(bank),
              runtimeStates.indices.contains(bank),
              runtimeStates[bank].destinationConnected,
              let messages = try? HUI.bankSnapshot(values: commandedBankValues[bank]),
              let status = midi.send(messages.map(\.bytes), toBank: bank),
              status == noErr else {
            return false
        }
        return true
    }

    private func reassertNominalOnUntouchedBanks() {
        var failedBanks: [Int] = []
        for bank in 0..<activeBankCount {
            let channels = (bank * 8)..<((bank + 1) * 8)
            guard !channels.contains(where: touchedChannels.contains) else { continue }

            commandedBankValues[bank] = channels.map { lockTarget(for: $0) }
            if !sendBankSnapshot(bank: bank) {
                guard transmissionEnabled else { return }
                failedBanks.append(bank + 1)
            }
        }

        lastReassertionUptime = ProcessInfo.processInfo.systemUptime
        if !failedBanks.isEmpty {
            lastIssue = "Timed nominal reassertion failed for banks \(failedBanks)."
        }
    }

    private func restoreAllActiveFadersToNominal() -> Bool {
        restoreBanksToNominal(Array(0..<activeBankCount))
    }

    private func restoreBanksToNominal(_ banks: [Int]) -> Bool {
        guard transmissionEnabled, nominalVerified, !banks.isEmpty else { return false }

        activeSceneID = nil
        activeFaderLevel = .zero
        sceneCaptureEnabled = false
        sceneCapturePositions = nil
        var allMessagesSent = true
        for bank in banks {
            guard runtimeStates[bank].destinationConnected else {
                allMessagesSent = false
                continue
            }
            commandedBankValues[bank] = Array(repeating: nominalValue, count: 8)
            if !sendBankSnapshot(bank: bank) {
                guard transmissionEnabled else { return false }
                allMessagesSent = false
            }
        }

        if allMessagesSent {
            lastReassertionUptime = ProcessInfo.processInfo.systemUptime
        }
        return allMessagesSent
    }

    @discardableResult
    private func sendAllFaders(value: Int) -> Bool {
        guard transmissionEnabled,
              (HUI.minimumFaderValue...HUI.maximumFaderValue).contains(value),
              activeBankCount == 4,
              allActiveBanksOnline else {
            return false
        }

        for bank in 0..<4 {
            commandedBankValues[bank] = Array(repeating: value, count: 8)
            guard sendBankSnapshot(bank: bank) else { return false }
        }
        return true
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
        guard enforceEthernetSafetyBeforeSend() else { return false }
        guard runtimeStates.indices.contains(bank), runtimeStates[bank].destinationConnected else {
            lastIssue = "Bank \(bank + 1) has no connected MIDI destination."
            return false
        }
        guard (0..<8).contains(fader),
              (HUI.minimumFaderValue...HUI.maximumFaderValue).contains(value) else {
            lastIssue = "Invalid HUI fader command for bank \(bank + 1), fader \(fader + 1)."
            return false
        }

        let previousValue = commandedBankValues[bank][fader]
        commandedBankValues[bank][fader] = value
        let sentUptime = ProcessInfo.processInfo.systemUptime
        guard sendBankSnapshot(bank: bank) else {
            commandedBankValues[bank][fader] = previousValue
            lastIssue = "Could not send the full snapshot for bank \(bank + 1), fader \(fader + 1)."
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
        clearDAWCloseState(resumeTransmission: false)
        for bank in runtimeStates.indices {
            bankLastActivityUptimes[bank] = nil
            runtimeStates[bank].online = false
            runtimeStates[bank].lastActivityUptime = nil
        }
        lastIssue = "The MIDI routing changed, so commissioning authorization was revoked and all outgoing MIDI was disabled. Re-test the new route before authorizing startup transmission."
    }

    private func targetDescription(_ target: FaderExerciseTarget) -> String {
        switch target {
        case .maximum:
            return "maximum"
        case .minimum:
            return "low position (raw \(Self.deskExerciseLowValue))"
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

    private func lockTarget(for channel: Int) -> Int {
        if let activeScene, activeScene.positions.indices.contains(channel) {
            return activeScene.positions[channel]
        }
        if let activeFaderLevel, let value = rawValue(for: activeFaderLevel) {
            return value
        }
        return nominalValue
    }

    private func persistScenes() {
        if let data = try? JSONEncoder().encode(scenes) {
            defaults.set(data, forKey: DefaultsKey.scenes)
        }
    }

    private func saveRoutes() {
        if let data = try? JSONEncoder().encode(routes) {
            defaults.set(data, forKey: DefaultsKey.routes)
        }
    }
}
