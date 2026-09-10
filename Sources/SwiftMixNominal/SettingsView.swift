import CoreMIDI
import SwiftMixCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var showTestConfirmation = false
    @State private var showVerificationConfirmation = false
    @State private var showTransmissionConfirmation = false
    @State private var showCommissioningConfirmation = false
    @State private var showDAWTakeoverConfirmation = false
    @State private var sceneName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusSection
                safetySection
                connectionSection
                calibrationSection
                scenesSection
                commissioningSection
                dawTakeoverSection
                startupSection
            }
            .padding(20)
        }
        .frame(minWidth: 640, idealWidth: 700, minHeight: 700, idealHeight: 820)
        .alert("Move channel 1 to the candidate value?", isPresented: $showTestConfirmation) {
            Button("Send to Fader 1", role: .destructive) {
                model.testNominalOnFirstFader()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This command can immediately change the analog level, recording level, and monitor feeds on channel 1. Keep your hand off the fader cap while sending. The SwiftMix MODE switch requests automation-mode changes through its HUI host; do not treat mixed LED combinations as a verified READ state until host mode handling has been confirmed. Confirm that the studio is in a safe state first.")
        }
        .alert("Verify and arm Nominal Lock?", isPresented: $showVerificationConfirmation) {
            Button("Verified — Arm Lock", role: .destructive) {
                model.verifyNominalAndArm()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only continue after confirming that raw value \(model.nominalValue) places a physical SwiftMix fader exactly on its printed 0 dB mark. The app will send this value to every configured fader.")
        }
        .alert("Enable outgoing HUI MIDI for this session?", isPresented: $showTransmissionConfirmation) {
            Button("Enable HUI Transmission", role: .destructive) {
                model.enableHUITransmissionForSession()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The app will immediately begin sending HUI keepalive pings to the selected destinations. If a previously verified Nominal Lock is enabled, it can also return faders to nominal after all banks reply. Confirm that Pro Tools is not using these HUI ports and the studio is safe.")
        }
        .alert("Run the destructive 32-channel exercise?", isPresented: $showCommissioningConfirmation) {
            Button("Muted/Disconnected — Run Test", role: .destructive) {
                model.startFullDeskCommissioningTest()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This moves all 32 faders together: maximum, low raw 300, then verified nominal. Each position is held for three seconds. The test finishes at nominal and requires your visual confirmation; it does not rely on motor-position reports. Confirm that all console inputs, outputs, DAW paths, speakers, headphones, and in-ear feeds are muted or physically disconnected.")
        }
        .alert("Enable DAW Takeover?", isPresented: $showDAWTakeoverConfirmation) {
            Button("Enable Selected DAW Mode", role: .destructive) {
                model.enableDAWTakeover()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.dawTakeoverProfile == .logicProHUI
                ? "This creates temporary bidirectional HUI port pairs only for the selected bank or banks and bridges them to native Ethernet. The ports are disposed when Takeover stops. Remove old ipMIDI HUI assignments and keep audio paths safe during the first test."
                : "Nominal Lock will be suspended while takeover is active. Moving a physical fader changes the console’s real analog level. This generic MIDI mode sends controller data to the DAW but does not accept playback commands back to the console.")
        }
    }

    private var statusSection: some View {
        GroupBox("Status") {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.statusLine)
                    .font(.headline)
                if let issue = model.lastIssue {
                    Text(issue)
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var safetySection: some View {
        GroupBox("Important Safety Limitation") {
            Text("Nominal Lock is software, not a hard interlock. Pushing a motorized fader can cause a brief real analog level change before the app detects it and commands the fader back. Do not rely on this utility as the only protection for hearing, performers, monitors, or recordings.")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var connectionSection: some View {
        GroupBox("SwiftMix Connection") {
            VStack(alignment: .leading, spacing: 12) {
                Picker(
                    "Ethernet service",
                    selection: Binding<String?>(
                        get: { model.selectedEthernetServiceID },
                        set: { model.selectEthernetService(id: $0) }
                    )
                ) {
                    Text("Select an Ethernet service").tag(Optional<String>.none)
                    missingEthernetServiceSelection
                    ForEach(model.ethernetServices) { service in
                        Text(service.displayName).tag(Optional(service.id))
                    }
                }
                .disabled(model.hasUnsafeActiveMode)

                Text(model.selectedEthernetServiceStatusLine)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(model.canEnableHUITransmission ? .green : .orange)

                Button("Rescan Interfaces") {
                    model.rescanEthernetServices()
                }
                .disabled(model.hasUnsafeActiveMode)

                Text("SwiftMix Nominal Lock provides four native Ethernet MIDI ports. Their UDP sockets are bound directly to the selected BSD interface, so SwiftMix traffic does not follow the system multicast route onto Wi-Fi. Third-party ipMIDI is no longer required for physical fader control.")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)

                Divider()

                Picker(
                    "Channels",
                    selection: Binding(
                        get: { model.channelCount },
                        set: { model.setChannelCount($0) }
                    )
                ) {
                    ForEach([8, 16, 24, 32], id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .pickerStyle(.segmented)

                Text("The app must be the sole HUI host for the SwiftMix. Quit Logic/Pro Tools control-surface sessions and disable the third-party ipMIDI driver for these four banks, or multiple hosts can fight over fader positions.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if model.transmissionEnabled {
                    HStack {
                        Text("Outgoing HUI MIDI is enabled")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Disable All MIDI Transmission", role: .destructive) {
                            model.disableAllMIDITransmission()
                        }
                    }
                } else {
                    HStack {
                        Text("Monitor only: endpoint discovery and incoming MIDI remain available, but the transport gate blocks every outgoing packet.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Enable for This Session…") {
                            showTransmissionConfirmation = true
                        }
                        .disabled(!model.canEnableHUITransmission)
                    }

                    if let reason = model.huiTransmissionBlockerText {
                        Text("Transmission blocked: \(reason)")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }

                ForEach(0..<model.activeBankCount, id: \.self) { bank in
                    BankEndpointSettings(model: model, bank: bank)
                }

                HStack {
                    Button("Use Native Ethernet Ports") {
                        model.autoConfigureEthernetPorts()
                    }
                    Button("Rescan") {
                        model.rescanEndpoints()
                    }
                }
                .disabled(model.hasUnsafeActiveMode)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var calibrationSection: some View {
        GroupBox("Nominal Calibration") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Raw HUI value")
                    Spacer()
                    TextField(
                        "0–16383",
                        text: Binding(
                            get: { String(model.nominalValue) },
                            set: { text in
                                if let value = Int(text) {
                                    model.setNominalValue(value)
                                }
                            }
                        )
                    )
                    .frame(width: 100)
                    .multilineTextAlignment(.trailing)
                }

                Stepper(
                    "Restore tolerance: \(model.tolerance)",
                    value: Binding(
                        get: { model.tolerance },
                        set: { model.setTolerance($0) }
                    ),
                    in: 0...512,
                    step: 8
                )

                if model.nominalVerified {
                    Text("This nominal value has been marked as physically verified.")
                        .foregroundStyle(.green)
                } else {
                    Text("Not verified. The default 12320 value was observed at the printed 0 dB mark on one fader in each SwiftMix bank. Verify it on this desk before transmission.")
                        .foregroundStyle(.orange)
                }

                if let observed = model.lastObservedFader {
                    Text("Last received: channel \(observed.channel), raw \(observed.value)")
                        .font(.system(.body, design: .monospaced))
                    Button("Use Last Received Value") {
                        model.useLastObservedAsNominal()
                    }
                } else {
                    Text("No fader position has been received yet.")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Test Candidate on Fader 1") {
                        showTestConfirmation = true
                    }
                    .disabled(!model.canTestFirstFader)

                    Button("Verify 0 dB and Arm Lock") {
                        showVerificationConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canVerifyNominal)
                }

                if let reason = model.testCandidateBlockReason {
                    Text("Candidate test unavailable: \(reason)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Text("For capture calibration, disable Nominal Lock, place one physical fader exactly at its printed 0 dB mark, then use the last received value above. The SwiftMix MODE switch changes automation mode through its HUI host, and this app does not yet interpret mode-button requests or drive the mode LEDs. Re-enable the lock only after the studio signal path is safe.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var scenesSection: some View {
        GroupBox("Fader Scenes") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Capture stores 32 target positions. Recall sends the scene immediately and locks each fader to its stored position; touch a fader to move it temporarily, then release it to return to the scene.")
                    .foregroundStyle(.secondary)

                if model.sceneCaptureEnabled {
                    Text("Capture unlocked — move the desired faders now.")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    HStack {
                        TextField("Scene name", text: $sceneName)
                        Button("Save Scene") {
                            model.saveCapturedScene(name: sceneName)
                            if !model.sceneCaptureEnabled { sceneName = "" }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(sceneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Cancel") {
                            model.cancelSceneCapture()
                            sceneName = ""
                        }
                    }
                } else {
                    Button("Unlock Faders & Capture New Scene") {
                        sceneName = ""
                        model.beginSceneCapture()
                    }
                    .disabled(!model.canManageScenes)
                }

                if model.scenes.isEmpty {
                    Text("No scenes saved.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.scenes) { scene in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(scene.name)
                                    .font(.headline)
                                Text(model.activeSceneID == scene.id ? "Active scene lock" : "32 stored positions")
                                    .font(.caption)
                                    .foregroundStyle(model.activeSceneID == scene.id ? .green : .secondary)
                            }
                            Spacer()
                            Button("Recall & Lock") {
                                model.recallScene(id: scene.id)
                            }
                            .disabled(!model.canManageScenes || model.sceneCaptureEnabled)
                            Button("Delete", role: .destructive) {
                                model.deleteScene(id: scene.id)
                            }
                            .disabled(model.sceneCaptureEnabled)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var commissioningSection: some View {
        GroupBox("Full-Desk Commissioning Exercise") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Destructive test: all 32 faders move together to maximum, then low raw 300, then verified nominal. Each stage is held for three seconds. Transport acceptance and bank connectivity are checked, but you must visually verify physical movement.")
                    .foregroundStyle(.red)

                Text(model.commissioningStatusLine)
                    .font(.headline)

                if let reason = model.commissioningBlockReason,
                   !model.isCommissioningActive {
                    Text("Not ready: \(reason)")
                        .foregroundStyle(.secondary)
                }

                if model.isCommissioningActive {
                    HStack {
                        Button("Stop & Return All to Nominal") {
                            model.stopCommissioningAndRestoreNominal()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Emergency: Stop All MIDI Now", role: .destructive) {
                            model.disableAllMIDITransmission()
                        }
                    }
                } else {
                    Button("Run 32-Channel Exercise…") {
                        showCommissioningConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canStartCommissioningTest)
                }

                Text("A matching MIDI report cannot by itself prove physical movement if ipMIDI is looping the app’s output back to its input. The app blocks an echoed ping and requires intervening travel for each stage, but you must still watch the desk during this test.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var dawTakeoverSection: some View {
        GroupBox("DAW Takeover") {
            VStack(alignment: .leading, spacing: 12) {
                if model.dawTakeoverProfile == .logicProHUI {
                    Text("When enabled, temporary bidirectional HUI port pairs appear only for the selected bank or banks. Configure one Logic HUI device per active bank: Logic input = ‘Bank N Output’; Logic output = ‘Bank N Input’. The bridge forwards raw HUI between Logic and native Ethernet without ipMIDI.")
                } else {
                    Text("Choose “SwiftMix DAW Takeover” as a MIDI input in the DAW. Faders 1–32 publish adjacent 7-bit CC messages; touch states publish notes 36–67. Use MIDI Learn or controller mapping.")
                }

                Picker(
                    "MIDI channel",
                    selection: Binding(
                        get: { model.dawMIDIChannel },
                        set: { model.setDAWMIDIChannel($0) }
                    )
                ) {
                    ForEach(1...16, id: \.self) { channel in
                        Text("\(channel)").tag(channel)
                    }
                }
                .disabled(model.dawTakeoverEnabled)

                Stepper(
                    "Fader CC range: \(model.dawControllerBase)–\(model.dawControllerBase + 31)",
                    value: Binding(
                        get: { model.dawControllerBase },
                        set: { model.setDAWControllerBase($0) }
                    ),
                    in: 0...96
                )
                .disabled(model.dawTakeoverEnabled)

                if model.dawTakeoverEnabled {
                    HStack {
                        Button("Exit & Return All to Nominal") {
                            model.stopDAWTakeoverAndRestoreNominal()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Emergency: Stop All MIDI Now", role: .destructive) {
                            model.disableAllMIDITransmission()
                        }
                    }
                } else {
                    HStack {
                        Button("Enable DAW Takeover…") {
                            showDAWTakeoverConfirmation = true
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canEnableDAWTakeover)

                        Picker(
                            "DAW",
                            selection: Binding(
                                get: { model.dawTakeoverProfile },
                                set: { model.setDAWTakeoverProfile($0) }
                            )
                        ) {
                            ForEach(DAWTakeoverProfile.allCases) { profile in
                                Text(profile.displayName).tag(profile)
                            }
                        }
                        .frame(maxWidth: 240)
                    }

                    Text(model.dawTakeoverProfile.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Picker(
                        "Active fader banks",
                        selection: Binding(
                            get: { model.dawBankSelection },
                            set: { model.setDAWBankSelection($0) }
                        )
                    ) {
                        ForEach(DAWBankSelection.allCases) { selection in
                            Text(selection.displayName).tag(selection)
                        }
                    }

                    if let reason = model.dawTakeoverBlockReason {
                        Text("Not ready: \(reason)")
                            .foregroundStyle(.secondary)
                    }
                }

                Text(model.dawTakeoverProfile == .logicProHUI
                    ? "Logic HUI ports exist only while this preset’s Takeover mode is active. Stopping Takeover closes the selected virtual endpoint pairs and returns only the selected bank or banks to nominal."
                    : "Generic and Ableton profiles are one-way MIDI automation output. Select Logic Pro (HUI Bridge) for bidirectional HUI and motor automation without ipMIDI.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var startupSection: some View {
        GroupBox("Startup") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(
                    "Launch automatically at login",
                    isOn: Binding(
                        get: { model.launchAtLoginEnabled },
                        set: { model.setLaunchAtLogin($0) }
                    )
                )

                Toggle(
                    "Allow outgoing HUI MIDI automatically on future launches",
                    isOn: Binding(
                        get: { model.automaticTransmissionAuthorized },
                        set: { model.setAutomaticTransmissionAuthorized($0) }
                    )
                )
                .disabled(!model.commissioningPassedThisSession && !model.automaticTransmissionAuthorized)

                Text("Fresh installations start in monitor-only mode. Automatic transmission is tied to the exact selected Ethernet service ID and underlying BSD interface and can be authorized only after this session’s full-desk maximum, low, and nominal exercise completes. At a future launch the gate opens only if that same service ID resolves to the authorized BSD interface and is active; the exercise never resumes automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var missingEthernetServiceSelection: some View {
        if let serviceID = model.selectedEthernetServiceID,
           model.selectedEthernetService == nil {
            let savedName = model.selectedEthernetServiceName ?? "Saved Ethernet service"
            let savedBSD = model.selectedEthernetBSDName.map { " · \($0)" } ?? ""
            Text("\(savedName)\(savedBSD) (unavailable)")
                .tag(Optional(serviceID))
        }
    }
}

private struct BankEndpointSettings: View {
    @ObservedObject var model: AppModel
    let bank: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Bank \(bank + 1) · Channels \(bank * 8 + 1)–\(bank * 8 + 8)")
                .font(.headline)

            Picker(
                "Input from SwiftMix",
                selection: Binding<MIDIUniqueID?>(
                    get: { model.routes[bank].sourceUniqueID },
                    set: { model.selectSource(bank: bank, uniqueID: $0) }
                )
            ) {
                Text("Automatic SwiftMix Ethernet Port \(bank + 1)").tag(Optional<MIDIUniqueID>.none)
                missingSourceSelection
                ForEach(model.sources) { endpoint in
                    Text(endpoint.name).tag(Optional(endpoint.uniqueID))
                }
            }

            Picker(
                "Output to SwiftMix",
                selection: Binding<MIDIUniqueID?>(
                    get: { model.routes[bank].destinationUniqueID },
                    set: { model.selectDestination(bank: bank, uniqueID: $0) }
                )
            ) {
                Text("Automatic SwiftMix Ethernet Port \(bank + 1)").tag(Optional<MIDIUniqueID>.none)
                missingDestinationSelection
                ForEach(model.destinations) { endpoint in
                    Text(endpoint.name).tag(Optional(endpoint.uniqueID))
                }
            }
        }
        .padding(.vertical, 4)
        .disabled(model.hasUnsafeActiveMode)
    }

    @ViewBuilder
    private var missingSourceSelection: some View {
        if let uniqueID = model.routes[bank].sourceUniqueID,
           !model.sources.contains(where: { $0.uniqueID == uniqueID }) {
            Text("\(model.routes[bank].sourceName ?? "Saved input") (offline)")
                .tag(Optional(uniqueID))
        }
    }

    @ViewBuilder
    private var missingDestinationSelection: some View {
        if let uniqueID = model.routes[bank].destinationUniqueID,
           !model.destinations.contains(where: { $0.uniqueID == uniqueID }) {
            Text("\(model.routes[bank].destinationName ?? "Saved output") (offline)")
                .tag(Optional(uniqueID))
        }
    }
}
