import Foundation

public struct CaptureResult: Equatable, Sendable {
    public let task: TaskItem
    public let hasDueDate: Bool
    public let hasPlannedDate: Bool
    public let hasProject: Bool
}

/// Prefixes occupy the suffix of a capture: title !due phrase @planned phrase /project name.
/// Delimiters inside quotes or escaped with a backslash stay literal. Invalid commands never
/// disappear from a title silently: the UI keeps the raw input and requires a correction.
public enum Capture {
    public static func parse(_ input: String, projects: [Project], defaultProjectId: String = "inbox",
                             now: Date = Date(), defaultHour: Int = 9, defaultMinute: Int = 0,
                             calendar: Calendar = .current) throws -> CaptureResult {
        var markers: [String.Index] = []
        var quoted = false
        var escaped = false
        for index in input.indices {
            let character = input[index]
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "\"" { quoted.toggle(); continue }
            if !quoted, "!@/".contains(character),
               index == input.startIndex || input[input.index(before: index)].isWhitespace {
                markers.append(index)
            }
        }
        guard !quoted else { throw AppFailure("Close the quoted text before saving.") }
        let title = unescape(String(input[..<(markers.first ?? input.endIndex)])).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw AppFailure("Start with a task title, followed by !due, @planned or /project.") }
        var task = TaskItem(title: title, projectId: defaultProjectId,
                            project: projects.first { $0.id == defaultProjectId }?.name ?? "Inbox")
        var used = Set<Character>()
        for (offset, index) in markers.enumerated() {
            let marker = input[index]
            guard used.insert(marker).inserted else { throw AppFailure("Use \(marker) only once per task.") }
            let end = offset + 1 < markers.count ? markers[offset + 1] : input.endIndex
            var phrase = String(input[input.index(after: index)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if phrase.hasPrefix("\""), phrase.hasSuffix("\""), phrase.count >= 2 { phrase.removeFirst(); phrase.removeLast() }
            phrase = unescape(phrase)
            guard !phrase.isEmpty else { throw AppFailure("Add a value after \(marker).") }
            if marker == "/" {
                let exact = projects.filter { $0.name == phrase }
                let matches = exact.isEmpty ? projects.filter { $0.name.compare(phrase, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame } : exact
                guard matches.count == 1 else { throw AppFailure("Choose an existing, unambiguous project after /: “\(phrase)”.") }
                task.projectId = matches[0].id
                task.project = matches[0].name
            } else {
                let date = try NaturalDate.parse(phrase, now: now, defaultHour: defaultHour, defaultMinute: defaultMinute, calendar: calendar)
                let value = LocalDateTime.string(from: date, calendar: calendar)
                if marker == "!" { task.dueOn = value } else { task.plannedFor = value }
            }
        }
        return CaptureResult(task: task, hasDueDate: used.contains("!"), hasPlannedDate: used.contains("@"), hasProject: used.contains("/"))
    }

    private static func unescape(_ text: String) -> String {
        var result = ""
        var escaped = false
        for character in text {
            if escaped {
                if !"!@/\\\"".contains(character) { result.append("\\") }
                result.append(character)
                escaped = false
            } else if character == "\\" { escaped = true }
            else { result.append(character) }
        }
        if escaped { result.append("\\") }
        return result
    }
}

public enum NaturalDate {
    // NSDataDetector doesn't recognize “two weeks from now” and has no reference-date API.
    // Handle relative dates with Calendar for predictable, offline, DST-aware results; use the
    // native detector only as a full-phrase fallback for absolute human-readable dates.
    public static func parse(_ text: String, now: Date = Date(), defaultHour: Int = 9, defaultMinute: Int = 0,
                             calendar: Calendar = .current) throws -> Date {
        guard (0...23).contains(defaultHour), (0...59).contains(defaultMinute) else { throw AppFailure("Invalid default capture time.") }
        var phrase = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "a.m.", with: "am").replacingOccurrences(of: "p.m.", with: "pm")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let invalid = AppFailure("Couldn’t understand “\(text)”. Try tomorrow, Monday 9am, two weeks from now, or 2027-04-15 at 14:30.")
        var hour = defaultHour
        var minute = defaultMinute
        var explicitTime = false
        let timePattern = #"(?:^|\s+)(?:at\s+)?(noon|midnight|morning|afternoon|evening|night|\d{1,2}(?::\d{2})?\s*(?:am|pm)|\d{1,2}:\d{2}|(?<=at )\d{1,2})$"#
        if let range = phrase.range(of: timePattern, options: .regularExpression) {
            let token = String(phrase[range]).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"^at\s+"#, with: "", options: .regularExpression)
            if let clockHour = ["noon": 12, "midnight": 0, "morning": 9, "afternoon": 15, "evening": 18, "night": 20][token] {
                hour = clockHour; minute = 0
            } else {
                let meridiem = token.hasSuffix("am") ? "am" : token.hasSuffix("pm") ? "pm" : ""
                let digits = token.replacingOccurrences(of: #"\s*(am|pm)$"#, with: "", options: .regularExpression).split(separator: ":")
                guard let parsedHour = Int(digits[0]), let parsedMinute = digits.count == 2 ? Int(digits[1]) : 0,
                      (0...59).contains(parsedMinute), meridiem.isEmpty ? (0...23).contains(parsedHour) : (1...12).contains(parsedHour) else { throw invalid }
                hour = meridiem.isEmpty ? parsedHour : parsedHour % 12 + (meridiem == "pm" ? 12 : 0)
                minute = parsedMinute
            }
            explicitTime = true
            phrase.removeSubrange(range)
            phrase = phrase.trimmingCharacters(in: .whitespaces)
        }
        func atTime(_ date: Date) throws -> Date {
            guard let result = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date, matchingPolicy: .nextTime, repeatedTimePolicy: .first) else { throw invalid }
            return result
        }
        if phrase.isEmpty, explicitTime {
            let today = try atTime(now)
            return today > now ? today : try atTime(calendar.date(byAdding: .day, value: 1, to: now)!)
        }
        if let days = ["today": 0, "tomorrow": 1, "day after tomorrow": 2, "yesterday": -1][phrase] {
            return try atTime(calendar.date(byAdding: .day, value: days, to: now)!)
        }
        if phrase == "tonight" {
            if !explicitTime { hour = 20; minute = 0 }
            return try atTime(now)
        }
        let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        let dayWord = phrase.replacingOccurrences(of: #"^(next|this) "#, with: "", options: .regularExpression)
        if let weekday = weekdays.firstIndex(where: { $0 == dayWord || String($0.prefix(3)) == dayWord }) {
            if phrase.hasPrefix("next ") {
                let offset = (weekday + 1 - calendar.component(.weekday, from: now) + 7) % 7
                return try atTime(calendar.date(byAdding: .day, value: offset == 0 ? 7 : offset, to: now)!)
            }
            guard let result = calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute, second: 0, weekday: weekday + 1), matchingPolicy: .nextTime, repeatedTimePolicy: .first) else { throw invalid }
            return result
        }
        let relative = phrase.replacingOccurrences(of: #"^in "#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #" (from now|later)$"#, with: "", options: .regularExpression)
        let words = relative.split(separator: " ").map(String.init)
        if words.count == 2 {
            let numbers = ["zero": 0, "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
                           "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
                           "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "next": 1]
            let unit = words[1].hasSuffix("s") ? String(words[1].dropLast()) : words[1]
            let units: [String: Calendar.Component] = ["minute": .minute, "hour": .hour, "day": .day, "week": .weekOfYear, "month": .month, "year": .year]
            if let count = Int(words[0]) ?? numbers[words[0]], (0...10_000).contains(count), let component = units[unit],
               let date = calendar.date(byAdding: component, value: count, to: now) {
                if component == .minute || component == .hour {
                    guard !explicitTime else { throw invalid }
                    return calendar.dateInterval(of: .minute, for: date)!.start
                }
                return try atTime(date)
            }
        }
        // Reject malformed ISO dates rather than letting a detector normalize an invalid day.
        if phrase.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            guard let date = LocalDateTime.date(from: phrase + "T12:00", calendar: calendar),
                  LocalDateTime.string(from: date, calendar: calendar).hasPrefix(phrase) else { throw invalid }
            return try atTime(date)
        }
        let absolute = #"\b(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:tember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\b|\d{1,2}[/.-]\d{1,2}"#
        guard phrase.range(of: absolute, options: .regularExpression) != nil,
              phrase.range(of: #"\b(at|am|pm|morning|afternoon|evening|night)\b|\d:\d"#, options: .regularExpression) == nil else { throw invalid }
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        let range = NSRange(phrase.startIndex..., in: phrase)
        let matches = detector.matches(in: phrase, range: range)
        guard matches.count == 1, let match = matches.first, match.range == range, match.duration == 0, let date = match.date else { throw invalid }
        let day = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard let localDay = calendar.date(from: day) else { throw invalid }
        return try atTime(localDay)
    }
}
