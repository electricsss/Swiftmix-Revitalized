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
- Bidirectional Logic Pro and Pro Tools HUI bridges using temporary CoreMIDI ports
- Launch at Login
- Fail-closed transmission controls and an immediate “Disable All MIDI Transmission” action

This is hardware-facing software. Release builds produced by the included packaging script are ad-hoc signed and are **not Apple-notarized**, so macOS requires explicit user approval before the first launch.

## Requirements

- macOS 15 Sequoia or macOS 26 Tahoe
- Apple Silicon or a Mac model supported by the installed macOS release
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

### Create the v1.0.0 release app

The packaging script builds a universal Apple Silicon/Intel app bundle, ad-hoc signs it, creates a ZIP archive, and writes a SHA-256 checksum:

```sh
./Scripts/package-release-app.sh
```

Generated artifacts are placed in `dist/`:

- `Swiftmix-Revitalized-1.0.0-macOS.zip`
- `Swiftmix-Revitalized-1.0.0-macOS.zip.sha256`

On another Mac, verify the download before opening it:

```sh
shasum -a 256 -c Swiftmix-Revitalized-1.0.0-macOS.zip.sha256
```

Because the release is not Developer ID notarized, macOS may require you to Control-click the app, choose **Open**, and approve that specific app in **System Settings → Privacy & Security**. Do not use broad or recursive quarantine-removal commands.

See [`Packaging/INSTALLATION.md`](Packaging/INSTALLATION.md) for the release installation checklist.

## First startup

### 1. Approve the app in Privacy & Security

This release is ad-hoc signed and is not notarized, so macOS may block its first launch.

1. Unzip the download and move `Swiftmix-Revitalized.app` into `/Applications`.
2. Try to open the app once. If macOS blocks it, open **System Settings → Privacy & Security**.
3. Scroll to the **Security** section and find the message that `Swiftmix-Revitalized` was blocked.
4. Click **Open Anyway**, authenticate if requested, and then confirm **Open**.
5. Alternatively, Control-click `Swiftmix-Revitalized.app` in Finder, choose **Open**, and confirm the exception.
6. Do not use broad or recursive quarantine-removal commands.

The application is a menu-bar utility and does not open a Dock window. After launch, look for the vertical-slider icon in the menu bar and choose **Settings…**.

### 2. Prepare the console and connection

> [!WARNING]
> Do not run this app and another HUI host against the physical SwiftMix at the same time. Multiple hosts can fight over physical fader positions and change real analog levels.

1. Mute or physically disconnect console inputs, outputs, monitors, headphones, in-ear feeds, recording paths, and all other affected audio paths.
2. Connect the SwiftMix to a dedicated wired Ethernet adapter.
3. Quit Logic Pro, Pro Tools, Ableton Live, and other control-surface hosts.
4. Disable or remove third-party ipMIDI assignments for the SwiftMix banks. Native Ethernet mode does not require ipMIDI.
5. Leave **Nominal Lock** disabled until calibration is complete.

### 3. Choose the Ethernet interface and refresh devices

1. Open **Settings…** from the menu-bar icon.
2. Under **SwiftMix Connection**, click **Rescan Interfaces**.
3. In **Ethernet service**, select the exact wired macOS network service connected to the SwiftMix. Do not select Wi-Fi or an unrelated Ethernet adapter.
4. Check the status line and confirm that it shows the expected BSD interface, such as `en5`, and that the service is active.
5. Choose the number of connected channels: **8**, **16**, **24**, or **32**. Each group of eight channels enables another SwiftMix bank.
6. Click **Use Native Ethernet Ports** to assign the app's native ports automatically.
7. Click **Rescan** to refresh the available MIDI endpoints.
8. Confirm that every active bank uses the corresponding `SwiftMix Ethernet Port 1–4` input and output.
9. Click **Enable for This Session…**, review the warning, and choose **Enable HUI Transmission** only after confirming the interface and isolated signal path.
10. Wait for every configured bank to report recent HUI activity. Do not calibrate, commission, or enable DAW Takeover while a required bank is offline.

**Rescan Interfaces** refreshes macOS network services and adapters. **Rescan** refreshes MIDI endpoints and clears stale endpoint discovery state. If an adapter, cable, channel count, or MIDI configuration changes, run the appropriate rescan and verify every selection again.

### 4. Confirm nominal and calibrate the level markers

The app must learn the physical desk's printed fader positions. Do not assume the default raw value is correct for every SwiftMix.

1. Keep all affected audio paths muted or disconnected and keep **Nominal Lock** disabled.
2. Move one physical fader exactly to its printed **0 dB** mark.
3. In **Nominal Calibration**, confirm that **Last received** shows that fader's channel and raw HUI value.
4. Click **Use Last Received Value** to make that value the nominal candidate.
5. Click **Test Candidate on Fader 1**, approve the warning, and visually confirm that fader 1 moves exactly to the printed `0 dB` mark.
6. Click **Verify 0 dB and Arm Lock** only after the physical position has been confirmed. This sends the verified value to every configured fader.
7. Disable **Nominal Lock** again before moving a fader by hand to calibrate the remaining markers.
8. For each additional preset—**-5 dB**, **-10 dB**, **-15 dB**, and **-20 dB**—move a physical fader exactly to the corresponding printed mark and confirm the new **Last received** value.
9. Click **Use Last Received** beside that specific marker. Repeat separately for every marker; do not reuse an assumed value or calculate one from another marker.
10. Test the menu-bar **Set Faders to** choices while the signal path remains isolated, and visually confirm every calibrated position before reconnecting audio.

The marker values are saved on the Mac. Uncalibrated markers remain unavailable in the **Set Faders to** menu. The menu-bar icon is bright only when Nominal Lock is verified and armed and all configured banks are online; commissioning and DAW Takeover intentionally leave it dim.

### 5. Configure DAW control

Complete interface selection, endpoint discovery, nominal verification, and bank connectivity before enabling DAW Takeover. DAW Takeover suspends Nominal Lock while active.

1. Keep other HUI hosts and old ipMIDI SwiftMix assignments disabled while configuring the app.
2. In **Settings → DAW Takeover**, choose a **DAW** profile and the required **Active fader banks**.
3. For **Generic Linear** or **Ableton Live**, choose the MIDI channel and starting CC range before enabling takeover.
4. Click **Enable DAW Takeover…**, review the safety warning, and select **Enable Selected DAW Mode**.
5. Configure the DAW as described below. Ports created by a HUI Bridge exist only while takeover is active.
6. When finished, use **Exit & Return All to Nominal** and visually confirm the desk before reconnecting audio. Use **Emergency: Stop All MIDI Now** only when an immediate stop is required; an emergency stop does not guarantee restoration to nominal.

#### Generic Linear

1. In the DAW, enable `SwiftMix DAW Takeover` as a MIDI input.
2. Use MIDI Learn or the DAW's controller mapping to assign the adjacent fader CC messages.
3. Faders 1–32 use the configured CC range and MIDI channel; touch states publish notes `36–67`.
4. This profile is one-way: DAW playback automation does not drive the SwiftMix motors.

#### Ableton Live

1. In Live's MIDI settings, enable `SwiftMix DAW Takeover` as a track/remote input as required by the mapping workflow.
2. Use MIDI Map Mode to assign the faders.
3. The Ableton response curve maps SwiftMix nominal raw value `12320` to Ableton's `0 dB` CC value `108`.
4. This profile is one-way and does not return Live automation to the console.

#### Logic Pro HUI Bridge

For each active bank, add one HUI control surface in Logic and configure:

- Logic input: `SwiftMix Logic Pro HUI Bank N Output`
- Logic output: `SwiftMix Logic Pro HUI Bank N Input`

Use the matching bank number on both sides. Remove old ipMIDI HUI assignments before enabling the bridge.

This mode carries the original bidirectional HUI control data rather than translating the faders to generic MIDI CC messages. Logic's normal HUI fader assignments, touch handling, motor feedback, automation behavior, and other controls supported by the original SwiftMix/Logic design therefore apply while the bridge is active. Any Logic-specific HUI limitations still apply.

#### Pro Tools HUI Bridge

In **Pro Tools → Setup → Peripherals → MIDI Controllers**, add one HUI peripheral for each active bank:

- Type: **HUI**
- Channels: **8**
- Receive From: `SwiftMix Pro Tools HUI Bank N Output`
- Send To: `SwiftMix Pro Tools HUI Bank N Input`

Use the matching bank number for each peripheral. This mode carries the original bidirectional HUI control data rather than translating the faders to generic MIDI CC messages. Pro Tools' normal HUI fader assignments, touch handling, motor feedback, automation behavior, and other controls supported by the original SwiftMix/Pro Tools design therefore apply while the bridge is active. Any Pro Tools-specific HUI limitations still apply.

The Logic and Pro Tools bridges are bidirectional and pass raw HUI between the DAW and the selected native SwiftMix Ethernet banks.

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

Creates temporary bidirectional HUI endpoint pairs for the selected bank or banks and bridges raw HUI directly between Logic and native SwiftMix Ethernet. Because this is a raw HUI bridge—not a generic CC mapping—Logic's normal HUI fader assignments, touch handling, motor feedback, automation behavior, and other controls supported by the original SwiftMix/Logic design apply while the bridge is active.

For each active bank, configure one Logic HUI device:

- Logic input: `SwiftMix Logic Pro HUI Bank N Output`
- Logic output: `SwiftMix Logic Pro HUI Bank N Input`

The virtual ports exist only while takeover is active and are disposed when takeover stops. Remove old ipMIDI HUI assignments before using this mode. Any Logic-specific HUI limitations still apply.

### Pro Tools (HUI Bridge)

Creates temporary bidirectional HUI endpoint pairs for the selected bank or banks and bridges raw HUI directly between Pro Tools and native SwiftMix Ethernet. Because this is a raw HUI bridge—not a generic CC mapping—Pro Tools' normal HUI fader assignments, touch handling, motor feedback, automation behavior, and other controls supported by the original SwiftMix/Pro Tools design apply while the bridge is active.

In **Pro Tools → Setup → Peripherals → MIDI Controllers**, configure one HUI peripheral for each active bank:

- Type: **HUI**
- Channels: **8**
- Receive From: `SwiftMix Pro Tools HUI Bank N Output`
- Send To: `SwiftMix Pro Tools HUI Bank N Input`

Use the same bank number for the input and output of each peripheral. The virtual ports exist only while takeover is active and are disposed when takeover stops. Remove old ipMIDI HUI assignments before using this mode. Any Pro Tools-specific HUI limitations still apply.

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
Packaging/                 app metadata, icon, and installation notes
Scripts/                   packaging and hardware test scripts
Experimental/              isolated transport experiments
```

## Known limitations

- Motor correction occurs in software and cannot prevent every brief analog-level excursion.
- Physical movement must be verified visually; received MIDI may be echoed or otherwise fail to represent motor travel.
- SwiftMix automation mode-button requests and mode LEDs are not managed.
- Generic and Ableton takeover profiles are one-way and do not accept DAW playback automation back to the console.
- Release packages are ad-hoc signed and not Apple-notarized.
- Hardware behavior depends on the local network, console state, cabling, and host configuration.

## License and trademark notice

This project is distributed under the BSD 2-Clause–style license in [`LICENSE`](LICENSE). It permits use, modification, and redistribution while requiring preservation of the copyright notice, license conditions, and disclaimer.

SwiftMix and Rupert Neve Designs are trademarks of their respective owners. This project is an independent utility and is not presented as an official Rupert Neve Designs product.
