import Foundation

public protocol SafeMetadataWriting: Sendable {
    func apply(to url: URL, patch: MetadataPatch) async -> BatchFileResult
}

struct SafeMetadataFileOperations: @unchecked Sendable {
    let copyItem: (URL, URL) throws -> Void
    let replaceItem: (URL, URL) throws -> URL?

    static func live(fileManager: FileManager) -> Self {
        Self(
            copyItem: { source, destination in
                try fileManager.copyItem(at: source, to: destination)
            },
            replaceItem: { original, replacement in
                try fileManager.replaceItemAt(
                    original,
                    withItemAt: replacement,
                    backupItemName: nil,
                    options: []
                )
            }
        )
    }
}

public actor SafeMetadataWriter: SafeMetadataWriting {
    private static let maximumTemporaryNameAttempts = 16

    private let metadataService: any MetadataService
    private let fileManager: FileManager
    private let fileOperations: SafeMetadataFileOperations
    private let temporaryIdentifierProvider: @Sendable () -> String

    public init(
        metadataService: any MetadataService,
        fileManager: FileManager = .default
    ) {
        self.metadataService = metadataService
        self.fileManager = fileManager
        fileOperations = .live(fileManager: fileManager)
        temporaryIdentifierProvider = { UUID().uuidString }
    }

    init(
        metadataService: any MetadataService,
        fileManager: FileManager,
        fileOperations: SafeMetadataFileOperations,
        temporaryIdentifierProvider: @escaping @Sendable () -> String
    ) {
        self.metadataService = metadataService
        self.fileManager = fileManager
        self.fileOperations = fileOperations
        self.temporaryIdentifierProvider = temporaryIdentifierProvider
    }

    public func apply(to url: URL, patch: MetadataPatch) async -> BatchFileResult {
        guard !Task.isCancelled else {
            return result(for: url, status: .notProcessed, message: "操作已取消")
        }
        guard patch.artist != nil || patch.album != nil else {
            return result(for: url, status: .failed, message: "没有需要写入的标签")
        }

        if let message = preflightFailureMessage(for: url) {
            return result(for: url, status: .failed, message: message)
        }

        let originalSnapshot: OriginalFileSnapshot
        do {
            originalSnapshot = try fileSnapshot(for: url)
        } catch {
            return result(
                for: url,
                status: .failed,
                message: "无法记录原文件状态：\(errorMessage(error))"
            )
        }

        guard await metadataService.canWrite(url: url) else {
            return result(for: url, status: .failed, message: "文件格式不支持标签写入")
        }
        guard !Task.isCancelled else {
            return result(for: url, status: .notProcessed, message: "操作已取消")
        }

        let temporaryURL: URL
        do {
            temporaryURL = try createTemporaryCopy(of: url)
        } catch {
            return result(
                for: url,
                status: .failed,
                message: "无法创建安全工作副本：\(errorMessage(error))"
            )
        }

        defer {
            removeTemporaryItemIfPresent(at: temporaryURL)
        }

        guard !Task.isCancelled else {
            return result(for: url, status: .notProcessed, message: "操作已取消")
        }

        do {
            try await metadataService.write(url: temporaryURL, patch: patch)
        } catch is CancellationError where Task.isCancelled {
            return result(for: url, status: .notProcessed, message: "操作已取消")
        } catch {
            return result(
                for: url,
                status: .failed,
                message: "写入安全工作副本失败：\(errorMessage(error))"
            )
        }

        guard !Task.isCancelled else {
            return result(for: url, status: .notProcessed, message: "操作已取消")
        }

        let savedMetadata: AudioMetadata
        do {
            savedMetadata = try await metadataService.read(url: temporaryURL)
        } catch is CancellationError where Task.isCancelled {
            return result(for: url, status: .notProcessed, message: "操作已取消")
        } catch {
            return result(
                for: url,
                status: .failed,
                message: "写入后验证失败：无法重新读取工作副本（\(errorMessage(error))）"
            )
        }

        if let verificationMessage = verificationFailureMessage(
            metadata: savedMetadata,
            patch: patch
        ) {
            return result(for: url, status: .failed, message: verificationMessage)
        }

        guard !Task.isCancelled else {
            return result(for: url, status: .notProcessed, message: "操作已取消")
        }

        guard preflightFailureMessage(for: url) == nil else {
            return result(
                for: url,
                status: .failed,
                message: "原文件在编辑期间发生变化，已取消替换"
            )
        }
        do {
            guard try fileSnapshot(for: url) == originalSnapshot else {
                return result(
                    for: url,
                    status: .failed,
                    message: "原文件在编辑期间发生变化，已取消替换"
                )
            }
        } catch {
            return result(
                for: url,
                status: .failed,
                message: "原文件在编辑期间发生变化，已取消替换"
            )
        }

        do {
            _ = try fileOperations.replaceItem(url, temporaryURL)
        } catch {
            return result(
                for: url,
                status: .failed,
                message: "安全替换原文件失败：\(errorMessage(error))"
            )
        }

        return result(for: url, status: .succeeded, message: nil)
    }

    private func preflightFailureMessage(for url: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return "文件不存在"
        }
        guard !isDirectory.boolValue else {
            return "目标不是普通文件"
        }

        do {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .isReadableKey,
                .isWritableKey,
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true
            else {
                return "目标不是普通文件"
            }
            guard values.isReadable != false,
                  fileManager.isReadableFile(atPath: url.path)
            else {
                return "文件不可读"
            }
            guard values.isWritable != false,
                  fileManager.isWritableFile(atPath: url.path)
            else {
                return "文件不可写"
            }
        } catch {
            return "无法检查文件状态：\(errorMessage(error))"
        }

        return nil
    }

    private func fileSnapshot(for url: URL) throws -> OriginalFileSnapshot {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return OriginalFileSnapshot(
            systemNumber: (attributes[.systemNumber] as? NSNumber)?.uint64Value,
            systemFileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
            fileSize: (attributes[.size] as? NSNumber)?.uint64Value,
            modificationDate: attributes[.modificationDate] as? Date,
            posixPermissions: (attributes[.posixPermissions] as? NSNumber)?.uint16Value
        )
    }

    private func createTemporaryCopy(of originalURL: URL) throws -> URL {
        let directory = originalURL.deletingLastPathComponent()
        let pathExtension = originalURL.pathExtension

        for _ in 0..<Self.maximumTemporaryNameAttempts {
            let identifier = temporaryIdentifierProvider()
            let baseName = ".audio-toolbox-\(identifier)"
            let fileName = pathExtension.isEmpty ? baseName : "\(baseName).\(pathExtension)"
            let candidate = directory.appendingPathComponent(fileName, isDirectory: false)

            guard !fileManager.fileExists(atPath: candidate.path) else {
                continue
            }

            do {
                try fileOperations.copyItem(originalURL, candidate)
                return candidate
            } catch where isFileExistsError(error) {
                continue
            } catch {
                removeTemporaryItemIfPresent(at: candidate)
                throw error
            }
        }

        throw SafeMetadataWriterError.unableToReserveTemporaryName
    }

    private func verificationFailureMessage(
        metadata: AudioMetadata,
        patch: MetadataPatch
    ) -> String? {
        if let expectedArtist = patch.artist,
           metadata.artists.first != expectedArtist
        {
            return "写入后验证失败：作者标签不匹配"
        }
        if let expectedAlbum = patch.album,
           metadata.albums.first != expectedAlbum
        {
            return "写入后验证失败：专辑标签不匹配"
        }
        return nil
    }

    private func removeTemporaryItemIfPresent(at url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
    }

    private func result(
        for url: URL,
        status: BatchFileStatus,
        message: String?
    ) -> BatchFileResult {
        BatchFileResult(url: url, status: status, message: message)
    }

    private func isFileExistsError(_ error: Error) -> Bool {
        let cocoaError = error as NSError
        return cocoaError.domain == NSCocoaErrorDomain
            && cocoaError.code == CocoaError.fileWriteFileExists.rawValue
    }

    private func errorMessage(_ error: Error) -> String {
        switch error {
        case let MetadataServiceError.unreadable(message),
             let MetadataServiceError.unsupported(message),
             let MetadataServiceError.notWritable(message),
             let MetadataServiceError.saveFailed(message),
             let MetadataServiceError.verificationFailed(message):
            return message
        case SafeMetadataWriterError.unableToReserveTemporaryName:
            return "无法生成不冲突的临时文件名"
        default:
            return error.localizedDescription
        }
    }
}

private struct OriginalFileSnapshot: Equatable {
    let systemNumber: UInt64?
    let systemFileNumber: UInt64?
    let fileSize: UInt64?
    let modificationDate: Date?
    let posixPermissions: UInt16?
}

private enum SafeMetadataWriterError: Error {
    case unableToReserveTemporaryName
}
