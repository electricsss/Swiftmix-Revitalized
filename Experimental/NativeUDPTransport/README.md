# Experimental Native ipMIDI UDP Transport

This is a standalone, nested Swift package for a deliberately isolated native-UDP experiment. It does not replace or modify the repository's existing CoreMIDI/ipMIDI application. The only link to the repository root is a read-only local Swift package dependency on the existing `SwiftMixCore` product for conservative MIDI/HUI parsing.

> **Safety status:** receive-only is the default. `swiftmix-udp-capture` has no transmit command and sends zero packets. Library transmission is denied unless a caller deliberately constructs `.verified(...)` authorization containing both a packet-capture identifier and a protocol-revision identifier. Nothing arms transmission automatically.

## Requirements

- macOS 13 or newer
- Swift 5.9 or newer
- An explicitly selected, active, multicast-capable BSD interface with exactly one IPv4 address
- No third-party dependencies; only Apple system frameworks and the local root `SwiftMixCore` product

## Package layout

```text
NativeUDPTransport/
├── .gitignore
├── Package.swift
├── README.md
└── Sources/
    ├── NativeUDPTransport/
    │   ├── CaptureEncoding.swift
    │   ├── Configuration.swift
    │   ├── ConservativeMIDIDecoder.swift
    │   ├── InterfaceResolver.swift
    │   ├── NativeUDPError.swift
    │   ├── NativeUDPTransport.swift
    │   └── WireProfile.swift
    ├── NativeUDPTransportSelfTests/
    │   └── main.swift
    └── SwiftMixUDPCapture/
        └── main.swift
```

## Architecture and interface isolation

One Darwin `SOCK_DGRAM` socket is created per selected logical bank. Startup is all-or-nothing:

1. Resolve the **exact required BSD name** with `if_nametoindex` and `getifaddrs`.
2. Reject a missing/down/non-multicast interface, no IPv4 address, or multiple IPv4 addresses. Ambiguity is an error; there is no route lookup and no fallback.
3. For each bank, set `SO_REUSEADDR` and `SO_REUSEPORT`.
4. Set macOS `IP_BOUND_IF` to the resolved interface index.
5. Set `IP_MULTICAST_IF` to that same interface's exact IPv4 address.
6. Bind `INADDR_ANY` only after the socket is constrained by `IP_BOUND_IF`, using the bank's local UDP port.
7. Join `225.0.0.37` using `IP_ADD_MEMBERSHIP` with the selected interface IPv4—not `INADDR_ANY`.
8. Configure provisional send defaults (`IP_MULTICAST_TTL=1`, `IP_MULTICAST_LOOP=0`) even though transmission remains unauthorized by default.
9. Switch the socket to nonblocking mode and attach it to one private serial `DispatchQueue`.

If any bank fails, every socket opened during that start attempt is closed. `start` and `stop` are idempotent, and `stop` is safe from a receive callback. A fatal receive error stops all sockets. Every accepted packet records:

- logical bank
- local destination/bound UDP port
- source IPv4 address and source UDP port
- userspace receive timestamp taken immediately after `recvfrom`
- bounded raw payload bytes

Datagrams larger than the configured bound are dropped and surfaced as receive failures. The default bound is the maximum IPv4 UDP payload, 65,507 bytes. There is no future-timestamped, delayed, scheduled, or queued transmit behavior.

## Known external evidence vs. unverified target assumptions

All wire values are intentionally represented by `ProvisionalWireAssumption` and carry the state `unverifiedAgainstTargetConsoleAndTrialDriver`. “Known” below means documented or demonstrated by the cited source; it does **not** mean verified against this console and trial-driver combination.

| Item | External evidence / conservative choice | Status for target setup |
|---|---|---|
| Multicast group | `225.0.0.37` appears in the Arduino example and SSL help | **UNVERIFIED** |
| Base UDP port | `21928` appears in the Arduino example | **UNVERIFIED** |
| Four logical banks | Current experiment scope | **UNVERIFIED** |
| Bank mapping | probable bank 1 → `21928`, bank 2 → `21929`, bank 3 → `21930`, bank 4 → `21931` | **UNVERIFIED** |
| Payload packing | likely raw MIDI 1.0 bytes in each UDP datagram, based on the Arduino example | **UNVERIFIED** |
| Send TTL | `1`, selected here as a conservative link-local default | **UNVERIFIED** |
| Local multicast loopback | off, consistent with SSL guidance and conservative send behavior | **UNVERIFIED** |
| macOS interface selection | SSL documents binding/routing concerns; this experiment additionally enforces `IP_BOUND_IF`, membership interface, and `IP_MULTICAST_IF` | Must be capture-tested |
| Transport semantics | ipMIDI uses multicast UDP, as described by nerds.de | Must be capture-tested |

### Sources

- Arduino ipMIDI multicast example—multicast `225.0.0.37`, base port `21928`, and raw MIDI-style byte packing: <https://raw.githubusercontent.com/djbottrill/IPMidi_example/master/IPMidi_Multicast_Example.ino>
- Solid State Logic ipMIDI help—multicast group, macOS route/interface binding guidance, and multicast loopback off: <https://livehelp.solidstatelogic.com/Help/ipMIDI.html>
- nerds.de ipMIDI overview—multicast UDP semantics: <https://www.nerds.de/en/ipmidi.html>

## Build and deterministic self-tests

Run commands from this directory only:

```sh
swift build
swift run native-udp-self-tests
```

The self-test executable uses simple deterministic assertions rather than XCTest. It validates bank/port bounds, multicast/profile/config rejection, transmission-policy rejection, raw hex and exact JSONL encoding, ping request/reply decoding, and HUI fader pairs through root `SwiftMixCore`. It deliberately does not instantiate/start the transport or open sockets.

## Receive-only capture command

Do not substitute an interface name. Identify the intended wired BSD interface first, then pass it explicitly:

```sh
swift run swiftmix-udp-capture --interface <WIRED_BSD> --banks 1-4
```

JSON Lines output can be redirected into this package's ignored `captures/` directory:

```sh
mkdir -p captures
swift run swiftmix-udp-capture --interface <WIRED_BSD> --banks 1-4 --jsonl > captures/native-receiver.jsonl
```

`<WIRED_BSD>` is a placeholder, not a literal interface name. The command prints a receive-only warning, contains no transmit option, and sends zero packets. Press Ctrl-C for an orderly stop. Its decoder is deliberately labeled conservative: it feeds the provisional raw payload into independent per-bank `SwiftMixCore.MIDIMessageStreamParser` and `HUIFaderParser` state, but does not claim the UDP payload format is correct before capture verification.

## tcpdump examples for tomorrow

Both names below are placeholders. Replace them with the exact BSD names observed on the test Mac:

```sh
sudo tcpdump -ni <WIRED_BSD> -s 0 -vvv -tttt -XX \
  'udp and host 225.0.0.37 and portrange 21928-21931'
```

Write a full wired capture:

```sh
mkdir -p captures
sudo tcpdump -ni <WIRED_BSD> -s 0 \
  'udp and host 225.0.0.37 and portrange 21928-21931' \
  -w captures/ipmidi-wired.pcap
```

Simultaneously watch a second interface to detect route drift or unwanted duplication:

```sh
sudo tcpdump -ni <SECOND_BSD> -s 0 -vvv -tttt -XX \
  'udp and host 225.0.0.37 and portrange 21928-21931'
```

Write that comparison capture separately:

```sh
sudo tcpdump -ni <SECOND_BSD> -s 0 \
  'udp and host 225.0.0.37 and portrange 21928-21931' \
  -w captures/ipmidi-second-interface.pcap
```

`<SECOND_BSD>` is also a placeholder. It should identify the comparison interface (for example, Wi-Fi), not the selected wired interface.

## Tomorrow's exact trial-driver comparison plan

Do not enable library transmission during this plan. Any transmitted packets should come only from the trial ipMIDI driver/console under observation.

1. **Record configuration:** note macOS version, trial-driver version, console firmware, `<WIRED_BSD>`, wired IPv4, `<SECOND_BSD>`, second-interface IPv4, and route table before changing anything.
2. **Driver-off baseline:** with the trial driver stopped/disabled, run tcpdump on both interfaces for a fixed 60-second window. Confirm whether any pre-existing traffic already uses `225.0.0.37` or ports `21928...21931`.
3. **Receiver coexistence baseline:** start tcpdump first, then start the receive-only CLI on `<WIRED_BSD>`. Verify the CLI itself adds no outbound packets on either interface. Record whether all four bank sockets can bind while the driver is off.
4. **Driver-on idle sample:** enable the trial driver without touching controls. Capture both interfaces and JSONL for 60 seconds. Record periodic traffic, source/destination endpoints, TTL, and loopback observations.
5. **Bank mapping:** enable/select one driver UI bank/port at a time. Capture at least 15 seconds per UI selection. Build a table from the driver's displayed numbering/name to observed destination and source ports; do not assume UI bank 1 is UDP `21928`.
6. **Known actions:** for each bank, perform one isolated action at a logged wall-clock time: ping/online transition if exposed, then one fader movement up, pause, and down. Avoid simultaneous controls. Compare raw datagrams with conservative MIDI/HUI labels.
7. **Aggregation tests:** perform two quick movements and then a sustained movement. Determine whether messages are aggregated, split across packets, or encoded using MIDI running status across datagrams.
8. **Direction test:** correlate console-originated control movement and driver-originated keepalive/response traffic. Identify sender IP and which endpoint initiates/responds.
9. **Interface enforcement test:** while capturing both interfaces, change only the trial driver's documented interface/route preference. Verify exactly where driver traffic appears. Do not change this library's required interface during a run.
10. **Port-sharing test:** compare driver-only, receiver-only, driver-started-first, and receiver-started-first runs. Record bind failures and whether both can receive the same multicast datagrams. This explicitly tests `SO_REUSEADDR`/`SO_REUSEPORT` coexistence rather than assuming it.
11. **Loopback test:** compare local observations with and without the driver running and inspect packet captures for local copies. Do not infer `IP_MULTICAST_LOOP` solely from duplicate application logs.
12. **Freeze a revision:** hash/name the retained `.pcap` files, write a short protocol revision (for example `trial-driver-observation-r1`), and update the provisional profile only after the evidence is reviewed. Those two identifiers are the minimum data required to construct future `.verified(...)` transmission authorization.

### Unknowns that must be captured

- driver UI bank numbering/naming versus UDP ports
- source UDP ports and destination UDP ports
- exact payload bytes
- packet aggregation, splitting, and MIDI running-status behavior across datagrams
- sender IPv4 address for each direction
- observed IP TTL
- multicast loopback behavior
- request/response direction, including ping ownership
- packet and response timing
- whether the trial driver and native receiver can share the bank ports

## Transmission policy for future integration

The library exposes an immediate `send(_:on:)` API solely for later controlled integration. Its default authorization is `.denied`, which throws `transmissionNotAuthorized` before checking transport/socket state. A future caller must deliberately provide both evidence identifiers:

```swift
let evidence = try ProtocolVerification(
    captureIdentifier: "sha256-or-capture-id",
    protocolRevision: "reviewed-protocol-r1"
)
let transport = NativeUDPTransport(
    configuration: configuration,
    receiveAuthorization: .receiveOnly,
    transmissionAuthorization: .verified(evidence)
)
```

That construction does not send by itself. There is no automatic arming, keepalive, timer, queue, or future-timestamp API. The capture executable never constructs verified authorization and has no code path that calls `send`.
