import Foundation

public struct SuspectedDuplicateMembership: Equatable, Sendable {
    public let groupNumber: Int
    public let similarity: Double
    public let durationDifference: TimeInterval

    public init(
        groupNumber: Int,
        similarity: Double,
        durationDifference: TimeInterval
    ) {
        self.groupNumber = groupNumber
        self.similarity = similarity
        self.durationDifference = durationDifference
    }
}

public enum SuspectedDuplicateDetector {
    public static let minimumTitleSimilarity = 0.85

    public static func analyze(
        _ tracks: [AudioTrack],
        locale: Locale = .current
    ) -> [FileIdentity: SuspectedDuplicateMembership] {
        guard tracks.count > 1 else { return [:] }

        let orderedTracks = LibraryProjection.sortedTracks(tracks, locale: locale)
        let candidates = orderedTracks.map { track in
            Candidate(
                track: track,
                normalizedTitle: normalizedTitle(for: track, locale: locale)
            )
        }
        var unionFind = UnionFind(count: candidates.count)
        var edges: [MatchEdge] = []

        for leftIndex in candidates.indices {
            for rightIndex in candidates.indices where rightIndex > leftIndex {
                guard let edge = match(
                    candidates[leftIndex],
                    candidates[rightIndex],
                    leftIndex: leftIndex,
                    rightIndex: rightIndex
                ) else { continue }
                edges.append(edge)
                unionFind.join(leftIndex, rightIndex)
            }
        }

        guard !edges.isEmpty else { return [:] }

        var memberIndicesByRoot: [Int: [Int]] = [:]
        for index in candidates.indices {
            memberIndicesByRoot[unionFind.root(of: index), default: []].append(index)
        }
        let duplicateClusters = memberIndicesByRoot.values
            .filter { $0.count > 1 }
            .sorted { ($0.min() ?? .max) < ($1.min() ?? .max) }

        var result: [FileIdentity: SuspectedDuplicateMembership] = [:]
        for (offset, memberIndices) in duplicateClusters.enumerated() {
            let groupNumber = offset + 1
            let memberSet = Set(memberIndices)
            let clusterEdges = edges.filter {
                memberSet.contains($0.leftIndex) && memberSet.contains($0.rightIndex)
            }
            for memberIndex in memberIndices {
                let memberEdges = clusterEdges
                    .filter { $0.leftIndex == memberIndex || $0.rightIndex == memberIndex }
                    .sorted(by: isBetterMatch)
                guard let bestEdge = memberEdges.first else { continue }
                result[candidates[memberIndex].track.id] = SuspectedDuplicateMembership(
                    groupNumber: groupNumber,
                    similarity: bestEdge.similarity,
                    durationDifference: bestEdge.durationDifference
                )
            }
        }
        return result
    }

    private static func match(
        _ left: Candidate,
        _ right: Candidate,
        leftIndex: Int,
        rightIndex: Int
    ) -> MatchEdge? {
        guard !left.normalizedTitle.isEmpty,
              !right.normalizedTitle.isEmpty,
              let leftDuration = validDuration(left.track.metadata.duration),
              let rightDuration = validDuration(right.track.metadata.duration) else {
            return nil
        }

        let similarity = titleSimilarity(left.normalizedTitle, right.normalizedTitle)
        guard similarity >= minimumTitleSimilarity else { return nil }

        let durationDifference = abs(leftDuration - rightDuration)
        let allowedDifference = max(2, max(leftDuration, rightDuration) * 0.01)
        guard durationDifference <= allowedDifference else { return nil }

        return MatchEdge(
            leftIndex: leftIndex,
            rightIndex: rightIndex,
            similarity: similarity,
            durationDifference: durationDifference
        )
    }

    private static func normalizedTitle(for track: AudioTrack, locale: Locale) -> String {
        let source = track.metadata.title?.trimmedNonEmpty
            ?? track.url.deletingPathExtension().lastPathComponent
        let withoutCopySuffixes = removingCopySuffixes(from: source)
        return withoutCopySuffixes
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func removingCopySuffixes(from source: String) -> String {
        var value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        while let range = copySuffixPatterns.lazy.compactMap({ pattern in
            value.range(
                of: pattern,
                options: [.regularExpression, .caseInsensitive]
            )
        }).first {
            let shortened = String(value[..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard shortened != value else { break }
            value = shortened
        }
        return value
    }

    private static func validDuration(_ duration: TimeInterval?) -> TimeInterval? {
        guard let duration, duration.isFinite, duration >= 0 else { return nil }
        return duration
    }

    private static func titleSimilarity(_ left: String, _ right: String) -> Double {
        if left == right { return 1 }
        let leftCharacters = Array(left)
        let rightCharacters = Array(right)
        let longestCount = max(leftCharacters.count, rightCharacters.count)
        guard longestCount > 0 else { return 1 }
        let distance = levenshteinDistance(leftCharacters, rightCharacters)
        return 1 - Double(distance) / Double(longestCount)
    }

    private static func levenshteinDistance(
        _ left: [Character],
        _ right: [Character]
    ) -> Int {
        if left.isEmpty { return right.count }
        if right.isEmpty { return left.count }

        var previous = Array(0...right.count)
        for (leftOffset, leftCharacter) in left.enumerated() {
            var current = [leftOffset + 1]
            current.reserveCapacity(right.count + 1)
            for (rightOffset, rightCharacter) in right.enumerated() {
                current.append(min(
                    current[rightOffset] + 1,
                    previous[rightOffset + 1] + 1,
                    previous[rightOffset] + (leftCharacter == rightCharacter ? 0 : 1)
                ))
            }
            previous = current
        }
        return previous[right.count]
    }

    private static func isBetterMatch(_ left: MatchEdge, _ right: MatchEdge) -> Bool {
        if left.similarity != right.similarity {
            return left.similarity > right.similarity
        }
        if left.durationDifference != right.durationDifference {
            return left.durationDifference < right.durationDifference
        }
        if left.leftIndex != right.leftIndex {
            return left.leftIndex < right.leftIndex
        }
        return left.rightIndex < right.rightIndex
    }

    private static let copySuffixPatterns = [
        #"(?:[\s._-]*(?:copy|副本|复制(?:的)?)(?:[\s._-]*(?:\d+|[(（]\s*\d+\s*[)）]))?)[\s._-]*$"#,
        #"(?:[\s._-]*[(（]\s*(?:copy|副本|复制(?:的)?)(?:\s*\d+)?\s*[)）])[\s._-]*$"#,
        #"(?:[\s._-]*[(（]\s*\d+\s*[)）])[\s._-]*$"#,
    ]

}

private struct Candidate {
    let track: AudioTrack
    let normalizedTitle: String
}

private struct MatchEdge {
    let leftIndex: Int
    let rightIndex: Int
    let similarity: Double
    let durationDifference: TimeInterval
}

private struct UnionFind {
    private var parents: [Int]

    init(count: Int) {
        parents = Array(0..<count)
    }

    mutating func root(of index: Int) -> Int {
        if parents[index] != index {
            parents[index] = root(of: parents[index])
        }
        return parents[index]
    }

    mutating func join(_ left: Int, _ right: Int) {
        let leftRoot = root(of: left)
        let rightRoot = root(of: right)
        if leftRoot != rightRoot {
            parents[rightRoot] = leftRoot
        }
    }
}
