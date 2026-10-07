import Foundation

enum EventKind: String, Codable {
    case sessionStart = "MISSION START"
    case humanDetected = "ASTRONAUT DETECTED"
    case humanLeft = "OUT OF VIEW"
    case movementResumed = "MOVEMENT"
    case loo = "LOO BREAK"
    case observation = "OBSERVATION"
    case deceased = "NO SIGNS OF LIFE"
    case revived = "SIGNS OF LIFE"
    case system = "SYSTEM"

    var symbol: String {
        switch self {
        case .sessionStart: "moon.stars.fill"
        case .humanDetected: "figure.stand"
        case .humanLeft: "figure.walk.departure"
        case .movementResumed: "waveform.path.ecg"
        case .loo: "toilet"
        case .observation: "eye"
        case .deceased: "heart.slash"
        case .revived: "heart.fill"
        case .system: "cpu"
        }
    }
}

struct RecorderEvent: Identifiable, Codable {
    var id = UUID()
    var date = Date()
    var kind: EventKind
    var detail: String
    var snapshot: String?
}

/// Append-only on-device log: Documents/Blackbox/log.jsonl plus JPEG snapshots.
@MainActor
@Observable
final class FlightRecorder {
    private(set) var events: [RecorderEvent] = []

    let directory: URL = {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Blackbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    var logURL: URL { directory.appendingPathComponent("log.jsonl") }

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? String(contentsOf: logURL, encoding: .utf8) {
            events = data.split(separator: "\n").compactMap {
                try? decoder.decode(RecorderEvent.self, from: Data($0.utf8))
            }
        }
    }

    func record(_ kind: EventKind, _ detail: String, jpeg: Data? = nil) {
        var event = RecorderEvent(kind: kind, detail: detail)
        if let jpeg {
            let name = "\(Int(event.date.timeIntervalSince1970 * 1000)).jpg"
            if (try? jpeg.write(to: directory.appendingPathComponent(name))) != nil {
                event.snapshot = name
            }
        }
        events.append(event)
        guard var line = try? encoder.encode(event) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: logURL)
        }
    }

    func snapshotURL(for event: RecorderEvent) -> URL? {
        event.snapshot.map { directory.appendingPathComponent($0) }
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        events = []
    }
}
