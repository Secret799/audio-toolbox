import CTagLibBridge
import Foundation

public actor TagLibMetadataService: MetadataService {
    public init() {}

    public func read(url: URL) async throws -> AudioMetadata {
        var result = url.path.withCString { path in
            ATReadMetadata(path)
        }
        defer {
            ATFreeReadResult(&result)
        }

        guard result.status == 0 else {
            let message = result.error_message.map { String(cString: $0) }
                ?? "无法读取音频标签"
            throw MetadataServiceError.unreadable(message)
        }

        return AudioMetadata(
            title: result.title.map { String(cString: $0) },
            artists: result.artist.map { [String(cString: $0)] } ?? [],
            albums: result.album.map { [String(cString: $0)] } ?? [],
            duration: result.duration_seconds > 0 ? result.duration_seconds : nil
        )
    }

    public func canWrite(url: URL) async -> Bool {
        FileManager.default.isWritableFile(atPath: url.path)
    }

    public func write(url: URL, patch: MetadataPatch) async throws {
        throw MetadataServiceError.unsupported("标签写入尚未接入")
    }
}
