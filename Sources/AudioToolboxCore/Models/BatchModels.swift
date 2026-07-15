import Foundation

public struct MetadataPatch: Equatable, Sendable {
    public let artist: String?
    public let album: String?

    public init(artist: String?, album: String?) {
        self.artist = artist?.trimmedNonEmpty
        self.album = album?.trimmedNonEmpty
    }

    public static func validated(artist: String?, album: String?) -> MetadataPatch? {
        let patch = MetadataPatch(artist: artist, album: album)
        return patch.artist == nil && patch.album == nil ? nil : patch
    }
}

public struct BatchEditRequest: Sendable {
    public let files: [URL]
    public let patch: MetadataPatch

    public init(files: [URL], patch: MetadataPatch) {
        self.files = files
        self.patch = patch
    }
}

public enum BatchFileStatus: Equatable, Sendable {
    case succeeded, failed, notProcessed
}

public struct BatchFileResult: Equatable, Sendable {
    public let url: URL
    public let status: BatchFileStatus
    public let message: String?
}

public struct BatchEditSummary: Equatable, Sendable {
    public let results: [BatchFileResult]

    public var succeededCount: Int {
        results.count { $0.status == .succeeded }
    }

    public var failedCount: Int {
        results.count { $0.status == .failed }
    }

    public var notProcessedCount: Int {
        results.count { $0.status == .notProcessed }
    }
}
