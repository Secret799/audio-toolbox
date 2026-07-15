import Foundation

public struct FileIdentity: Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum AudioFormat: String, Sendable, Codable, CaseIterable {
    case mp3, m4a, mp4, aac, flac, wav, ogg, oga
}

public struct AudioMetadata: Equatable, Sendable {
    public var title: String?
    public var artists: [String]
    public var albums: [String]
    public var duration: TimeInterval?

    public init(title: String?, artists: [String], albums: [String], duration: TimeInterval?) {
        self.title = title
        self.artists = artists
        self.albums = albums
        self.duration = duration
    }

    public var artistDisplayName: String {
        artists.first?.trimmedNonEmpty ?? "未知作者"
    }

    public var albumDisplayName: String {
        albums.first?.trimmedNonEmpty ?? "未知专辑"
    }
}

public enum AudioFileIssue: Equatable, Sendable {
    case unreadable(String)
    case notWritable(String)
    case unsupportedTag(String)
}

public struct AudioTrack: Identifiable, Equatable, Sendable {
    public let id: FileIdentity
    public let url: URL
    public let format: AudioFormat
    public var metadata: AudioMetadata
    public let fileSize: Int64
    public let modificationDate: Date
    public let isWritable: Bool
    public let issue: AudioFileIssue?
}

public enum GroupingMode: String, CaseIterable, Sendable {
    case artist, album
}

public struct AudioGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let trackIDs: [FileIdentity]
}

extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
