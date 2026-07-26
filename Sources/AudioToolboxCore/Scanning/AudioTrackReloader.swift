import Foundation

public protocol AudioTrackReloading: Sendable {
    func reload(url: URL) async throws -> AudioTrack
}

public enum AudioTrackReloadError: LocalizedError, Equatable, Sendable {
    case unsupportedFormat(URL)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedFormat(url):
            "不支持的音频格式：\(url.lastPathComponent)"
        }
    }
}

public struct AudioTrackReloader: AudioTrackReloading {
    private let metadataService: any MetadataService

    public init(metadataService: any MetadataService) {
        self.metadataService = metadataService
    }

    public func reload(url: URL) async throws -> AudioTrack {
        let url = url.standardizedFileURL
        guard let format = AudioFileCandidate.format(for: url) else {
            throw AudioTrackReloadError.unsupportedFormat(url)
        }

        let fingerprint = try StableFileIdentityResolver.fingerprint(for: url)
        let metadata = try await metadataService.read(url: url)
        let isWritable = await metadataService.canWrite(url: url)

        return AudioTrack(
            id: fingerprint.fileIdentity,
            url: url,
            format: format,
            metadata: metadata,
            fileSize: fingerprint.fileSize,
            modificationDate: fingerprint.modificationDate,
            isWritable: isWritable,
            issue: nil
        )
    }
}
