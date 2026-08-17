import Foundation

/// The cameras this event expects, by number and position.
///
/// Everything else in the app reports what it found. This is the only thing that
/// knows what *should* be there — and on a rig day the question that matters is
/// which camera is missing, which no amount of discovery can answer.
///
/// A camera is bound to its number by **serial**, not by the name it advertises
/// and not by the order it was plugged in. The serial is the only identifier the
/// camera itself will confirm: the advertised Bonjour name has been seen to be a
/// stale copy of the previously connected camera's, and the number painted on the
/// case is only as good as the last person who painted one.
public struct Roster: Codable, Sendable, Equatable {

    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        /// The number on the case. Also the RTMP path — `cam07`.
        public var number: Int

        /// Bound once the camera has been installed here. A roster carried over
        /// from a previous event already has these, which is what lets cameras
        /// be hung in any order and still land on their own number.
        public var serial: String?

        /// Where it is in the room, in the words the crew uses.
        public var position: String

        /// Which node receives it. Cameras that fail together behind one node
        /// are one fault, and that only becomes visible if this is known.
        public var nodeID: Int?

        public var id: Int { number }

        public init(number: Int, serial: String? = nil,
                    position: String = "", nodeID: Int? = nil) {
            self.number = number
            self.serial = serial
            self.position = position
            self.nodeID = nodeID
        }
    }

    public var eventName: String
    public var entries: [Entry]

    public init(eventName: String = "Untitled event", entries: [Entry] = []) {
        self.eventName = eventName
        self.entries = entries
    }

    public var expected: Int { entries.count }

    public func entry(forSerial serial: String) -> Entry? {
        entries.first { $0.serial == serial }
    }

    public func entry(number: Int) -> Entry? {
        entries.first { $0.number == number }
    }

    public var byNode: [Int?: [Entry]] {
        Dictionary(grouping: entries.sorted { $0.number < $1.number }) { $0.nodeID }
    }

    /// Binds a camera to a number, taking it off whatever number it was on.
    ///
    /// A camera can only be in one place, and a number can only hold one camera.
    /// Assigning without clearing the other side is how a fleet ends up with two
    /// entries claiming the same unit.
    public mutating func install(serial: String, at number: Int) {
        for index in entries.indices where entries[index].serial == serial {
            entries[index].serial = nil
        }
        if let index = entries.firstIndex(where: { $0.number == number }) {
            entries[index].serial = serial
        } else {
            entries.append(Entry(number: number, serial: serial))
            entries.sort { $0.number < $1.number }
        }
    }
}

// MARK: - Where it lives

public enum RosterStore {

    public static var url: URL {
        let directory = AppPaths.support
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("roster.json")
    }

    public static func load() -> Roster {
        guard let data = try? Data(contentsOf: url),
              let roster = try? JSONDecoder().decode(Roster.self, from: data)
        else { return Roster() }
        return roster
    }

    public static func save(_ roster: Roster) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(roster).write(to: url)
    }

    /// Builds a roster from the cameras that have been checked out.
    ///
    /// The first event with a new set of cameras should not begin with typing
    /// sixteen serial numbers. `orahctl checkout` has already collected them.
    public static func seedFromRecords(at directory: URL, nodeSize: Int = 4) -> Roster {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" } ?? []

        var known: [(number: Int, serial: String)] = files.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let record = try? decoder.decode(CameraCheckout.Record.self, from: data),
                  let number = record.number, !record.serial.isEmpty
            else { return nil }
            return (number, record.serial)
        }
        known.sort { $0.number < $1.number }

        var roster = Roster(eventName: "Seeded from camera records")
        for (index, camera) in known.enumerated() {
            roster.entries.append(Roster.Entry(
                number: camera.number,
                serial: camera.serial,
                position: "",
                nodeID: index / nodeSize + 1))
        }
        return roster
    }
}
