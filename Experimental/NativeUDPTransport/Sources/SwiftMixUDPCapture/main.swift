import Darwin
import Dispatch
import Foundation
import NativeUDPTransport

private enum CLIError: Error, CustomStringConvertible {
    case helpRequested
    case missingValue(String)
    case missingRequiredInterface
    case unknownArgument(String)
    case invalidBankSelection(String)

    var description: String {
        switch self {
        case .helpRequested:
            return ""
        case let .missingValue(option):
            return "Missing value for \(option)"
        case .missingRequiredInterface:
            return "--interface <bsd> is required; no default-route fallback is allowed"
        case let .unknownArgument(argument):
            return "Unknown argument: \(argument)"
        case let .invalidBankSelection(value):
            return "Invalid --banks selection '\(value)'; use 1-4, 1,3, or a single bank"
        }
    }
}

private struct Options {
    let interfaceBSDName: String
    let banks: [IPMIDIBank]
    let jsonLines: Bool

    static func parse(_ arguments: [String]) throws -> Options {
        var interfaceBSDName: String?
        var banks = IPMIDIBank.allCases
        var jsonLines = false
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--help", "-h":
                throw CLIError.helpRequested
            case "--interface":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.missingValue("--interface")
                }
                interfaceBSDName = arguments[index]
            case "--banks":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.missingValue("--banks")
                }
                banks = try parseBanks(arguments[index])
            case "--jsonl":
                jsonLines = true
            default:
                throw CLIError.unknownArgument(argument)
            }
            index += 1
        }

        guard let interfaceBSDName else {
            throw CLIError.missingRequiredInterface
        }
        return Options(
            interfaceBSDName: interfaceBSDName,
            banks: banks,
            jsonLines: jsonLines
        )
    }

    private static func parseBanks(_ value: String) throws -> [IPMIDIBank] {
        var numbers = Set<Int>()
        for component in value.split(separator: ",", omittingEmptySubsequences: false) {
            let bounds = component.split(separator: "-", omittingEmptySubsequences: false)
            if bounds.count == 1, let number = Int(bounds[0]) {
                numbers.insert(number)
            } else if bounds.count == 2,
                      let lower = Int(bounds[0]),
                      let upper = Int(bounds[1]),
                      lower <= upper {
                for number in lower...upper {
                    numbers.insert(number)
                }
            } else {
                throw CLIError.invalidBankSelection(value)
            }
        }

        guard !numbers.isEmpty else {
            throw CLIError.invalidBankSelection(value)
        }
        do {
            return try numbers.sorted().map(IPMIDIBank.init(number:))
        } catch {
            throw CLIError.invalidBankSelection(value)
        }
    }
}

private final class CaptureSession: @unchecked Sendable {
    private var decoder = ConservativeMIDIDecoder()
    private let jsonLines: Bool

    init(jsonLines: Bool) {
        self.jsonLines = jsonLines
    }

    func handle(_ event: NativeUDPReceiveEvent) {
        switch event {
        case let .failure(error):
            write("receive-error: \(error)", to: .standardError)
        case let .packet(packet):
            let decoded = decoder.decode(payload: packet.payload, bank: packet.bank)
            if jsonLines {
                do {
                    write(
                        try CaptureEncoding.jsonLine(packet: packet, decoded: decoded),
                        to: .standardOutput
                    )
                } catch {
                    write("capture-encoding-error: \(error)", to: .standardError)
                }
                return
            }

            write(
                "\(CaptureEncoding.timestamp(packet.timestamp)) "
                    + "bank=\(packet.bank.rawValue) "
                    + "src=\(packet.source.address):\(packet.source.port) "
                    + "dst-port=\(packet.localDestinationPort) "
                    + "bytes=\(packet.payload.count) "
                    + "hex=\(CaptureEncoding.hex(packet.payload))",
                to: .standardOutput
            )
            for message in decoded.messages {
                write("  MIDI \(message)", to: .standardOutput)
            }
            for huiEvent in decoded.events {
                write("  HUI? \(huiEvent)", to: .standardOutput)
            }
        }
    }
}

private func write(_ line: String, to handle: FileHandle) {
    handle.write(Data((line + "\n").utf8))
}

private let usage = """
Usage:
  swiftmix-udp-capture --interface <bsd> [--banks <selection>] [--jsonl]

Options:
  --interface <bsd>   Required exact BSD interface name, for example en7.
  --banks <selection> Defaults to 1-4; accepts 1-4, 1,3, or a single bank.
  --jsonl             Emit one deterministic JSON object per received datagram.
  --help, -h          Show this help.

SAFETY: This executable is receive-only. It has no transmit command and sends
zero packets. Press Ctrl-C to stop cleanly.
"""

@main
private struct SwiftMixUDPCaptureMain {
    static func main() {
        do {
            let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
            try run(options)
        } catch CLIError.helpRequested {
            write(usage, to: .standardOutput)
        } catch {
            write("error: \(error)", to: .standardError)
            write(usage, to: .standardError)
            exit(2)
        }
    }

    private static func run(_ options: Options) throws {
        write(
            "RECEIVE-ONLY SAFETY MODE: this command sends zero packets; Ctrl-C stops it.",
            to: .standardError
        )
        write(
            "Binding only to \(options.interfaceBSDName); banks "
                + options.banks.map { String($0.rawValue) }.joined(separator: ","),
            to: .standardError
        )

        let configuration = try NativeUDPConfiguration(
            interfaceBSDName: options.interfaceBSDName,
            banks: options.banks
        )
        let transport = NativeUDPTransport(
            configuration: configuration,
            receiveAuthorization: .receiveOnly,
            transmissionAuthorization: .denied
        )
        let session = CaptureSession(jsonLines: options.jsonLines)
        let interrupted = DispatchSemaphore(value: 0)
        let signalQueue = DispatchQueue(label: "SwiftMixUDPCapture.signal")

        Darwin.signal(SIGINT, SIG_IGN)
        let interruptSource = DispatchSource.makeSignalSource(
            signal: SIGINT,
            queue: signalQueue
        )
        interruptSource.setEventHandler {
            interrupted.signal()
        }
        interruptSource.resume()

        do {
            try transport.start { event in
                session.handle(event)
            }
        } catch {
            interruptSource.cancel()
            throw error
        }

        interrupted.wait()
        transport.stop()
        interruptSource.cancel()
        write("Capture stopped cleanly; zero packets were sent.", to: .standardError)
    }
}
