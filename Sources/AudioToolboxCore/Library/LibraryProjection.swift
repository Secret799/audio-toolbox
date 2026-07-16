import Foundation

public enum TrackTitleSortDirection: Sendable {
    case ascending
    case descending
}

public struct AudioTrackTitleComparator: SortComparator, Sendable {
    public var order: SortOrder
    private let localeIdentifier: String

    public init(order: SortOrder = .forward, locale: Locale = .current) {
        self.order = order
        localeIdentifier = locale.identifier
    }

    public func compare(_ lhs: AudioTrack, _ rhs: AudioTrack) -> ComparisonResult {
        let result = LibraryProjection.compareTracks(
            lhs,
            rhs,
            locale: Locale(identifier: localeIdentifier)
        )
        guard order == .reverse else { return result }
        switch result {
        case .orderedAscending:
            return .orderedDescending
        case .orderedDescending:
            return .orderedAscending
        case .orderedSame:
            return .orderedSame
        }
    }
}

public enum LibraryProjection {
    public static func groups(
        tracks: [AudioTrack],
        mode: GroupingMode,
        locale: Locale = .current
    ) -> [AudioGroup] {
        let buckets = Dictionary(grouping: tracks) { track in
            switch mode {
            case .artist:
                track.metadata.artistDisplayName
            case .album:
                track.metadata.albumDisplayName
            }
        }

        return buckets.map { displayName, tracks in
            AudioGroup(
                id: "\(mode.rawValue):\(displayName)",
                displayName: displayName,
                trackIDs: sortedTracks(tracks, locale: locale).map(\.id)
            )
        }.sorted { left, right in
            isOrderedBefore(left.displayName, right.displayName, locale: locale)
        }
    }

    public static func sortedTracks(
        _ tracks: [AudioTrack],
        direction: TrackTitleSortDirection = .ascending,
        locale: Locale = .current
    ) -> [AudioTrack] {
        tracks.sorted { left, right in
            let result = compareTracks(left, right, locale: locale)
            switch direction {
            case .ascending:
                return result == .orderedAscending
            case .descending:
                return result == .orderedDescending
            }
        }
    }

    fileprivate static func compareTracks(
        _ left: AudioTrack,
        _ right: AudioTrack,
        locale: Locale
    ) -> ComparisonResult {
        let leftDisplayName = displayName(for: left)
        let rightDisplayName = displayName(for: right)

        let localizedResult = compare(leftDisplayName, rightDisplayName, locale: locale)
        if localizedResult != .orderedSame {
            return localizedResult
        }
        if leftDisplayName != rightDisplayName {
            return leftDisplayName < rightDisplayName ? .orderedAscending : .orderedDescending
        }
        if left.url.lastPathComponent != right.url.lastPathComponent {
            return left.url.lastPathComponent < right.url.lastPathComponent
                ? .orderedAscending
                : .orderedDescending
        }
        if left.id.rawValue == right.id.rawValue {
            return .orderedSame
        }
        return left.id.rawValue < right.id.rawValue ? .orderedAscending : .orderedDescending
    }

    private static func displayName(for track: AudioTrack) -> String {
        track.metadata.title?.trimmedNonEmpty ?? track.url.lastPathComponent
    }

    private static func isOrderedBefore(_ left: String, _ right: String, locale: Locale) -> Bool {
        switch compare(left, right, locale: locale) {
        case .orderedAscending:
            true
        case .orderedDescending:
            false
        case .orderedSame:
            left < right
        }
    }

    private static func compare(_ left: String, _ right: String, locale: Locale) -> ComparisonResult {
        left.compare(
            right,
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: locale
        )
    }
}
