import Foundation

/// What happened to a run of words between the original and the result.
public enum DiffOperation: String, Equatable, Sendable, Codable {
  case equal, insert, delete
}

/// A consecutive run of words sharing one operation. Runs rather than single words,
/// because the caller is drawing them and a per-word list would make it re-group
/// everything before it could paint a strikethrough.
public struct DiffRun: Equatable, Sendable, Codable {
  public var operation: DiffOperation
  public var words: [String]

  public init(operation: DiffOperation, words: [String]) {
    self.operation = operation
    self.words = words
  }

  public var text: String { words.joined(separator: " ") }
}

/// A word-level diff, so a transform can be shown as a change rather than as a new
/// block of text the user has to re-read from the top.
///
/// Word-level, not character-level: a model rewrite moves whole words around, and a
/// character diff of two rewritten paragraphs is visual noise that hides the one
/// sentence that actually changed.
///
/// The algorithm is Myers' greedy edit-script search. It costs O(N·D) in the number
/// of words N and the edit distance D, which is the right shape for this job — two
/// versions of the same paragraph differ in a handful of words, and the search
/// finishes almost immediately. The failure mode it avoids is the obvious
/// alternative: a full LCS table is O(N·M) time *and memory*, so diffing two
/// four-thousand-word documents would allocate sixteen million cells to answer a
/// question about a preview panel.
///
/// The two texts are unrelated often enough — "translate this" — that D can approach
/// N + M, and the search would then do the quadratic work anyway. So the search is
/// capped: beyond `maximumEditDistance` steps it gives up and reports the middle as
/// one deletion followed by one insertion, which is a true description of the change
/// and merely a coarse one. A preview that is slightly less granular is a far better
/// outcome than a UI that stalls after the user pressed a shortcut.
public enum TextDiff {

  /// The default ceiling on the edit-script search. A thousand differing words is far
  /// past the point where a word-level highlight is telling the reader anything.
  public static let defaultMaximumEditDistance = 1_000

  /// Splits on whitespace only. Punctuation stays attached to its word, so "Thursday."
  /// and "Thursday" read as a change — which they are, and which a reader wants to see.
  public static func words(_ text: String) -> [String] {
    text.split(whereSeparator: \.isWhitespace).map(String.init)
  }

  public static func diff(
    original: String, result: String, maximumEditDistance: Int = defaultMaximumEditDistance
  ) -> [DiffRun] {
    diff(
      original: words(original), result: words(result),
      maximumEditDistance: maximumEditDistance)
  }

  public static func diff(
    original: [String], result: [String],
    maximumEditDistance: Int = defaultMaximumEditDistance
  ) -> [DiffRun] {
    // Trimming the shared head and tail first is what makes the common case — a
    // rewrite of one clause in a long paragraph — cost almost nothing.
    var head = 0
    while head < original.count, head < result.count, original[head] == result[head] {
      head += 1
    }
    var tail = 0
    while tail < original.count - head, tail < result.count - head,
      original[original.count - 1 - tail] == result[result.count - 1 - tail]
    {
      tail += 1
    }

    let middleOriginal = Array(original[head..<(original.count - tail)])
    let middleResult = Array(result[head..<(result.count - tail)])

    let middle =
      myers(middleOriginal, middleResult, limit: maximumEditDistance)
      ?? coarse(middleOriginal, middleResult)

    var runs: [DiffRun] = []
    if head > 0 { runs.append(DiffRun(operation: .equal, words: Array(original[0..<head]))) }
    runs.append(contentsOf: middle)
    if tail > 0 {
      runs.append(DiffRun(operation: .equal, words: Array(original[(original.count - tail)...])))
    }
    return merge(runs)
  }

  /// Words added and removed, for the one-line summary above a preview.
  public static func summary(_ runs: [DiffRun]) -> (inserted: Int, deleted: Int) {
    var inserted = 0
    var deleted = 0
    for run in runs {
      switch run.operation {
      case .insert: inserted += run.words.count
      case .delete: deleted += run.words.count
      case .equal: break
      }
    }
    return (inserted, deleted)
  }

  /// True when the transform did nothing. Worth knowing before showing a preview that
  /// asks the user to approve no change at all.
  public static func isUnchanged(_ runs: [DiffRun]) -> Bool {
    runs.allSatisfy { $0.operation == .equal }
  }

  // MARK: - The search

  /// Myers' greedy algorithm. Returns nil when the edit distance exceeds `limit`,
  /// which is the signal to fall back rather than keep paying for a diff nobody can read.
  ///
  /// Each iteration keeps only the diagonals it can actually reach — `2d + 1` of them
  /// — so the recorded trace costs O(D²) integers rather than O(D·N). With the
  /// default limit that is about a million machine words in the worst case and a few
  /// hundred in the ordinary one.
  static func myers(_ a: [String], _ b: [String], limit: Int) -> [DiffRun]? {
    let n = a.count
    let m = b.count
    if n == 0 && m == 0 { return [] }
    if n == 0 { return [DiffRun(operation: .insert, words: b)] }
    if m == 0 { return [DiffRun(operation: .delete, words: a)] }

    let ceiling = min(limit, n + m)
    let offset = n + m
    // Indexed by diagonal k + offset; only diagonals of the current parity are live.
    var v = [Int](repeating: 0, count: 2 * (n + m) + 1)
    var trace: [[Int]] = []
    trace.reserveCapacity(ceiling + 1)

    for d in 0...ceiling {
      // Snapshot before the step, holding the diagonals reachable in d - 1 moves.
      trace.append(Array(v[(offset - d)...(offset + d)]))

      var k = -d
      while k <= d {
        var x: Int
        if k == -d || (k != d && v[k - 1 + offset] < v[k + 1 + offset]) {
          x = v[k + 1 + offset]
        } else {
          x = v[k - 1 + offset] + 1
        }
        var y = x - k
        while x < n, y < m, a[x] == b[y] {
          x += 1
          y += 1
        }
        v[k + offset] = x
        if x >= n, y >= m {
          return runs(backtrack(a, b, trace: trace, offsetInSnapshot: true))
        }
        k += 2
      }
    }
    return nil
  }

  /// Walks the recorded traces back from the end, emitting one edit per step.
  ///
  /// `trace[d]` is indexed by `k + d`, because the snapshot only spans the diagonals
  /// `-d…d`. The greedy loop never reads outside that span: at `k == -d` the
  /// comparison short-circuits before touching `k - 1`, and at `k == d` it never
  /// reaches for `k + 1`.
  private static func backtrack(
    _ a: [String], _ b: [String], trace: [[Int]], offsetInSnapshot: Bool
  ) -> [(DiffOperation, String)] {
    var edits: [(DiffOperation, String)] = []
    var x = a.count
    var y = b.count

    for d in stride(from: trace.count - 1, through: 0, by: -1) {
      let snapshot = trace[d]
      let k = x - y
      let previousK: Int
      if k == -d || (k != d && snapshot[k - 1 + d] < snapshot[k + 1 + d]) {
        previousK = k + 1
      } else {
        previousK = k - 1
      }
      let previousX = snapshot[previousK + d]
      let previousY = previousX - previousK

      while x > previousX, y > previousY {
        x -= 1
        y -= 1
        edits.append((.equal, a[x]))
      }
      if d > 0 {
        if x == previousX {
          y -= 1
          edits.append((.insert, b[y]))
        } else {
          x -= 1
          edits.append((.delete, a[x]))
        }
      }
      x = previousX
      y = previousY
    }
    return edits.reversed()
  }

  /// The fallback: everything that is left is a wholesale replacement.
  private static func coarse(_ a: [String], _ b: [String]) -> [DiffRun] {
    var runs: [DiffRun] = []
    if !a.isEmpty { runs.append(DiffRun(operation: .delete, words: a)) }
    if !b.isEmpty { runs.append(DiffRun(operation: .insert, words: b)) }
    return runs
  }

  private static func runs(_ edits: [(DiffOperation, String)]) -> [DiffRun] {
    var runs: [DiffRun] = []
    for edit in edits {
      if var last = runs.last, last.operation == edit.0 {
        last.words.append(edit.1)
        runs[runs.count - 1] = last
      } else {
        runs.append(DiffRun(operation: edit.0, words: [edit.1]))
      }
    }
    return runs
  }

  /// Joins neighbouring runs the head/tail trim left adjacent, and drops empties, so
  /// the output has one run per change rather than one per stage of the algorithm.
  private static func merge(_ runs: [DiffRun]) -> [DiffRun] {
    var merged: [DiffRun] = []
    for run in runs where !run.words.isEmpty {
      if var last = merged.last, last.operation == run.operation {
        last.words.append(contentsOf: run.words)
        merged[merged.count - 1] = last
      } else {
        merged.append(run)
      }
    }
    return merged
  }
}
