# Swiftmix-Revitalized — second-Mac test build

## Requirements

- macOS 15 Sequoia or macOS 26 Tahoe.
- Apple Silicon or a Mac model supported by the installed macOS release.
- A dedicated wired Ethernet adapter connected to the SwiftMix.
- Audio paths physically isolated for the first test.
- Logic Pro, Pro Tools, ipMIDI, and other HUI hosts stopped during native transport testing.

## Transfer and verify

Transfer both files from `dist/`:

- `Swiftmix-Revitalized-macOS-test.zip`
- `Swiftmix-Revitalized-macOS-test.zip.sha256`

In Terminal on the receiving Mac, change to the folder containing them and run:

```sh
shasum -a 256 -c Swiftmix-Revitalized-macOS-test.zip.sha256
```

The result must say `OK`.

## Install an ad-hoc test build

1. Double-click the ZIP.
2. Drag `Swiftmix-Revitalized.app` into `/Applications`.
3. Because this test build is not Developer ID notarized, Control-click the app and choose **Open**, then confirm **Open**. If macOS still blocks it, open **System Settings → Privacy & Security** and approve this specific app.
4. Do not remove quarantine with a broad or recursive command. Approve only this app through Finder/System Settings.

The app is a menu-bar utility and does not open a Dock window. Look for the vertical-slider icon in the menu bar.

## First native Ethernet test

1. Keep audio disconnected/isolated.
2. Quit all DAWs and disable the third-party ipMIDI SwiftMix ports.
3. Open the app’s Settings.
4. Select the exact wired Ethernet service connected to the SwiftMix.
5. Click **Use Native Ethernet Ports**.
6. Verify Banks 1–4 show `SwiftMix Ethernet Port 1–4` for input and output.
7. Enable HUI transmission only after confirming the selected BSD interface identity.
8. Verify all four banks receive HUI activity before commissioning or applying nominal.

Native UDP uses:

```text
225.0.0.37:21928 → channels 1–8
225.0.0.37:21929 → channels 9–16
225.0.0.37:21930 → channels 17–24
225.0.0.37:21931 → channels 25–32
```

Transmit sockets use macOS-assigned ephemeral source ports. The sockets are bound directly to the selected Ethernet interface and do not rely on the system multicast route.

## Safety and limitations

- This package is for controlled testing, not public distribution.
- It is ad-hoc signed and not notarized.
- Launch at Login may require approval and should be tested only after normal launch succeeds.
- Never run the app and a DAW/ipMIDI HUI host against the physical SwiftMix simultaneously.
- Emergency Stop intentionally sends no restoration through an unverified connection.
