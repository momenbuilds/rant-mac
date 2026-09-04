import Foundation

/// A moment worth jumping back to, with the timestamp that gets you there.
public struct MeetingKeyMoment: Equatable, Sendable, Codable {
  public var startedMilliseconds: Int
  public var channel: MeetingChannel
  public var text: String

  public init(startedMilliseconds: Int, channel: MeetingChannel, text: String) {
    self.startedMilliseconds = startedMilliseconds
    self.channel = channel
    self.text = text
  }
}

/// What a meeting came to.
public struct MeetingSummary: Equatable, Sendable, Codable {
  public var overview: String
  public var actionItems: [String]
  public var decisions: [String]
  public var questions: [String]
  public var keyMoments: [MeetingKeyMoment]
  /// Identifier of the model that wrote the overview, or nil when nothing was
  /// available and the structural extraction stands on its own.
  public var producedBy: String?
  /// True when no model contributed. Shown to the user, because "the app summarised
  /// this" and "the app pulled out the sentences that looked like commitments" are
  /// different claims and only one of them is true here.
  public var isFallback: Bool
  /// True when producing this summary sent the transcript off the machine. Recorded
  /// on the summary itself rather than inferred from settings later, so the record
  /// stays accurate even if the setting changes afterwards.
  public var sentTextOffDevice: Bool

  public init(
    overview: String,
    actionItems: [String] = [],
    decisions: [String] = [],
    questions: [String] = [],
    keyMoments: [MeetingKeyMoment] = [],
    producedBy: String? = nil,
    isFallback: Bool = true,
    sentTextOffDevice: Bool = false
  ) {
    self.overview = overview
    self.actionItems = actionItems
    self.decisions = decisions
    self.questions = questions
    self.keyMoments = keyMoments
    self.producedBy = producedBy
    self.isFallback = isFallback
    self.sentTextOffDevice = sentTextOffDevice
  }

  public static let empty = MeetingSummary(overview: "")
}

/// What the summariser is allowed to do.
///
/// Defaults are the private ones. A meeting transcript is the most sensitive text
/// Rant ever holds — it contains other people, who never agreed to anything — so
/// sending it anywhere has to be a decision somebody made on purpose rather than a
/// default they inherited.
public struct MeetingSummariserPolicy: Equatable, Sendable {
  /// Permit an enhancer whose `sendsTextOffDevice` is true.
  public var allowOffDeviceText: Bool
  /// Permit a provider that would upload the *audio* rather than the text. Nothing in
  /// Rant does this today; the flag exists so that if a provider ever offers it, it
  /// has to be switched on deliberately and shows up in the resulting summary.
  public var allowAudioUpload: Bool
  public var maximumKeyMoments: Int
  /// Transcripts longer than this are truncated before being sent to a model. A model
  /// that silently drops the second half of a meeting is worse than one that is told
  /// where the text stops.
  public var maximumTranscriptCharacters: Int

  public init(
    allowOffDeviceText: Bool = false,
    allowAudioUpload: Bool = false,
    maximumKeyMoments: Int = 5,
    maximumTranscriptCharacters: Int = 24_000
  ) {
    self.allowOffDeviceText = allowOffDeviceText
    self.allowAudioUpload = allowAudioUpload
    self.maximumKeyMoments = maximumKeyMoments
    self.maximumTranscriptCharacters = maximumTranscriptCharacters
  }

  public static let `default` = MeetingSummariserPolicy()
}

/// Turns a transcript into notes.
///
/// The model is optional on purpose. Ollama may not be installed, the machine may be
/// offline, the user may have turned enhancement off entirely — and a notetaker that
/// produces nothing under those conditions is a notetaker nobody trusts with an
/// important call. So the structural extraction runs first and always, the model is
/// asked only to improve on it, and any failure leaves the deterministic result
/// standing rather than an error message where the notes should be.
public struct MeetingSummariser: Sendable {
  private let enhancer: EnhancementProvider?
  private let log = RantLog("Notetaker")
  public var policy: MeetingSummariserPolicy

  public init(enhancer: EnhancementProvider? = nil, policy: MeetingSummariserPolicy = .default) {
    self.enhancer = enhancer
    self.policy = policy
  }

  /// Never throws. The worst outcome is a summary marked `isFallback`.
  public func summarise(
    title: String? = nil,
    segments: [MeetingSegment],
    labels: MeetingSpeakerLabels = .default,
    durationMilliseconds: Int = 0
  ) async -> MeetingSummary {
    let fallback = MeetingStructure.summarise(
      title: title, segments: segments, labels: labels,
      durationMilliseconds: durationMilliseconds,
      maximumKeyMoments: policy.maximumKeyMoments)
    guard !segments.isEmpty else { return fallback }

    guard let enhancer else { return fallback }
    guard enhancer.identifier != "none" else { return fallback }
    if enhancer.sendsTextOffDevice && !policy.allowOffDeviceText {
      log.notice("skipping \(enhancer.identifier) for a meeting summary: off-device text not allowed")
      return fallback
    }
    guard await enhancer.isAvailable() else { return fallback }

    let transcript = MeetingStructure.transcript(
      segments, labels: labels, limit: policy.maximumTranscriptCharacters)
    do {
      let response = try await enhancer.enhance(
        transcript, instruction: Self.instruction(title: title), context: nil)
      let parsed = MeetingSummaryParser.parse(response)
      guard !parsed.overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        log.warning("meeting summariser returned nothing usable, keeping the structural notes")
        return fallback
      }
      // The model's sections replace the structural ones only where it actually
      // produced something. A model that forgets to list decisions should not delete
      // the ones we found ourselves.
      return MeetingSummary(
        overview: parsed.overview,
        actionItems: parsed.actionItems.isEmpty ? fallback.actionItems : parsed.actionItems,
        decisions: parsed.decisions.isEmpty ? fallback.decisions : parsed.decisions,
        questions: parsed.questions.isEmpty ? fallback.questions : parsed.questions,
        keyMoments: fallback.keyMoments,
        producedBy: enhancer.identifier,
        isFallback: false,
        sentTextOffDevice: enhancer.sendsTextOffDevice)
    } catch {
      log.warning("meeting summariser failed, keeping the structural notes")
      return fallback
    }
  }

  static func instruction(title: String?) -> String {
    var lines = [
      "You are summarising a meeting transcript. Lines are labelled with who spoke.",
      "Reply with these headings and nothing else:",
      "Summary: one short paragraph.",
      "Action items: one per line, starting with '- ', each naming who owes what.",
      "Decisions: one per line, starting with '- '.",
      "Open questions: one per line, starting with '- '.",
      "Use only what the transcript says. Leave a section empty rather than inventing.",
    ]
    if let title, !title.isEmpty { lines.insert("The meeting is called \"\(title)\".", at: 1) }
    return lines.joined(separator: "\n")
  }
}

// MARK: - Parsing a model's reply

/// Reads the headed sections back out of a model's reply.
///
/// Tolerant by design: models add markdown, change "Action items" to "Action Items",
/// and sometimes bold the heading. Anything unrecognised falls into the overview
/// rather than being discarded, because a summary in the wrong section is still a
/// summary and a dropped one is a bug the user cannot work around.
public enum MeetingSummaryParser {
  public struct Parsed: Equatable, Sendable {
    public var overview: String = ""
    public var actionItems: [String] = []
    public var decisions: [String] = []
    public var questions: [String] = []
  }

  private enum Section { case overview, actions, decisions, questions }

  public static func parse(_ response: String) -> Parsed {
    var parsed = Parsed()
    var overviewLines: [String] = []
    var section = Section.overview

    for rawLine in response.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(rawLine).trimmingCharacters(in: .whitespaces)
      if line.isEmpty { continue }
      let stripped = strippingDecoration(line)
      let lowered = stripped.lowercased()

      if let (next, remainder) = heading(in: stripped, lowered: lowered) {
        section = next
        if !remainder.isEmpty { append(remainder, to: &parsed, section: section, overview: &overviewLines) }
        continue
      }
      append(stripped, to: &parsed, section: section, overview: &overviewLines)
    }

    parsed.overview = overviewLines.joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return parsed
  }

  private static func append(
    _ text: String, to parsed: inout Parsed, section: Section, overview: inout [String]
  ) {
    let item = strippingBullet(text)
    guard !item.isEmpty else { return }
    switch section {
    case .overview: overview.append(item)
    case .actions: parsed.actionItems.append(item)
    case .decisions: parsed.decisions.append(item)
    case .questions: parsed.questions.append(item)
    }
  }

  /// Matches a heading at the start of a line and returns whatever followed the
  /// colon, so "Summary: we agreed to ship" works as well as a heading on its own.
  private static func heading(in line: String, lowered: String) -> (Section, String)? {
    let headings: [(String, Section)] = [
      ("summary", .overview), ("overview", .overview),
      ("action items", .actions), ("action item", .actions), ("actions", .actions),
      ("next steps", .actions), ("todos", .actions), ("to do", .actions),
      ("decisions", .decisions), ("decision", .decisions),
      ("open questions", .questions), ("questions", .questions),
    ]
    for (name, section) in headings where lowered.hasPrefix(name) {
      let rest = String(lowered.dropFirst(name.count))
      guard rest.isEmpty || rest.hasPrefix(":") else { continue }
      let remainder = String(line.dropFirst(name.count)).drop(while: { $0 == ":" || $0 == " " })
      return (section, String(remainder))
    }
    return nil
  }

  /// Removes markdown heading marks and surrounding emphasis. A linear scan rather
  /// than a pattern, because this runs over model output of unbounded length and a
  /// pattern with nested quantifiers over untrusted text is how you hang a UI.
  static func strippingDecoration(_ line: String) -> String {
    var text = Substring(line)
    while let first = text.first, first == "#" || first == ">" || first == " " {
      text = text.dropFirst()
    }
    while text.hasPrefix("**") { text = text.dropFirst(2) }
    while text.hasSuffix("**") { text = text.dropLast(2) }
    while text.hasPrefix("*") && !text.hasPrefix("* ") { text = text.dropFirst() }
    return String(text).trimmingCharacters(in: .whitespaces)
  }

  static func strippingBullet(_ line: String) -> String {
    var text = line
    for marker in ["- ", "* ", "• ", "– ", "—"] where text.hasPrefix(marker) {
      text = String(text.dropFirst(marker.count))
      break
    }
    // Numbered lists: a leading run of digits followed by a dot or bracket.
    var digits = 0
    for character in text {
      if character.isNumber { digits += 1; continue }
      if digits > 0, character == "." || character == ")" {
        text = String(text.dropFirst(digits + 1)).trimmingCharacters(in: .whitespaces)
      }
      break
    }
    return text.trimmingCharacters(in: .whitespaces)
  }
}

// MARK: - Structural extraction

/// The deterministic notes: what you get with no model at all.
///
/// This is not a summary and does not pretend to be one. It is the set of sentences
/// that carry the grammar of a commitment, a decision or a question, pulled out with
/// a cue-phrase scan. It is right often enough to be worth reading and it never
/// invents anything, which is the property a model cannot offer.
public enum MeetingStructure {
  static let actionCues = [
    "i'll ", "i will ", "we'll ", "we will ", "you'll ", "let's ", "lets ",
    "action item", "follow up", "follow-up", "can you ", "could you ", "please ",
    "i need to", "we need to", "needs to ", "have to ", "make sure", "take care of",
    "send over", "send you", "write up", "circle back", "by tomorrow", "by monday",
    "by friday", "next week", "todo", "to-do", "i'm going to", "we're going to",
  ]

  static let decisionCues = [
    "we decided", "we've decided", "we have decided", "decision is", "decided to",
    "let's go with", "we're going with", "we are going with", "we agreed",
    "agreed to", "sign off", "settled on", "the plan is", "we'll go with",
    "final answer", "that's the call",
  ]

  public static func summarise(
    title: String?,
    segments: [MeetingSegment],
    labels: MeetingSpeakerLabels = .default,
    durationMilliseconds: Int = 0,
    maximumKeyMoments: Int = 5
  ) -> MeetingSummary {
    let decisions = decisions(in: segments)
    let actions = actionItems(in: segments, excluding: Set(decisions))
    return MeetingSummary(
      overview: overview(
        title: title, segments: segments, labels: labels,
        durationMilliseconds: durationMilliseconds,
        actionCount: actions.count, decisionCount: decisions.count),
      actionItems: actions,
      decisions: decisions,
      questions: questions(in: segments),
      keyMoments: keyMoments(in: segments, limit: maximumKeyMoments),
      producedBy: nil,
      isFallback: true,
      sentTextOffDevice: false)
  }

  /// A plain-language description of what happened, built only from things that can
  /// be counted. No claim here can be wrong.
  public static func overview(
    title: String?,
    segments: [MeetingSegment],
    labels: MeetingSpeakerLabels,
    durationMilliseconds: Int,
    actionCount: Int,
    decisionCount: Int
  ) -> String {
    guard !segments.isEmpty else { return "Nothing was transcribed." }
    let words = segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    let mine = segments.filter { $0.channel == .me }.count
    let theirs = segments.count - mine
    var parts: [String] = []
    if let title, !title.isEmpty { parts.append("\(title).") }
    let length = durationMilliseconds > 0 ? humanDuration(durationMilliseconds) : "A short"
    parts.append("\(length) conversation, \(words) words.")
    parts.append("\(labels.me) took \(mine) turns, \(labels.them) \(theirs).")
    if let opening = sentences(in: segments.first?.text ?? "").first {
      parts.append("It opened with “\(opening)”")
    }
    if actionCount > 0 || decisionCount > 0 {
      parts.append(
        "\(actionCount) possible action \(actionCount == 1 ? "item" : "items") and "
          + "\(decisionCount) possible \(decisionCount == 1 ? "decision" : "decisions") "
          + "were picked out of the transcript.")
    }
    return parts.joined(separator: " ")
  }

  public static func actionItems(
    in segments: [MeetingSegment], excluding: Set<String> = []
  ) -> [String] {
    matches(in: segments, cues: actionCues, excluding: excluding)
  }

  public static func decisions(in segments: [MeetingSegment]) -> [String] {
    matches(in: segments, cues: decisionCues)
  }

  /// Sentences that end in a question mark. Cue-phrase matching is not used here:
  /// the punctuation is a far better signal than any list of opening words, and
  /// transcription providers are reliable about it.
  public static func questions(in segments: [MeetingSegment]) -> [String] {
    var found: [String] = []
    var seen = Set<String>()
    for segment in segments {
      for sentence in sentences(in: segment.text) where sentence.hasSuffix("?") {
        let key = sentence.lowercased()
        guard !seen.contains(key), sentence.count > 8 else { continue }
        seen.insert(key)
        found.append(sentence)
      }
    }
    return found
  }

  private static func matches(
    in segments: [MeetingSegment], cues: [String], excluding: Set<String> = []
  ) -> [String] {
    var found: [String] = []
    var seen = Set<String>()
    for segment in segments {
      for sentence in sentences(in: segment.text) {
        let lowered = sentence.lowercased()
        guard cues.contains(where: { lowered.contains($0) }) else { continue }
        guard !seen.contains(lowered), !excluding.contains(sentence) else { continue }
        seen.insert(lowered)
        found.append(sentence)
      }
    }
    return found
  }

  /// The segments most likely worth replaying, oldest first.
  public static func keyMoments(in segments: [MeetingSegment], limit: Int) -> [MeetingKeyMoment] {
    guard limit > 0 else { return [] }
    let scored = segments.enumerated().map { index, segment -> (Int, Int, MeetingSegment) in
      let lowered = segment.text.lowercased()
      var score = 0
      if decisionCues.contains(where: { lowered.contains($0) }) { score += 4 }
      if actionCues.contains(where: { lowered.contains($0) }) { score += 2 }
      if lowered.contains("?") { score += 1 }
      score += min(3, segment.text.count / 200)
      return (score, index, segment)
    }
    return
      scored
      .filter { $0.0 > 0 }
      .sorted { left, right in
        left.0 == right.0 ? left.1 < right.1 : left.0 > right.0
      }
      .prefix(limit)
      .sorted { $0.2.startedMilliseconds < $1.2.startedMilliseconds }
      .map {
        MeetingKeyMoment(
          startedMilliseconds: $0.2.startedMilliseconds, channel: $0.2.channel,
          text: $0.2.text)
      }
  }

  /// Splits text into sentences, keeping the terminator.
  ///
  /// A linear scan rather than a pattern. Transcripts run to tens of thousands of
  /// characters and arrive from a model, which is exactly the shape of input that
  /// turns a lazy regex into a hang; see the cleanup work for the one that already
  /// bit this codebase.
  public static func sentences(in text: String) -> [String] {
    var sentences: [String] = []
    var current = ""
    for character in text {
      if character == "\n" {
        appendSentence(current, to: &sentences)
        current = ""
        continue
      }
      current.append(character)
      if character == "." || character == "!" || character == "?" {
        appendSentence(current, to: &sentences)
        current = ""
      }
    }
    appendSentence(current, to: &sentences)
    return sentences
  }

  private static func appendSentence(_ text: String, to sentences: inout [String]) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    sentences.append(trimmed)
  }

  /// "12 minute", "1 hour 5 minute" — used inside a sentence, so no trailing plural.
  public static func humanDuration(_ milliseconds: Int) -> String {
    let totalMinutes = max(0, milliseconds) / 60_000
    if totalMinutes < 1 { return "A brief" }
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours == 0 { return "A \(minutes) minute" }
    if minutes == 0 { return "A \(hours) hour" }
    return "A \(hours) hour \(minutes) minute"
  }

  /// The labelled transcript, truncated to `limit` characters on a line boundary so a
  /// model never receives half a sentence as if it were the end of the meeting.
  public static func transcript(
    _ segments: [MeetingSegment], labels: MeetingSpeakerLabels, limit: Int
  ) -> String {
    var lines: [String] = []
    var used = 0
    for segment in segments {
      let line = "\(segment.displayName(labels)): \(segment.text)"
      if used + line.count > limit {
        lines.append("[transcript truncated]")
        break
      }
      used += line.count + 1
      lines.append(line)
    }
    return lines.joined(separator: "\n")
  }
}
