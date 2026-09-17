# SwiftMix-Revitalized

A macOS menu-bar utility for controlling the motorized faders on the **Rupert Neve Designs SwiftMix** over a dedicated wired Ethernet connection.

SwiftMix Revitalized provides native, interface-bound UDP/HUI communication for up to 32 faders. Its primary purpose is to hold the console’s faders at a physically verified nominal (`0 dB`) position without requiring a third-party ipMIDI driver. It also includes fader scenes, a commissioning exercise, and optional DAW takeover modes.

> [!CAUTION]
> **This software can move motorized faders and change real analog audio levels.** Test only with console inputs, outputs, monitors, headphones, in-ear feeds, recording paths, and other affected signal paths muted or physically disconnected. Nominal Lock is software—not a hard safety interlock—and must not be the only protection for hearing, performers, equipment, or recordings.

## Current status

The current working version supports:

- Native Ethernet MIDI transport for all four SwiftMix banks
- Explicit selection and validation of the wired macOS network service
- Interface-bound multicast sockets, preventing SwiftMix traffic from following the system multicast route onto Wi-Fi
- 8, 16, 24, or 32 active channels
- HUI endpoint discovery, keepalive, and activity monitoring
- Calibration and physical verification of the nominal fader value
- Session-only Nominal Lock with configurable restore tolerance
- Manual “Apply Nominal Now” control
- Capture, storage, recall, and locking of 32-fader scenes
- A destructive full-desk commissioning exercise
- Generic MIDI and Ableton Live takeover profiles
- A bidirectional Logic Pro HUI bridge using temporary CoreMIDI ports
- Launch at Login
- Fail-closed transmission controls and an immediate “Disable All MIDI Transmission” action

This remains a hardware-facing test project. Builds produced by the included packaging script are ad-hoc signed and are **not notarized for public distribution**.

## Requirements

- macOS 13 Ventura or newer
- Apple Silicon or Intel Mac
- Swift 5.9-compatible toolchain (Xcode Command Line Tools or Xcode)
- Rupert Neve Designs SwiftMix
- A dedicated wired Ethernet adapter connected to the SwiftMix
- Audio paths isolated during initial setup and commissioning

## How it works

The app exposes four native SwiftMix Ethernet MIDI banks:

| Bank | Faders | Multicast endpoint |
| --- | ---: | --- |
| 1 | 1–8 | `225.0.0.37:21928` |
| 2 | 9–16 | `225.0.0.37:21929` |
| 3 | 17–24 | `225.0.0.37:21930` |
| 4 | 25–32 | `225.0.0.37:21931` |

Transmit sockets use macOS-assigned ephemeral source ports. UDP sockets are bound directly to the selected BSD network interface rather than relying on the system multicast route.

At startup, a fresh installation is in **monitor-only mode**. Outgoing packets remain blocked until the user selects an exact Ethernet service and explicitly authorizes HUI transmission. Persistent automatic transmission can be enabled only after the full-desk commissioning exercise passes during the current session, and remains tied to the selected network service ID and BSD interface identity.

Nominal Lock itself is always session-only: it starts disabled after every app launch and must be explicitly armed.

## Installation

### Build from source

```sh
git clone <repository-url>
cd <repository-directory>
swift build -c release
```

Run the development build with:

```sh
swift run SwiftMixNominal
```

The application runs as a menu-bar accessory and does not create a Dock icon. Look for the vertical-slider icon in the menu bar.

### Create a distributable test app

The packaging script builds a universal Apple Silicon/Intel app bundle, ad-hoc signs it, creates a ZIP archive, and writes a SHA-256 checksum:

```sh
./Scripts/package-test-app.sh
```

Generated artifacts are placed in `dist/`:

- `SwiftMix-Nominal-Lock-macOS-test.zip`
- `SwiftMix-Nominal-Lock-macOS-test.zip.sha256`

On another Mac, verify the download before opening it:

```sh
shasum -a 256 -c SwiftMix-Nominal-Lock-macOS-test.zip.sha256
```

Because the test app is not Developer ID notarized, macOS may require you to Control-click the app, choose **Open**, and approve that specific app in **System Settings → Privacy & Security**. Do not use broad or recursive quarantine-removal commands.

See [`Packaging/TESTING.md`](Packaging/TESTING.md) for the test-build installation checklist.

## First-time setup

> [!WARNING]
> Do not run this app and another HUI host against the physical SwiftMix at the same time. Quit Logic Pro, Pro Tools, and other control-surface hosts, and disable third-party ipMIDI ports assigned to these banks. Multiple hosts can fight over physical fader positions.

1. Isolate or physically disconnect all affected audio paths.
2. Connect the SwiftMix to a dedicated wired Ethernet adapter.
3. Quit DAWs and disable third-party ipMIDI SwiftMix ports.
4. Launch SwiftMix Nominal Lock and open **Settings…** from the menu-bar icon.
5. Select the exact wired **Ethernet service** connected to the SwiftMix.
6. Click **Use Native Ethernet Ports**.
7. Confirm the active banks use `SwiftMix Ethernet Port 1–4` for input and output.
8. Choose the required channel count: 8, 16, 24, or 32.
9. Enable outgoing HUI MIDI for the current session only after confirming the selected service and BSD interface are correct.
10. Confirm every active bank reports recent HUI activity.
11. Calibrate and physically verify the nominal value before arming Nominal Lock.

The menu-bar icon is bright only when Nominal Lock is verified and armed and every configured bank is online. Test and takeover modes intentionally leave it dim.

## Nominal calibration and lock

The default raw HUI nominal value is **12320**, observed at the printed `0 dB` mark during development. Every physical desk must be verified independently.

Recommended calibration procedure:

1. Keep the signal path safe and Nominal Lock disabled.
2. Place a physical fader exactly at its printed `0 dB` mark.
3. Check the **Last received** raw value in Settings.
4. Use **Use Last Received Value**, or enter the raw value manually.
5. Use **Test Candidate on Fader 1**.
6. Visually confirm the physical position.
7. Choose **Verify 0 dB and Arm Lock** only after verification.

The restore tolerance is configurable from `0` through `512` raw HUI units. A touched fader can briefly alter the real analog level before software detects and restores it.

The SwiftMix MODE switch requests automation-mode changes through its HUI host. This app does not currently interpret mode-button requests or drive the mode LEDs, so mixed LED states must not be treated as a verified READ mode.

## Fader scenes

Scenes capture 32 target positions and persist them locally. Recalling a scene sends all positions immediately and locks each fader to its stored target. A touched fader may be moved temporarily and returns to the scene position after release.

Scene management requires:

- All four banks online
- Outgoing transmission enabled
- A physically verified nominal value
- No commissioning test or DAW takeover in progress
- No detected local MIDI echo

## Full-desk commissioning

The commissioning exercise is destructive and moves all 32 faders together through:

1. Maximum
2. Low raw value `300`
3. Verified nominal

Each position is held for three seconds. Transport acceptance and bank connectivity are checked, but MIDI reports alone cannot prove physical movement. Watch the desk throughout the exercise and visually verify every stage.

The app checks for local echo and intervening fader travel, but these checks do not replace physical observation. Stopping the test returns all faders to nominal. The emergency MIDI stop sends no restoration through an unverified connection.

## DAW takeover

DAW Takeover suspends Nominal Lock while active.

### Generic Linear

Creates a one-way CoreMIDI source named `SwiftMix DAW Takeover`. Faders publish adjacent 7-bit CC messages, and touch states publish notes `36–67`. The MIDI channel and starting CC number are configurable.

### Ableton Live

Uses the same one-way MIDI-learn workflow, with a response curve that maps SwiftMix nominal raw value `12320` to Ableton’s `0 dB` CC value `108`.

### Logic Pro (HUI Bridge)

Creates temporary bidirectional HUI endpoint pairs for the selected bank or banks and bridges raw HUI directly between Logic and native SwiftMix Ethernet.

For each active bank, configure one Logic HUI device:

- Logic input: `Bank N Output`
- Logic output: `Bank N Input`

The virtual ports exist only while takeover is active and are disposed when takeover stops. Remove old ipMIDI HUI assignments before using this mode.

## Development and tests

Build all package targets:

```sh
swift build
```

Run the core self-test executable:

```sh
swift run SwiftMixCoreSelfTests
```

The package also contains hardware-oriented diagnostic executables and scripts:

| Target | Purpose |
| --- | --- |
| `SwiftMixFaderProbe` | Observe and probe fader/HUI behavior through CoreMIDI |
| `SwiftMixCaptureReplay` | Capture and replay MIDI traffic |
| `SwiftMixSineWave` | Exercise faders through CoreMIDI |
| `SwiftMixNativeSineWave` | Exercise faders through native UDP transport |

These tools can move hardware. Review their source and isolate all audio paths before running them.

## Project layout

```text
Sources/
├── SwiftMixNominal/       macOS menu-bar application
├── SwiftMixCore/          HUI parsing, encoding, lock, commissioning, and DAW mapping
├── SwiftMixNativeUDP/     interface-bound multicast transport
├── SwiftMixFaderProbe/    CoreMIDI diagnostic tool
├── SwiftMixCaptureReplay/ capture/replay utility
├── SwiftMixSineWave/      CoreMIDI movement test
└── SwiftMixNativeSineWave/ native UDP movement test
Tests/
└── SwiftMixCoreSelfTests/ executable self-test suite
Packaging/                 app metadata, icon, and testing notes
Scripts/                   packaging and hardware test scripts
Experimental/              isolated transport experiments
```

## Known limitations

- Motor correction occurs in software and cannot prevent every brief analog-level excursion.
- Physical movement must be verified visually; received MIDI may be echoed or otherwise fail to represent motor travel.
- SwiftMix automation mode-button requests and mode LEDs are not managed.
- Generic and Ableton takeover profiles are one-way and do not accept DAW playback automation back to the console.
- Test packages are ad-hoc signed and not notarized.
- Hardware behavior depends on the local network, console state, cabling, and host configuration.

## License and trademark notice

No open-source license is currently included in this repository. Unless a license is added, the source is available for inspection but no general permission to copy, modify, or redistribute it is granted.

SwiftMix and Rupert Neve Designs are trademarks of their respective owners. This project is an independent utility and is not presented as an official Rupert Neve Designs product.
