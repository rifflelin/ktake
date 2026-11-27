import Foundation

struct LyricWord: Equatable {
    let time: Double
    let text: String
}

struct LyricLine: Identifiable, Equatable {
    var id: Int
    let time: Double
    let text: String
    var words: [LyricWord] = []
}

struct InterludeCue: Equatable {
    let nextLineText: String
    let remaining: Double
    let total: Double
    var progress: Double { total > 0 ? min(1, max(0, 1 - remaining / total)) : 0 }
}

struct Lyrics {
    let lines: [LyricLine]
    static let empty = Lyrics(lines: [])

    static func parse(_ source: String) throws -> Lyrics {
        let stamp = try NSRegularExpression(pattern: #"\[(\d{1,6}):([0-5]?\d)(?:[\.:](\d{1,3}))?\]"#)
        let offsetTag = try NSRegularExpression(pattern: #"(?i)\[offset:\s*([+-]?\d+)\s*\]"#)
        let wordStamp = try NSRegularExpression(pattern: #"<(\d{1,6}):([0-5]?\d)(?:[\.:](\d{1,3}))?>"#)
        let source = source.replacingOccurrences(of: "\u{feff}", with: "")
        let wholeRange = NSRange(source.startIndex..., in: source)
        var offset = 0.0
        if let match = offsetTag.firstMatch(in: source, range: wholeRange), let range = Range(match.range(at: 1), in: source) {
            offset = (Double(source[range]) ?? 0) / 1000
        }
        var entries: [(time: Double, text: String, words: [LyricWord], order: Int)] = []
        for raw in source.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let range = NSRange(line.startIndex..., in: line)
            let matches = stamp.matches(in: line, range: range)
            guard let last = matches.last, let end = Range(last.range, in: line)?.upperBound else { continue }
            let rawText = String(line[end...]).trimmingCharacters(in: .whitespaces)
            let cleanText = wordStamp.stringByReplacingMatches(in: rawText, range: NSRange(rawText.startIndex..., in: rawText), withTemplate: "")
            let parsedWords = matches.count == 1 ? parseWords(rawText, regex: wordStamp, offset: offset) : []
            for match in matches {
                func number(_ group: Int) -> String {
                    Range(match.range(at: group), in: line).map { String(line[$0]) } ?? ""
                }
                guard let minutes = Double(number(1)), let seconds = Double(number(2)) else { continue }
                let fraction = number(3)
                let decimal = fraction.isEmpty ? 0 : (Double(fraction) ?? 0) / pow(10, Double(fraction.count))
                let lineTime = minutes * 60 + seconds + decimal + offset
                entries.append((lineTime, cleanText, parsedWords, entries.count))
            }
        }
        guard !entries.isEmpty else { throw AppFailure(message: "没有找到带时间戳的歌词。请导入 LRC 文件，例如 [00:12.50]这一句歌词。") }
        entries.sort { $0.time == $1.time ? $0.order < $1.order : $0.time < $1.time }
        var lines: [LyricLine] = []
        for entry in entries {
            if let last = lines.last, last.time == entry.time {
                if last.text != entry.text {
                    lines[lines.count - 1] = LyricLine(id: last.id, time: last.time,
                                                       text: [last.text, entry.text].filter { !$0.isEmpty }.joined(separator: " / "),
                                                       words: [])
                }
            } else {
                lines.append(LyricLine(id: lines.count, time: entry.time, text: entry.text, words: entry.words))
            }
        }
        return Lyrics(lines: lines)
    }

    private static func parseWords(_ rawText: String, regex: NSRegularExpression, offset: Double) -> [LyricWord] {
        let matches = regex.matches(in: rawText, range: NSRange(rawText.startIndex..., in: rawText))
        guard !matches.isEmpty else { return [] }
        var result: [LyricWord] = []
        for i in matches.indices {
            let match = matches[i]
            func number(_ group: Int) -> String {
                Range(match.range(at: group), in: rawText).map { String(rawText[$0]) } ?? ""
            }
            guard let minutes = Double(number(1)), let seconds = Double(number(2)),
                  let tagRange = Range(match.range, in: rawText) else { continue }
            let fraction = number(3)
            let decimal = fraction.isEmpty ? 0 : (Double(fraction) ?? 0) / pow(10, Double(fraction.count))
            let wordTime = minutes * 60 + seconds + decimal + offset
            let textEnd = i + 1 < matches.count ? (Range(matches[i + 1].range, in: rawText)?.lowerBound ?? rawText.endIndex) : rawText.endIndex
            let segment = String(rawText[tagRange.upperBound..<textEnd])
            if !segment.isEmpty {
                result.append(LyricWord(time: wordTime, text: segment))
            }
        }
        return result
    }

    /// Last line at or before the playback time, including when seeking backwards.
    func index(at seconds: Double) -> Int? {
        guard seconds.isFinite, !lines.isEmpty else { return nil }
        var low = 0, high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if lines[middle].time <= seconds { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : low - 1
    }

    /// Smooth 0...1 singing progress for a line, using word timestamps when present.
    func lineProgress(at seconds: Double, lineIndex: Int, songDuration: Double) -> Double {
        guard seconds.isFinite, lines.indices.contains(lineIndex) else { return 0 }
        let line = lines[lineIndex]
        guard !line.text.isEmpty else { return 0 }
        let nextTime = lineIndex + 1 < lines.count ? lines[lineIndex + 1].time : max(line.time + 4.0, songDuration)
        if !line.words.isEmpty {
            let totalChars = max(1, line.words.reduce(0) { $0 + $1.text.count })
            if seconds < line.words[0].time { return 0 }
            var completedChars = 0
            for i in line.words.indices {
                let word = line.words[i]
                let wordEnd: Double
                if i + 1 < line.words.count {
                    wordEnd = max(word.time + 0.05, line.words[i + 1].time)
                } else {
                    let cap = min(nextTime, word.time + max(0.35, Double(word.text.count) * 0.45))
                    wordEnd = max(word.time + 0.12, cap)
                }
                if seconds < wordEnd {
                    let local = min(1, max(0, (seconds - word.time) / (wordEnd - word.time)))
                    return min(1, (Double(completedChars) + local * Double(word.text.count)) / Double(totalChars))
                }
                completedChars += word.text.count
            }
            return 1
        }
        let rawSpan = max(0.35, nextTime - line.time)
        let estimatedCap = max(2.8, min(9.5, Double(max(line.text.count, 4)) * 0.42))
        let span = rawSpan > estimatedCap + 2.5 ? estimatedCap : max(0.35, rawSpan * 0.94)
        return min(1, max(0, (seconds - line.time) / span))
    }

    /// Returns a countdown cue during intros, explicit interludes, or long silent gaps before the next vocal line.
    func interludeCue(at seconds: Double, currentIndex: Int?) -> InterludeCue? {
        guard seconds.isFinite, !lines.isEmpty else { return nil }
        let searchStart = currentIndex.map { $0 + 1 } ?? 0
        guard searchStart < lines.count,
              let nextIndex = lines[searchStart...].firstIndex(where: { !$0.text.isEmpty }) else { return nil }
        let next = lines[nextIndex]
        let remaining = next.time - seconds
        guard remaining > 0.04 else { return nil }
        if currentIndex == nil {
            guard next.time >= 1.5 else { return nil }
            return InterludeCue(nextLineText: next.text, remaining: remaining, total: max(1.5, next.time))
        }
        let current = lines[currentIndex!]
        if current.text.isEmpty {
            let total = next.time - current.time
            guard total >= 1.5 else { return nil }
            return InterludeCue(nextLineText: next.text, remaining: remaining, total: total)
        }
        let gap = next.time - current.time
        let estimatedCap = max(2.8, min(9.5, Double(max(current.text.count, 4)) * 0.42))
        if gap >= estimatedCap + 3.0, seconds >= current.time + estimatedCap, remaining <= 5.0 {
            let window = min(5.0, gap - estimatedCap)
            return InterludeCue(nextLineText: next.text, remaining: remaining, total: max(1.0, window))
        }
        return nil
    }
}
