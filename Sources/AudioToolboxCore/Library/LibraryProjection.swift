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

        return buckets.map { name, tracks in
            (
                group: AudioGroup(
                    id: "\(mode.rawValue):\(normalized(name, locale: locale))",
                    displayName: name,
                    trackIDs: sortedTracks(tracks, locale: locale).map(\.id)
                ),
                isUnknown: tracks.first.map { isUnknown($0, mode: mode) } ?? true
            )
        }.sorted { left, right in
            if left.isUnknown != right.isUnknown {
                return !left.isUnknown
            }
            return compare(
                left.group.displayName,
                right.group.displayName,
                locale: locale
            ) == .orderedAscending
        }.map(\.group)
    }

    public static func sortedTracks(
        _ tracks: [AudioTrack],
        locale: Locale = .current
    ) -> [AudioTrack] {
        tracks.sorted {
            let left = $0.metadata.title?.trimmedNonEmpty ?? $0.url.lastPathComponent
            let right = $1.metadata.title?.trimmedNonEmpty ?? $1.url.lastPathComponent
            return compare(left, right, locale: locale) == .orderedAscending
        }
    }

    private static func isUnknown(_ track: AudioTrack, mode: GroupingMode) -> Bool {
        switch mode {
        case .artist:
            track.metadata.artists.first?.trimmedNonEmpty == nil
        case .album:
            track.metadata.albums.first?.trimmedNonEmpty == nil
        }
    }

    private static func normalized(_ value: String, locale: Locale) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: locale
        )
    }

    private static func compare(_ left: String, _ right: String, locale: Locale) -> ComparisonResult {
        left.compare(
            right,
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: locale
        )
    }
}
