import Foundation

enum VocalRoom: String, Codable, CaseIterable, Sendable {
    case room, plate, hall

    var label: String {
        switch self {
        case .room: "房间"
        case .plate: "板式"
        case .hall: "大厅"
        }
    }

    var tailDuration: TimeInterval {
        switch self {
        case .room: 0.6
        case .plate: 0.75
        case .hall: 2.2
        }
    }
}

struct VocalTuning: Codable, Equatable, Sendable {
    static let lowCutRange: ClosedRange<Float> = 40...160
    static let toneRange: ClosedRange<Float> = -6...6
    static let gateRange: ClosedRange<Float> = -70 ... -30
    static let attackRange: ClosedRange<Float> = 1...40
    static let releaseRange: ClosedRange<Float> = 40...300
    static let echoRange: ClosedRange<Float> = 0...30
    static let echoTimeRange: ClosedRange<Float> = 70...420
    static let echoFeedbackRange: ClosedRange<Float> = 0...45

    var lowCut: Float = 80
    var warmth: Float = 0
    var air: Float = 0
    var gateThreshold: Float = -70
    var attackMS: Float = 5
    var releaseMS: Float = 120
    var room: VocalRoom = .plate
    var echo: Float = 0
    var echoTimeMS: Float = 150
    var echoFeedback: Float = 22

    var gateEnabled: Bool { gateThreshold > Self.gateRange.lowerBound }

    var bounded: Self {
        var value = self
        let defaults = Self()
        for (key, range): (WritableKeyPath<Self, Float>, ClosedRange<Float>) in [
            (\.lowCut, Self.lowCutRange), (\.warmth, Self.toneRange), (\.air, Self.toneRange),
            (\.gateThreshold, Self.gateRange), (\.attackMS, Self.attackRange), (\.releaseMS, Self.releaseRange),
            (\.echo, Self.echoRange), (\.echoTimeMS, Self.echoTimeRange), (\.echoFeedback, Self.echoFeedbackRange)
        ] {
            value[keyPath: key] = boundedVocalValue(self[keyPath: key], to: range, fallback: defaults[keyPath: key])
        }
        return value
    }
}

private func boundedVocalValue(_ value: Float, to range: ClosedRange<Float>, fallback: Float) -> Float {
    value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
}

struct VocalSettings: Codable, Equatable, Sendable {
    var brightness: Float = 2
    var compression: Float = 0.35
    var reverb: Float = 18
    var gain: Float = 0.8
    var enabled = true
    // Optional so takes and preferences saved before advanced effects still decode.
    var advanced: VocalTuning? = nil

    var tuning: VocalTuning {
        get { advanced ?? VocalTuning() }
        set { advanced = newValue == VocalTuning() ? nil : newValue }
    }

    var bounded: Self {
        var value = Self(brightness: boundedVocalValue(brightness, to: -4...6, fallback: 2),
                         compression: boundedVocalValue(compression, to: 0...1, fallback: 0.35),
                         reverb: boundedVocalValue(reverb, to: 0...45, fallback: 0),
                         gain: boundedVocalValue(gain, to: 0...1.5, fallback: 0.8), enabled: enabled)
        value.tuning = tuning.bounded
        return value
    }
}

struct PracticeRange: Codable, Equatable {
    let start: Double
    let end: Double
    var length: Double { end - start }
    var isValid: Bool { start.isFinite && end.isFinite && start >= 0 && length >= 0.25 }
    var label: String { "\(preciseTimeLabel(start))–\(preciseTimeLabel(end))" }
    func contains(_ value: Double) -> Bool { value >= start && value < end }
}

struct Take: Identifiable, Codable {
    let id: UUID
    let createdAt: Date
    let filename: String
    let songName: String
    let mediaPath: String?
    let videoStartSeconds: Double
    var duration: Double
    let sampleRate: Double
    var interrupted: Bool
    var issue: String?
    var accompanimentPath: String? = nil
    var lyricsPath: String? = nil
    var pitchSemitones: Int? = nil
    var librarySongID: String? = nil
    /// Position of the first captured frame on the accompaniment timeline.
    var captureSongSeconds: Double? = nil
    var backingVolume: Float? = nil
    var hasBacking: Bool? = nil
    var note: String? = nil
    var preferred: Bool? = nil
    var parentTakeID: UUID? = nil
    /// In seconds on the original dry recording, not on the accompaniment.
    var punchRange: PracticeRange? = nil
    var adoptedPunchID: UUID? = nil
    var recordedLyricDelay: Double? = nil
    /// Kept for compatibility with takes saved by the reverb-only version.
    var recordedReverb: Float? = nil
    var recordedEffects: VocalSettings? = nil
    var originalMixPath: String? = nil

    func quickPlaybackEffects(fallback: VocalSettings) -> VocalSettings {
        if let recordedEffects { return recordedEffects.bounded }
        let reverb = VocalSettings(reverb: recordedReverb ?? fallback.reverb).bounded.reverb
        return VocalSettings(brightness: 0, compression: 0, reverb: reverb, gain: 1, enabled: reverb > 0)
    }

    var songGroupKey: String {
        if let librarySongID { return "song:\(librarySongID)" }
        if let path = accompanimentPath ?? mediaPath {
            return "file:\(Self.recordedMediaURL(path).path)"
        }
        return "name:\(songName)"
    }
    static var directory: URL {
        StorageLocations.dataRoot.appendingPathComponent("Takes", isDirectory: true)
    }

    /// Recordings can refer to a song inside an older copy of the application bundle.
    static func recordedMediaURL(_ path: String, bundledRoot: URL? = Bundle.main.resourceURL?
        .appendingPathComponent("SongLibrary", isDirectory: true)) -> URL {
        let original = URL(fileURLWithPath: path).standardizedFileURL
        if let relocated = StorageLocations.relocatedMedia(original) { return relocated }
        guard let bundledRoot else { return original }
        let parts = original.pathComponents
        let bundleNames = ["KTV Pro.app", "KTake.app"]
        guard let index = parts.indices.first(where: {
            $0 + 4 < parts.count && bundleNames.contains(parts[$0]) &&
            parts[$0 + 1] == "Contents" && parts[$0 + 2] == "Resources" && parts[$0 + 3] == "SongLibrary"
        }) else { return original }
        let relative = parts[(index + 4)...].joined(separator: "/")
        let base = bundledRoot.resolvingSymlinksInPath().standardizedFileURL
        let current = base.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard current.path.hasPrefix(base.path + "/"), FileManager.default.fileExists(atPath: current.path) else { return original }
        return current
    }

    func url(in directory: URL) -> URL { directory.appendingPathComponent(filename) }
    private func metadataURL(in directory: URL) -> URL {
        url(in: directory).deletingPathExtension().appendingPathExtension("json")
    }

    func save(in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: metadataURL(in: directory), options: .atomic)
    }

    private var isSafeFilename: Bool {
        !filename.contains("/") && !filename.contains("\\") && (filename as NSString).pathExtension.lowercased() == "wav"
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    static func loadAll(in directory: URL) -> [Take] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap {
            guard isRegularFile($0), let data = try? Data(contentsOf: $0), let take = try? decoder.decode(Take.self, from: data),
                  take.isSafeFilename, $0.lastPathComponent == take.metadataURL(in: directory).lastPathComponent,
                  isRegularFile(take.url(in: directory)) else { return nil }
            return take
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func trash(in directory: URL, using moveToTrash: (URL) throws -> URL) throws {
        let audio = url(in: directory), metadata = metadataURL(in: directory)
        guard isSafeFilename, Self.isRegularFile(audio), Self.isRegularFile(metadata) else {
            throw AppFailure(message: "找不到这条录音的完整文件。")
        }
        let trashedAudio = try moveToTrash(audio)
        do { _ = try moveToTrash(metadata) }
        catch {
            do { try FileManager.default.moveItem(at: trashedAudio, to: audio) }
            catch { throw AppFailure(message: "录音的 WAV 已在废纸篓，但录音信息仍在原处。可将 WAV 放回后重试。") }
            throw error
        }
    }

    static func moveToSystemTrash(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        guard let result else { throw AppFailure(message: "无法确认废纸篓中的文件位置。") }
        return result as URL
    }
}

func timeLabel(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "00:00" }
    let total = Int(seconds)
    return String(format: "%02d:%02d", total / 60, total % 60)
}

func preciseTimeLabel(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0, seconds < 1_000_000 else { return "00:00.0" }
    let tenths = Int((seconds * 10).rounded())
    return "\(timeLabel(Double(tenths / 10))).\(tenths % 10)"
}
