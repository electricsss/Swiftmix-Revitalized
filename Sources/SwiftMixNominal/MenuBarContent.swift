import AppKit
import SwiftUI

struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    let openSettings: () -> Void

    var body: some View {
        Text(model.statusLine)

        if let issue = model.lastIssue {
            Text("Issue: \(issue)")
            Button("Dismiss Issue") {
                model.clearLastIssue()
            }
        }

        Divider()

        if model.isCommissioningActive {
            Button("Stop Test & Return All to Nominal") {
                model.stopCommissioningAndRestoreNominal()
            }
        }

        if model.dawTakeoverEnabled {
            Button("Exit DAW Takeover & Return Nominal") {
                model.stopDAWTakeoverAndRestoreNominal()
            }
        }

        if model.transmissionEnabled {
            Button("Disable All MIDI Transmission Now", role: .destructive) {
                model.disableAllMIDITransmission()
            }
        }

        Toggle(
            "Nominal Lock",
            isOn: Binding(
                get: { model.nominalLockEnabled },
                set: { model.setNominalLockEnabled($0) }
            )
        )
        .disabled(model.hasUnsafeActiveMode)

        Button("Apply Nominal Now") {
            model.applyNominalToAllFaders()
        }
        .disabled(!model.canApplyNominal)

        FaderLevelPicker(
            activeLevel: model.activeFaderLevel,
            availableLevels: Set(
                FaderLevelPreset.allCases.filter { model.rawValue(for: $0) != nil }
            ),
            isEnabled: model.canSetFaderLevel,
            onSelect: model.applyFaderLevel
        )
        .equatable()

        Divider()

        Text("Snapshot Quick Recall")
        if model.scenes.isEmpty {
            Text("No Saved Snapshots")
        } else {
            ForEach(model.scenes) { scene in
                Button(model.activeSceneID == scene.id ? "✓ \(scene.name)" : scene.name) {
                    model.recallScene(id: scene.id)
                }
                .disabled(!model.canManageScenes || model.sceneCaptureEnabled)
            }
        }

        Divider()

        Toggle(
            "Launch at Login",
            isOn: Binding(
                get: { model.launchAtLoginEnabled },
                set: { model.setLaunchAtLogin($0) }
            )
        )

        Button("Settings…") {
            openSettings()
        }
        .keyboardShortcut(",")

        Divider()

        Button(model.hasUnsafeActiveMode ? "Stop Active Mode Before Quitting" : "Quit SwiftMix Nominal Lock") {
            NSApp.terminate(nil)
        }
        .disabled(model.hasUnsafeActiveMode)
        .keyboardShortcut("q")
    }
}

private struct FaderLevelPicker: View, Equatable {
    let activeLevel: FaderLevelPreset?
    let availableLevels: Set<FaderLevelPreset>
    let isEnabled: Bool
    let onSelect: (FaderLevelPreset) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.activeLevel == rhs.activeLevel
            && lhs.availableLevels == rhs.availableLevels
            && lhs.isEnabled == rhs.isEnabled
    }

    var body: some View {
        Picker(
            "Set Faders to",
            selection: Binding<FaderLevelPreset?>(
                get: { activeLevel },
                set: { preset in
                    if let preset { onSelect(preset) }
                }
            )
        ) {
            Text("Choose Level…").tag(Optional<FaderLevelPreset>.none)
            ForEach(FaderLevelPreset.allCases) { preset in
                Text(preset.displayName)
                    .tag(Optional(preset))
                    .disabled(!availableLevels.contains(preset))
            }
        }
        .disabled(!isEnabled)
    }
}
