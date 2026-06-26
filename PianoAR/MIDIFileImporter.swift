import Foundation

enum MIDIImportError: LocalizedError {
    case invalidHeader
    case unsupportedTimeDivision
    case truncated
    case noNotes

    var errorDescription: String? {
        switch self {
        case .invalidHeader:
            return "That file is not a valid MIDI file."
        case .unsupportedTimeDivision:
            return "SMPTE-time MIDI files are not supported yet."
        case .truncated:
            return "The MIDI file appears to be incomplete."
        case .noNotes:
            return "No note events were found in the MIDI file."
        }
    }
}

enum MIDIFileImporter {
    private struct RawNote {
        let midiNote: Int
        let startTick: Int
        let endTick: Int
    }

    private struct ActiveNote {
        let startTick: Int
    }

    static func loadBundled(named name: String, title: String? = nil) -> Song? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mid"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? song(from: data, title: title ?? name)
    }

    static func song(from data: Data, title: String) throws -> Song {
        var reader = MIDIReader(data: data)
        guard try reader.readASCII(4) == "MThd" else { throw MIDIImportError.invalidHeader }

        let headerLength = try reader.readUInt32()
        guard headerLength >= 6 else { throw MIDIImportError.invalidHeader }

        _ = try reader.readUInt16() // format 0, 1, or 2. We parse tracks the same way.
        let trackCount = Int(try reader.readUInt16())
        let division = try reader.readUInt16()
        guard division & 0x8000 == 0 else { throw MIDIImportError.unsupportedTimeDivision }
        let ticksPerQuarter = max(1, Int(division))

        if headerLength > 6 {
            try reader.skip(Int(headerLength - 6))
        }

        var notes: [RawNote] = []
        var bpm = 90.0

        for _ in 0..<trackCount {
            guard try reader.readASCII(4) == "MTrk" else { throw MIDIImportError.invalidHeader }
            let trackLength = Int(try reader.readUInt32())
            let trackEnd = reader.position + trackLength
            guard trackEnd <= data.count else { throw MIDIImportError.truncated }
            let parsed = try parseTrack(
                reader: &reader,
                end: trackEnd,
                ticksPerQuarter: ticksPerQuarter,
                bpm: &bpm
            )
            notes.append(contentsOf: parsed)
            reader.position = trackEnd
        }

        let songNotes = notes
            .filter { $0.endTick > $0.startTick && (21...108).contains($0.midiNote) }
            .sorted {
                if $0.startTick == $1.startTick { return $0.midiNote < $1.midiNote }
                return $0.startTick < $1.startTick
            }
            .map { note in
                SongNote(
                    key: midiName(note.midiNote),
                    startBeat: Double(note.startTick) / Double(ticksPerQuarter),
                    durationBeats: max(
                        0.25,
                        Double(note.endTick - note.startTick) / Double(ticksPerQuarter)
                    ),
                    hand: "right"
                )
            }

        guard !songNotes.isEmpty else { throw MIDIImportError.noNotes }
        return Song(title: title, bpm: bpm, notes: songNotes)
    }

    private static func parseTrack(reader: inout MIDIReader,
                                   end: Int,
                                   ticksPerQuarter: Int,
                                   bpm: inout Double) throws -> [RawNote] {
        var tick = 0
        var runningStatus: UInt8?
        var active: [Int: [ActiveNote]] = [:]
        var notes: [RawNote] = []

        while reader.position < end {
            tick += try reader.readVariableLength()

            var status = try reader.readUInt8()
            if status < 0x80 {
                guard let running = runningStatus else { throw MIDIImportError.invalidHeader }
                reader.position -= 1
                status = running
            } else if status < 0xF0 {
                runningStatus = status
            }

            switch status {
            case 0x80...0x8F:
                let note = Int(try reader.readUInt8())
                _ = try reader.readUInt8()
                close(note: note, tick: tick, active: &active, notes: &notes)

            case 0x90...0x9F:
                let note = Int(try reader.readUInt8())
                let velocity = try reader.readUInt8()
                if velocity == 0 {
                    close(note: note, tick: tick, active: &active, notes: &notes)
                } else {
                    active[note, default: []].append(ActiveNote(startTick: tick))
                }

            case 0xA0...0xBF, 0xE0...0xEF:
                try reader.skip(2)

            case 0xC0...0xDF:
                try reader.skip(1)

            case 0xFF:
                let metaType = try reader.readUInt8()
                let length = try reader.readVariableLength()
                if metaType == 0x51 && length == 3 {
                    let micros = Int(try reader.readUInt8()) << 16
                        | Int(try reader.readUInt8()) << 8
                        | Int(try reader.readUInt8())
                    if micros > 0 {
                        bpm = 60_000_000.0 / Double(micros)
                    }
                } else {
                    try reader.skip(length)
                }
                if metaType == 0x2F {
                    reader.position = end
                }

            case 0xF0, 0xF7:
                let length = try reader.readVariableLength()
                try reader.skip(length)

            default:
                throw MIDIImportError.invalidHeader
            }
        }

        for (note, stack) in active {
            for item in stack {
                notes.append(RawNote(
                    midiNote: note,
                    startTick: item.startTick,
                    endTick: item.startTick + ticksPerQuarter
                ))
            }
        }

        return notes
    }

    private static func close(note: Int,
                              tick: Int,
                              active: inout [Int: [ActiveNote]],
                              notes: inout [RawNote]) {
        guard var stack = active[note], !stack.isEmpty else { return }
        let item = stack.removeFirst()
        active[note] = stack
        notes.append(RawNote(midiNote: note, startTick: item.startTick, endTick: tick))
    }

    private static func midiName(_ midi: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let pitch = ((midi % 12) + 12) % 12
        let octave = midi / 12 - 1
        return "\(names[pitch])\(octave)"
    }
}

private struct MIDIReader {
    let data: Data
    var position: Int = 0

    mutating func readASCII(_ count: Int) throws -> String {
        guard position + count <= data.count else { throw MIDIImportError.truncated }
        let bytes = data[position..<(position + count)]
        position += count
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    mutating func readUInt8() throws -> UInt8 {
        guard position < data.count else { throw MIDIImportError.truncated }
        let value = data[position]
        position += 1
        return value
    }

    mutating func readUInt16() throws -> UInt16 {
        let a = UInt16(try readUInt8())
        let b = UInt16(try readUInt8())
        return (a << 8) | b
    }

    mutating func readUInt32() throws -> UInt32 {
        let a = UInt32(try readUInt8())
        let b = UInt32(try readUInt8())
        let c = UInt32(try readUInt8())
        let d = UInt32(try readUInt8())
        return (a << 24) | (b << 16) | (c << 8) | d
    }

    mutating func readVariableLength() throws -> Int {
        var value = 0
        for _ in 0..<4 {
            let byte = try readUInt8()
            value = (value << 7) | Int(byte & 0x7F)
            if byte & 0x80 == 0 { return value }
        }
        return value
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, position + count <= data.count else { throw MIDIImportError.truncated }
        position += count
    }
}
