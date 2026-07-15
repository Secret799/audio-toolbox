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
        guard FileManager.default.isWritableFile(atPath: url.path) else {
            return false
        }

        return url.path.withCString { path in
            ATCanWriteMetadata(path)
        }
    }

    public func write(url: URL, patch: MetadataPatch) async throws {
        guard await canWrite(url: url) else {
            throw MetadataServiceError.notWritable("文件不可写或格式不支持标签写入")
        }

        var result = url.path.withCString { path in
            withOptionalCString(patch.artist) { artist in
                withOptionalCString(patch.album) { album in
                    ATWriteMetadata(path, artist, album)
                }
            }
        }
        defer {
            ATFreeWriteResult(&result)
        }

        guard result.status == 0 else {
            let message = result.error_message.map { String(cString: $0) }
                ?? "TagLib 保存音频标签失败"
            throw MetadataServiceError.saveFailed(message)
        }

        let savedMetadata: AudioMetadata
        do {
            savedMetadata = try await read(url: url)
        } catch {
            throw MetadataServiceError.verificationFailed("保存后无法重新读取音频标签")
        }

        if let artist = patch.artist, savedMetadata.artists.first != artist {
            throw MetadataServiceError.verificationFailed("作者标签写后验证失败")
        }
        if let album = patch.album, savedMetadata.albums.first != album {
            throw MetadataServiceError.verificationFailed("专辑标签写后验证失败")
        }
    }

    private func withOptionalCString<Result>(
        _ value: String?,
        operation: (UnsafePointer<CChar>?) -> Result
    ) -> Result {
        guard let value else {
            return operation(nil)
        }
        return value.withCString(operation)
    }
}
