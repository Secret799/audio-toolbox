import Foundation

public enum AuthorIdentity: Hashable, Sendable {
    case named(String)
    case unknown

    public var displayName: String {
        switch self {
        case let .named(value):
            value
        case .unknown:
            "未知作者"
        }
    }
}

public struct AuthorRenameRow: Identifiable, Equatable, Sendable {
    public let id: AuthorIdentity
    public let displayName: String
    public let totalCount: Int
    public let editableCount: Int
    public let unavailableCount: Int

    public init(
        id: AuthorIdentity,
        displayName: String,
        totalCount: Int,
        editableCount: Int,
        unavailableCount: Int
    ) {
        self.id = id
        self.displayName = displayName
        self.totalCount = totalCount
        self.editableCount = editableCount
        self.unavailableCount = unavailableCount
    }
}

public struct AuthorRenamePreview: Identifiable, Equatable, Sendable {
    public let id: AuthorIdentity
    public let oldAuthor: String
    public let newAuthor: String
    public let editableCount: Int
    public let unavailableCount: Int

    public init(
        id: AuthorIdentity,
        oldAuthor: String,
        newAuthor: String,
        editableCount: Int,
        unavailableCount: Int
    ) {
        self.id = id
        self.oldAuthor = oldAuthor
        self.newAuthor = newAuthor
        self.editableCount = editableCount
        self.unavailableCount = unavailableCount
    }
}

public enum AuthorRenamePlanner {
    public static func identity(for track: AudioTrack) -> AuthorIdentity {
        let artist = track.metadata.artists.lazy.compactMap { value -> String? in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        }.first
        return artist.map(AuthorIdentity.named) ?? .unknown
    }

    public static func rows(
        from tracks: [AudioTrack],
        locale: Locale = .current
    ) -> [AuthorRenameRow] {
        Dictionary(grouping: tracks, by: identity(for:))
            .map { identity, groupedTracks in
                let editableCount = groupedTracks.count(where: \.isEditable)
                return AuthorRenameRow(
                    id: identity,
                    displayName: identity.displayName,
                    totalCount: groupedTracks.count,
                    editableCount: editableCount,
                    unavailableCount: groupedTracks.count - editableCount
                )
            }
            .sorted { isOrderedBefore($0, $1, locale: locale) }
    }

    public static func previews(
        tracks: [AudioTrack],
        drafts: [AuthorIdentity: String],
        locale: Locale = .current
    ) -> [AuthorRenamePreview] {
        rows(from: tracks, locale: locale).compactMap { row in
            guard row.editableCount > 0,
                  let destination = destinationAuthor(
                    for: row.id,
                    drafts: drafts
                  ) else {
                return nil
            }
            return AuthorRenamePreview(
                id: row.id,
                oldAuthor: row.displayName,
                newAuthor: destination,
                editableCount: row.editableCount,
                unavailableCount: row.unavailableCount
            )
        }
    }

    public static func operations(
        tracks: [AudioTrack],
        drafts: [AuthorIdentity: String]
    ) -> [BatchEditOperation] {
        tracks.compactMap { track in
            guard track.isEditable,
                  let artist = destinationAuthor(
                    for: identity(for: track),
                    drafts: drafts
                  ) else {
                return nil
            }
            return BatchEditOperation(
                target: BatchEditTarget(
                    url: track.url,
                    fileIdentity: track.id,
                    fileSize: track.fileSize,
                    modificationDate: track.modificationDate
                ),
                patch: MetadataPatch(artist: artist, album: nil)
            )
        }
    }

    private static func destinationAuthor(
        for identity: AuthorIdentity,
        drafts: [AuthorIdentity: String]
    ) -> String? {
        guard let value = drafts[identity],
              let artist = MetadataPatch(artist: value, album: nil).artist else {
            return nil
        }
        if case let .named(original) = identity, artist == original {
            return nil
        }
        return artist
    }

    private static func isOrderedBefore(
        _ left: AuthorRenameRow,
        _ right: AuthorRenameRow,
        locale: Locale
    ) -> Bool {
        let result = left.displayName.compare(
            right.displayName,
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            range: nil,
            locale: locale
        )
        if result != .orderedSame {
            return result == .orderedAscending
        }
        if left.displayName != right.displayName {
            return left.displayName < right.displayName
        }
        return identityTieBreaker(left.id) < identityTieBreaker(right.id)
    }

    private static func identityTieBreaker(_ identity: AuthorIdentity) -> String {
        switch identity {
        case let .named(value):
            "named:\(value)"
        case .unknown:
            "unknown"
        }
    }
}
