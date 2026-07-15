import Foundation

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
        locale: Locale = .current
    ) -> [AudioTrack] {
        tracks.sorted { left, right in
            let leftDisplayName = displayName(for: left)
            let rightDisplayName = displayName(for: right)

            switch compare(leftDisplayName, rightDisplayName, locale: locale) {
            case .orderedAscending:
                return true
            case .orderedDescending:
                return false
            case .orderedSame:
                if leftDisplayName != rightDisplayName {
                    return leftDisplayName < rightDisplayName
                }
                return left.id.rawValue < right.id.rawValue
            }
        }
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
