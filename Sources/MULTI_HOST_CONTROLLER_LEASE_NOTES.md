# SwiftMix Multi-Host Controller Notes

## Status

**Deferred idea — not implemented.**

This note records the investigation into connecting multiple computers to one SwiftMix system and a possible future cooperative controller-handoff feature. The current application should continue to assume that it is the sole active HUI host whenever transmission is enabled.

## Question that prompted this note

Could two computers connected to the same SwiftMix Ethernet network both run SwiftMix Nominal Lock, with an app-specific signature or IP-address check allowing one computer to place the other in monitor-only mode and take control of automation?

## Findings from the SwiftMix manual

The included user guide is:

`Sources/Rupert Neve Designs SwiftMix Instruction Manual - Manuals+.pdf`

The manual explicitly describes an Ethernet-switch topology. Its hardware setup directs the user to:

1. Connect the router/LAN to the included Ethernet Gigabit Switch.
2. Connect the host DAW computer to that switch.
3. Connect the SwiftMix SMP-1 to that switch.

Therefore, operating the SwiftMix through a network switch is an intended configuration. The manual consistently refers to one singular host DAW computer, however, and does not document simultaneous control by multiple HUI hosts.

The SMP-1 is documented as having one RJ-45 Ethernet connection. Additional computers would therefore normally share the SwiftMix network through the switch rather than connect to separate SMP-1 computer ports.

## Relevant network behavior

SwiftMix MIDI/HUI traffic uses ipMIDI-style multicast UDP rather than a normal one-to-one connection to a fixed SwiftMix destination IP. The currently verified application endpoints are:

| Bank | Faders | Multicast endpoint |
| --- | ---: | --- |
| 1 | 1–8 | `225.0.0.37:21928` |
| 2 | 9–16 | `225.0.0.37:21929` |
| 3 | 17–24 | `225.0.0.37:21930` |
| 4 | 25–32 | `225.0.0.37:21931` |

Every computer on the same multicast-capable network that joins those groups can potentially receive the same SwiftMix messages. The multicast group is a shared destination, not the SMP-1's unique fixed address. A host IP address may also change through DHCP and is not a reliable application identity.

Consequently:

- Multiple computers may be physically connected to the switch.
- Multiple computers may receive or monitor the multicast traffic.
- Only one computer or HUI host should transmit control data to the SwiftMix at a time.
- Two independent transmitting hosts can send duplicate or conflicting keepalives, motor positions, scenes, automation state, or DAW bridge data.

The project currently warns against multiple active HUI hosts in `README.md` and `Packaging/TESTING.md`.

## Current application safeguards

The application already has a centralized transmission gate:

- `AppModel.enableHUITransmissionForSession()` enables transmission.
- `AppModel.disableAllMIDITransmission()` closes transmission without sending cleanup or restoration packets.
- `CoreMIDIService.send(...)` checks `transmissionEnabled` before every outgoing packet.
- The Settings UI exposes explicit monitor-only and transmission-enabled states.
- Incoming HUI host pings or host LED messages are treated as possible loopback/foreign-host traffic and cause transmission to fail closed.

These are useful foundations for a future multi-host coordination feature. At present, two transmitting app instances may detect each other's host traffic and both shut down rather than perform an orderly handoff.

## Deferred design: cooperative controller lease

If requested later, implement a small app-to-app coordination protocol on a **separate UDP multicast port**. Do not put an app signature inside the SwiftMix MIDI/HUI payloads on ports `21928–21931`; unknown bytes might be interpreted as MIDI by the SMP-1.

Each app installation should identify itself with:

- A persistent installation UUID.
- A per-launch instance UUID.
- A human-readable computer name.
- A coordination protocol version.
- A controller state such as `monitoring`, `requesting`, `controlling`, or `yielding`.
- A controller term/generation and short-lived lease expiration.
- Optionally, an authenticated pairing identity or shared secret.

The source IP can be included for diagnostics, but it should not be the primary identity or authority check.

### Suggested handoff

When a monitoring computer requests control:

1. The requester sends `REQUEST_CONTROL`.
2. The current controller remains authoritative until it explicitly yields.
3. The current controller closes its low-level MIDI transmission gate first.
4. It cancels or suspends keepalives, Nominal Lock correction, scenes, commissioning, and DAW takeover.
5. It sends `CONTROL_RELEASED` only after transmission has been closed.
6. The requester waits for that acknowledgment and a short quiet interval.
7. The requester acquires the lease and opens its transmission gate.
8. The previous controller remains monitor-only.

The critical invariant is:

> The old controller must stop transmitting before the new controller starts.

Sending a request must never by itself enable transmission on the requester.

### Heartbeats and failure behavior

The active controller could advertise a heartbeat approximately every 250–500 milliseconds, with a lease lasting roughly 1.5–3 seconds.

If the heartbeat disappears:

- The standby should remain monitor-only.
- The UI should report that no active coordinated controller is visible.
- Taking control should require an explicit operator action and a quiet interval.
- The operator should be warned to verify that the previous controller is stopped.

Immediate automatic failover is unsafe because loss of coordination traffic may be a network partition rather than a crashed controller. During a partition, the original controller might still be able to send HUI packets to the SwiftMix.

Absolute split-brain prevention cannot be guaranteed by two peer computers communicating over an unreliable network. Stronger guarantees would require an independent arbitrator or a hardware transmission gate.

### Required low-level enforcement

Lease ownership must be checked in the final send path, not only in the UI. Conceptually, `CoreMIDIService.send(...)` should require all of the following:

```swift
guard transmissionEnabled,
      controllerLease.isLocallyHeld,
      !controllerLease.isExpired,
      !transmissionSuspendedBanks.contains(bank),
      !payload.isEmpty
else {
    return nil
}
```

This prevents already-running keepalive tasks, scene correction callbacks, DAW bridge traffic, commissioning work, or a handoff race from bypassing the controller state.

On lease loss, expiration, or yield, the app should close the transmission gate before updating the UI.

### Foreign and legacy hosts

The lease would coordinate only application versions that implement the protocol. It cannot force an older app, Pro Tools, Logic, a third-party ipMIDI host, or another uncooperative sender to stop transmitting.

Existing foreign-HUI/loopback detection should therefore remain as a second fail-closed layer. If unexpected host traffic appears while this app believes it owns the lease, transmission should be disabled and the operator should be notified.

### Security

A recognizable plaintext signature is useful for discovery but does not establish authority. Any machine could copy it, and source IP addresses can change or be spoofed.

If remote takeover is implemented, coordination messages should be authenticated with a pairing secret or equivalent mechanism so that an unrelated host cannot force the controller into monitor-only mode.

## Recommended operational model if implemented

- Every coordinated machine may monitor incoming SwiftMix traffic.
- Exactly one valid lease holder may transmit.
- Control changes occur through an explicit, ordered handoff.
- Loss of coordination fails to monitor-only rather than automatically activating a standby.
- Unexpected non-coordinated HUI host traffic still disables transmission.
- The current single-host workflow remains the default.

## Conclusion

The feature is feasible and relatively contained because the application already centralizes transmission gating. It should be treated as a controller-lease and failover feature, not as a simple IP-address check. Until such a feature is deliberately implemented and hardware-tested, run only one active transmitting HUI host against the SwiftMix.