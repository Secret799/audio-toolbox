import Foundation

public struct ArtistComposerIdentity: Hashable, Sendable {
    public let artist: String?
    public let composer: String?

    public init(artist: String?, composer: String?) {
        self.artist = artist
        self.composer = composer
    }
}

public enum ArtistComposerAuthority: CaseIterable, Hashable, Sendable {
    case artist
    case composer
}

public struct ArtistComposerSyncRow: Identifiable, Equatable, Sendable {
    public let id: ArtistComposerIdentity
    public let artistDisplayName: String
    public let composerDisplayName: String
    public let totalCount: Int
    public let editableCount: Int
    public let unavailableCount: Int

    public init(
        id: ArtistComposerIdentity,
        artistDisplayName: String,
        composerDisplayName: String,
        totalCount: Int,
        editableCount: Int,
        unavailableCount: Int
    ) {
        self.id = id
        self.artistDisplayName = artistDisplayName
        self.composerDisplayName = composerDisplayName
        self.totalCount = totalCount
        self.editableCount = editableCount
        self.unavailableCount = unavailableCount
    }
}

public struct ArtistComposerSyncPreview: Identifiable, Equatable, Sendable {
    public let id: ArtistComposerIdentity
    public let artistDisplayName: String
    public let composerDisplayName: String
    public let unifiedValue: String
    public let editableCount: Int
    public let unavailableCount: Int

    public init(
        id: ArtistComposerIdentity,
        artistDisplayName: String,
        composerDisplayName: String,
        unifiedValue: String,
        editableCount: Int,
        unavailableCount: Int
    ) {
        self.id = id
        self.artistDisplayName = artistDisplayName
        self.composerDisplayName = composerDisplayName
        self.unifiedValue = unifiedValue
        self.editableCount = editableCount
        self.unavailableCount = unavailableCount
    }
}

public enum ArtistComposerSyncPlanner {
    public static func identity(for track: AudioTrack) -> ArtistComposerIdentity {
        ArtistComposerIdentity(
            artist: firstNormalizedValue(in: track.metadata.artists),
            composer: firstNormalizedValue(in: track.metadata.composers)
        )
    }

    public static func rows(
        from tracks: [AudioTrack],
        locale: Locale = .current
    ) -> [ArtistComposerSyncRow] {
        Dictionary(grouping: tracks, by: identity(for:))
            .compactMap { identity, groupedTracks in
                guard identity.artist != identity.composer else { return nil }
                let editableCount = groupedTracks.count(where: \.isEditable)
                return ArtistComposerSyncRow(
                    id: identity,
                    artistDisplayName: displayName(identity.artist),
                    composerDisplayName: displayName(identity.composer),
                    totalCount: groupedTracks.count,
                    editableCount: editableCount,
                    unavailableCount: groupedTracks.count - editableCount
                )
            }
            .sorted { isOrderedBefore($0, $1, locale: locale) }
    }

    public static func automaticDrafts(
        rows: [ArtistComposerSyncRow],
        authority: ArtistComposerAuthority
    ) -> [ArtistComposerIdentity: String] {
        Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            automaticValue(for: row.id, authority: authority).map { (row.id, $0) }
        })
    }

    public static func previews(
        tracks: [AudioTrack],
        drafts: [ArtistComposerIdentity: String],
        locale: Locale = .current
    ) -> [ArtistComposerSyncPreview] {
        rows(from: tracks, locale: locale).compactMap { row in
            guard row.editableCount > 0,
                  let target = destination(for: row.id, drafts: drafts)
            else {
                return nil
            }
            return ArtistComposerSyncPreview(
                id: row.id,
                artistDisplayName: row.artistDisplayName,
                composerDisplayName: row.composerDisplayName,
                unifiedValue: target,
                editableCount: row.editableCount,
                unavailableCount: row.unavailableCount
            )
        }
    }

    public static func operations(
        tracks: [AudioTrack],
        drafts: [ArtistComposerIdentity: String]
    ) -> [BatchEditOperation] {
        tracks.compactMap { track in
            let identity = identity(for: track)
            guard track.isEditable,
                  identity.artist != identity.composer,
                  let target = destination(for: identity, drafts: drafts)
            else {
                return nil
            }

            let patch = MetadataPatch(
                artist: identity.artist == target ? nil : target,
                album: nil,
                composer: identity.composer == target ? nil : target
            )
            guard patch.artist != nil || patch.composer != nil else { return nil }
            return BatchEditOperation(
                target: BatchEditTarget(
                    url: track.url,
                    fileIdentity: track.id,
                    fileSize: track.fileSize,
                    modificationDate: track.modificationDate
                ),
                patch: patch
            )
        }
    }

    private static func firstNormalizedValue(in values: [String]) -> String? {
        values.lazy.compactMap(\.trimmedNonEmpty).first
    }

    private static func destination(
        for identity: ArtistComposerIdentity,
        drafts: [ArtistComposerIdentity: String]
    ) -> String? {
        drafts[identity]?.trimmedNonEmpty
    }

    private static func automaticValue(
        for identity: ArtistComposerIdentity,
        authority: ArtistComposerAuthority
    ) -> String? {
        switch (identity.artist, identity.composer) {
        case let (artist?, nil):
            artist
        case let (nil, composer?):
            composer
        case let (artist?, composer?):
            authority == .artist ? artist : composer
        case (nil, nil):
            nil
        }
    }

    private static func displayName(_ value: String?) -> String {
        value ?? "未设置"
    }

    private static func isOrderedBefore(
        _ left: ArtistComposerSyncRow,
        _ right: ArtistComposerSyncRow,
        locale: Locale
    ) -> Bool {
        let artistResult = compare(
            left.artistDisplayName,
            right.artistDisplayName,
            locale: locale
        )
        if artistResult != .orderedSame {
            return artistResult == .orderedAscending
        }

        let composerResult = compare(
            left.composerDisplayName,
            right.composerDisplayName,
            locale: locale
        )
        if composerResult != .orderedSame {
            return composerResult == .orderedAscending
        }
        return identityTieBreaker(left.id) < identityTieBreaker(right.id)
    }

    private static func compare(
        _ left: String,
        _ right: String,
        locale: Locale
    ) -> ComparisonResult {
        let result = left.compare(
            right,
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            range: nil,
            locale: locale
        )
        if result != .orderedSame { return result }
        if left == right { return .orderedSame }
        return left < right ? .orderedAscending : .orderedDescending
    }

    private static func identityTieBreaker(_ identity: ArtistComposerIdentity) -> String {
        "artist:\(identity.artist ?? "<nil>")|composer:\(identity.composer ?? "<nil>")"
    }
}
