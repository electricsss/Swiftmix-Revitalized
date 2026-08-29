import CoreMIDI
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var showTestConfirmation = false
    @State private var showVerificationConfirmation = false
    @State private var showTransmissionConfirmation = false
    @State private var showCommissioningConfirmation = false
    @State private var showDAWTakeoverConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusSection
                safetySection
                connectionSection
                calibrationSection
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
            Text("This command can immediately change the analog level, recording level, and monitor feeds on channel 1. Confirm that the studio is in a safe state first.")
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
            Text("This drives channel 1 through 32 one at a time: maximum, minimum (−∞), then verified nominal, waiting for position reports at every step. After all 32 report nominal, Vegas mode runs continuously across the desk until you stop it. Confirm that all console inputs, outputs, Pro Tools paths, speakers, headphones, and in-ear feeds are muted or physically disconnected.")
        }
        .alert("Enable DAW Takeover?", isPresented: $showDAWTakeoverConfirmation) {
            Button("Enable Generic MIDI Takeover", role: .destructive) {
                model.enableDAWTakeover()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Nominal Lock will be suspended while takeover is active. Moving a physical fader to write DAW automation also changes the console’s real analog level. Keep audio paths safe until this behavior is intentional and verified. This first takeover stage sends controller data to the DAW but does not accept DAW playback commands back to the console.")
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

                Text("The app must be the sole HUI host on these ipMIDI ports. Remove the same SwiftMix HUI peripheral mappings from Pro Tools or the two hosts can fight over fader positions.")
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
                    }
                }

                ForEach(0..<model.activeBankCount, id: \.self) { bank in
                    BankEndpointSettings(model: model, bank: bank)
                }

                HStack {
                    Button("Auto-Configure ipMIDI Ports") {
                        model.autoConfigureIPMIDIPorts()
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
                    Text("Not verified. The initial 13168 value comes from another calibrated HUI surface and may not be exact for SwiftMix.")
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

                Text("For capture calibration, disable Nominal Lock, place one physical fader exactly at its printed 0 dB mark, then use the last received value above. Re-enable the lock only after the studio signal path is safe.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var commissioningSection: some View {
        GroupBox("Full-Desk Commissioning Exercise") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Destructive test: every fader reaches maximum, minimum (−∞), and verified nominal in strict channel order. Raw position reports—not just successful MIDI sends—advance the sequence. The routine then enters continuous Vegas wave mode.")
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
        GroupBox("DAW Takeover · Generic MIDI") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose “SwiftMix DAW Takeover” as a MIDI input in the DAW. Faders 1–32 publish adjacent 7-bit CC messages; touch states publish notes 36–67. Use the DAW’s MIDI Learn or controller-mapping feature to write automation.")

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
                    Button("Enable DAW Takeover…") {
                        showDAWTakeoverConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canEnableDAWTakeover)

                    if let reason = model.dawTakeoverBlockReason {
                        Text("Not ready: \(reason)")
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Current scope: generic one-way MIDI automation output. Native Pro Tools mixer control requires a bidirectional HUI proxy; do not map Pro Tools directly to the four physical ipMIDI ports while this app is the SwiftMix host.")
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

                Text("Fresh installations start in monitor-only mode. Automatic transmission can be authorized only after this session’s complete 32-channel exercise reaches Vegas mode; the exercise itself never resumes automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
                Text("Automatic ipMIDI Port \(bank + 1)").tag(Optional<MIDIUniqueID>.none)
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
                Text("Automatic ipMIDI Port \(bank + 1)").tag(Optional<MIDIUniqueID>.none)
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
