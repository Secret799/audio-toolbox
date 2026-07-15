import Foundation

public protocol SafeMetadataWriting: Sendable {
    func apply(to url: URL, patch: MetadataPatch) async -> BatchFileResult
}

public actor SafeMetadataWriter: SafeMetadataWriting {
    private static let maximumTemporaryNameAttempts = 16

    private let metadataService: any MetadataService
    private let fileOperations: SafeMetadataFileOperations
    private let commitGate: @Sendable () -> Bool
    private let temporaryIdentifierProvider: @Sendable () -> String

    public init(
        metadataService: any MetadataService,
        fileManager: FileManager = .default
    ) {
        self.metadataService = metadataService
        fileOperations = .live(fileManager: fileManager)
        commitGate = { !Task.isCancelled }
        temporaryIdentifierProvider = { UUID().uuidString }
    }

    init(
        metadataService: any MetadataService,
        fileOperations: SafeMetadataFileOperations,
        commitGate: @escaping @Sendable () -> Bool,
        temporaryIdentifierProvider: @escaping @Sendable () -> String
    ) {
        self.metadataService = metadataService
        self.fileOperations = fileOperations
        self.commitGate = commitGate
        self.temporaryIdentifierProvider = temporaryIdentifierProvider
    }

    public func apply(to url: URL, patch: MetadataPatch) async -> BatchFileResult {
        guard !Task.isCancelled else {
            return result(for: url, status: .notProcessed, message: "操作已取消")
        }
        guard patch.artist != nil || patch.album != nil else {
            return result(for: url, status: .failed, message: "没有需要写入的标签")
        }

        let originalSnapshot: OriginalFileSnapshot
        do {
            originalSnapshot = try initialSnapshot(for: url)
        } catch {
            return result(
                for: url,
                status: .failed,
                message: initialFailureMessage(error)
            )
        }

        let canWrite = await metadataService.canWrite(url: url)
        guard !Task.isCancelled else {
            return result(for: url, status: .notProcessed, message: "操作已取消")
        }
        guard canWrite else {
            return result(for: url, status: .failed, message: "文件格式不支持标签写入")
        }

        let temporary: OwnedTemporaryFile
        do {
            temporary = try createTemporaryCopy(of: url)
        } catch let error as TemporaryCreationError {
            return result(for: url, status: .failed, message: error.message)
        } catch {
            return result(
                for: url,
                status: .failed,
                message: "无法创建安全工作副本：\(copyFailureDetail(error))"
            )
        }

        guard !Task.isCancelled else {
            return preCommitResult(
                for: url,
                status: .notProcessed,
                message: "操作已取消",
                temporary: temporary
            )
        }

        let preWriteState: SafeMetadataFileNodeState
        do {
            preWriteState = try fileOperations.nodeState(temporary.url)
        } catch {
            return preCommitResult(
                for: url,
                status: .failed,
                message: "工作副本身份发生变化，已拒绝写入",
                temporary: temporary
            )
        }
        guard preWriteState.identity == temporary.identity,
              preWriteState.isRegularFile,
              preWriteState.linkCount == 1
        else {
            return preCommitResult(
                for: url,
                status: .failed,
                message: "工作副本身份发生变化，已拒绝写入",
                temporary: temporary
            )
        }

        do {
            try await metadataService.write(url: temporary.url, patch: patch)
        } catch is CancellationError where Task.isCancelled {
            return preCommitResult(
                for: url,
                status: .notProcessed,
                message: "操作已取消",
                temporary: temporary
            )
        } catch {
            return preCommitResult(
                for: url,
                status: .failed,
                message: "元数据写入失败",
                temporary: temporary
            )
        }

        let editedState: SafeMetadataFileNodeState
        do {
            editedState = try fileOperations.nodeState(temporary.url)
        } catch {
            return preCommitResult(
                for: url,
                status: .failed,
                message: "工作副本身份发生变化，已拒绝提交",
                temporary: temporary
            )
        }
        guard editedState.identity == preWriteState.identity,
              editedState.identity == temporary.identity,
              editedState.isRegularFile,
              editedState.linkCount == 1
        else {
            return preCommitResult(
                for: url,
                status: .failed,
                message: "工作副本身份发生变化，已拒绝提交",
                temporary: temporary
            )
        }

        guard !Task.isCancelled else {
            return preCommitResult(
                for: url,
                status: .notProcessed,
                message: "操作已取消",
                temporary: temporary
            )
        }

        let savedMetadata: AudioMetadata
        do {
            savedMetadata = try await metadataService.read(url: temporary.url)
        } catch is CancellationError where Task.isCancelled {
            return preCommitResult(
                for: url,
                status: .notProcessed,
                message: "操作已取消",
                temporary: temporary
            )
        } catch {
            return preCommitResult(
                for: url,
                status: .failed,
                message: "写入后验证失败：无法读取工作副本",
                temporary: temporary
            )
        }

        if let verificationMessage = verificationFailureMessage(
            metadata: savedMetadata,
            patch: patch
        ) {
            return preCommitResult(
                for: url,
                status: .failed,
                message: verificationMessage,
                temporary: temporary
            )
        }

        guard !Task.isCancelled else {
            return preCommitResult(
                for: url,
                status: .notProcessed,
                message: "操作已取消",
                temporary: temporary
            )
        }

        do {
            let currentTemporaryState = try fileOperations.nodeState(temporary.url)
            guard currentTemporaryState.identity == temporary.identity else {
                return preCommitResult(
                    for: url,
                    status: .failed,
                    message: "工作副本身份发生变化，已拒绝提交",
                    temporary: temporary
                )
            }
        } catch {
            return preCommitResult(
                for: url,
                status: .failed,
                message: "工作副本身份发生变化，已拒绝提交",
                temporary: temporary
            )
        }

        let coordinatedResult: CoordinatedCommitResult
        do {
            coordinatedResult = try coordinatedCommit(
                originalURL: url,
                originalSnapshot: originalSnapshot,
                temporary: temporary
            )
        } catch let failure as CoordinatedCommitFailure {
            let message: String
            if let validationError = failure.cause as? CommitValidationError {
                message = validationError.message
            } else {
                message = swapFailureMessage(failure.cause)
            }
            return preCommitResult(
                for: url,
                status: .failed,
                message: message,
                temporary: failure.temporary
            )
        } catch {
            return preCommitResult(
                for: url,
                status: .failed,
                message: swapFailureMessage(error),
                temporary: temporary
            )
        }

        switch coordinatedResult.outcome {
        case .cancelled:
            return preCommitResult(
                for: url,
                status: .notProcessed,
                message: "操作已取消",
                temporary: coordinatedResult.temporary
            )
        case let .swapped(warning):
            return result(for: url, status: .succeeded, message: warning)
        }
    }

    private func initialSnapshot(for url: URL) throws -> OriginalFileSnapshot {
        let before = try fileOperations.nodeState(url)
        if before.isSymbolicLink {
            throw InitialValidationError.symbolicLink
        }
        guard before.isRegularFile else {
            throw InitialValidationError.notRegularFile
        }
        guard before.linkCount == 1 else {
            throw InitialValidationError.hardLinked
        }
        guard fileOperations.isReadable(url) else {
            throw InitialValidationError.notReadable
        }
        guard fileOperations.isWritable(url) else {
            throw InitialValidationError.notWritable
        }

        let digest = try fileOperations.digest(url)
        let after = try fileOperations.nodeState(url)
        guard before == after else {
            throw InitialValidationError.changedDuringInspection
        }
        return OriginalFileSnapshot(nodeState: after, digest: digest)
    }

    private func createTemporaryCopy(of originalURL: URL) throws -> OwnedTemporaryFile {
        let directory = originalURL.deletingLastPathComponent()
        let pathExtension = originalURL.pathExtension

        for _ in 0..<Self.maximumTemporaryNameAttempts {
            let identifier = temporaryIdentifierProvider()
            let baseName = ".audio-toolbox-\(identifier)"
            let fileName = pathExtension.isEmpty ? baseName : "\(baseName).\(pathExtension)"
            let candidate = directory.appendingPathComponent(fileName, isDirectory: false)

            do {
                let copiedState = try fileOperations.copyExclusive(originalURL, candidate)
                guard copiedState.isRegularFile,
                      copiedState.linkCount == 1
                else {
                    let temporary = OwnedTemporaryFile(
                        url: candidate,
                        identity: copiedState.identity
                    )
                    let cleanup = cleanupOwnedTemporaryFile(temporary)
                    throw TemporaryCreationError(
                        message: appendCleanupMessage(
                            "无法创建安全工作副本：副本类型不安全",
                            cleanup
                        )
                    )
                }
                return OwnedTemporaryFile(url: candidate, identity: copiedState.identity)
            } catch let error as SafeMetadataFileSystemError where error.code == EEXIST {
                continue
            } catch let error as TemporaryCreationError {
                throw error
            } catch let error as SafeMetadataFileSystemError {
                let cleanup: CleanupOutcome
                if let ownedState = error.ownedNodeState {
                    cleanup = cleanupOwnedTemporaryFile(
                        OwnedTemporaryFile(url: candidate, identity: ownedState.identity)
                    )
                } else {
                    cleanup = cleanupCandidateWithoutOwnership(at: candidate)
                }
                throw TemporaryCreationError(
                    message: appendCleanupMessage(
                        "无法创建安全工作副本：\(copyFailureDetail(error))",
                        cleanup
                    )
                )
            } catch {
                throw TemporaryCreationError(
                    message: "无法创建安全工作副本：文件复制失败"
                )
            }
        }

        throw TemporaryCreationError(message: "无法创建安全工作副本：临时文件名持续冲突")
    }

    private func coordinatedCommit(
        originalURL: URL,
        originalSnapshot: OriginalFileSnapshot,
        temporary: OwnedTemporaryFile
    ) throws -> CoordinatedCommitResult {
        var coordinatedTemporary = temporary
        var outcome: CommitOutcome?
        do {
            try fileOperations.coordinateReplacing(
                originalURL,
                temporary.url
            ) { coordinatedOriginal, coordinatedTemporaryURL in
                coordinatedTemporary = OwnedTemporaryFile(
                    url: coordinatedTemporaryURL,
                    identity: temporary.identity
                )
                outcome = try commitInsideCoordination(
                    originalURL: coordinatedOriginal,
                    originalSnapshot: originalSnapshot,
                    temporary: coordinatedTemporary
                )
            }
        } catch {
            throw CoordinatedCommitFailure(
                cause: error,
                temporary: coordinatedTemporary
            )
        }
        guard let outcome else {
            throw CoordinatedCommitFailure(
                cause: CommitValidationError(message: "无法进入原文件替换协调区"),
                temporary: coordinatedTemporary
            )
        }
        return CoordinatedCommitResult(
            outcome: outcome,
            temporary: coordinatedTemporary
        )
    }

    private func commitInsideCoordination(
        originalURL: URL,
        originalSnapshot: OriginalFileSnapshot,
        temporary: OwnedTemporaryFile
    ) throws -> CommitOutcome {
        let before = try fileOperations.nodeState(originalURL)
        guard before == originalSnapshot.nodeState else {
            throw CommitValidationError(message: "原文件在编辑期间发生变化，已取消替换")
        }
        let digest = try fileOperations.digest(originalURL)
        let after = try fileOperations.nodeState(originalURL)
        guard before == after,
              after == originalSnapshot.nodeState
        else {
            throw CommitValidationError(message: "原文件在编辑期间发生变化，已取消替换")
        }
        guard digest == originalSnapshot.digest else {
            throw CommitValidationError(message: "原文件内容已发生变化，已取消替换")
        }

        let temporaryState = try fileOperations.nodeState(temporary.url)
        guard temporaryState.identity == temporary.identity,
              temporaryState.isRegularFile,
              temporaryState.linkCount == 1
        else {
            throw CommitValidationError(message: "工作副本身份发生变化，已拒绝提交")
        }

        guard commitGate() else {
            return .cancelled
        }

        try fileOperations.swap(originalURL, temporary.url)
        return postSwapOutcome(
            originalURL: originalURL,
            originalIdentity: originalSnapshot.nodeState.identity,
            editedIdentity: temporary.identity,
            recoveryURL: temporary.url
        )
    }

    private func postSwapOutcome(
        originalURL: URL,
        originalIdentity: SafeMetadataFileIdentity,
        editedIdentity: SafeMetadataFileIdentity,
        recoveryURL: URL
    ) -> CommitOutcome {
        let warning = "修改已提交，但隐藏恢复副本 \(recoveryURL.lastPathComponent) 已保留，请确认文件后手动处理"
        do {
            let committedState = try fileOperations.nodeState(originalURL)
            let recoveryState = try fileOperations.nodeState(recoveryURL)
            guard committedState.identity == editedIdentity,
                  committedState.isRegularFile,
                  recoveryState.identity == originalIdentity,
                  recoveryState.isRegularFile,
                  recoveryState.linkCount == 1
            else {
                return .swapped(warning: warning)
            }
            do {
                try fileOperations.unlink(recoveryURL)
                return .swapped(warning: nil)
            } catch {
                return .swapped(
                    warning: "修改已提交，但旧文件恢复副本 \(recoveryURL.lastPathComponent) 未能清理（\(cleanupFailureDetail(error))），已保留供恢复"
                )
            }
        } catch {
            return .swapped(warning: warning)
        }
    }

    private func preCommitResult(
        for url: URL,
        status: BatchFileStatus,
        message: String,
        temporary: OwnedTemporaryFile
    ) -> BatchFileResult {
        let cleanup = cleanupOwnedTemporaryFile(temporary)
        return result(
            for: url,
            status: status,
            message: appendCleanupMessage(message, cleanup)
        )
    }

    private func cleanupCandidateWithoutOwnership(at url: URL) -> CleanupOutcome {
        do {
            _ = try fileOperations.nodeState(url)
            return .ownershipUnknown
        } catch let error as SafeMetadataFileSystemError where error.code == ENOENT {
            return .notNeeded
        } catch {
            return .failed("无法确认临时路径状态")
        }
    }

    private func cleanupOwnedTemporaryFile(
        _ temporary: OwnedTemporaryFile
    ) -> CleanupOutcome {
        let state: SafeMetadataFileNodeState
        do {
            state = try fileOperations.nodeState(temporary.url)
        } catch let error as SafeMetadataFileSystemError where error.code == ENOENT {
            return .notNeeded
        } catch {
            return .failed("无法确认临时文件身份")
        }

        guard state.identity == temporary.identity else {
            return .identityMismatch
        }
        do {
            try fileOperations.unlink(temporary.url)
            return .removed
        } catch {
            return .failed(cleanupFailureDetail(error))
        }
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

    private func appendCleanupMessage(
        _ message: String,
        _ cleanup: CleanupOutcome
    ) -> String {
        switch cleanup {
        case .removed, .notNeeded:
            return message
        case .identityMismatch:
            return "\(message)；临时路径已被其他文件占用，为避免误删未删除该隐藏文件"
        case .ownershipUnknown:
            return "\(message)；临时路径存在但无法确认所有权，为避免误删未删除该隐藏文件"
        case let .failed(detail):
            return "\(message)；临时工作文件清理失败：\(detail)，隐藏文件已保留"
        }
    }

    private func cleanupFailureDetail(_ error: Error) -> String {
        guard let error = error as? SafeMetadataFileSystemError else {
            return "文件系统拒绝删除"
        }
        switch error.code {
        case EACCES, EPERM:
            return "没有删除权限"
        case EBUSY:
            return "文件正被占用"
        case EROFS:
            return "所在文件系统为只读"
        default:
            return "删除操作失败"
        }
    }

    private func initialFailureMessage(_ error: Error) -> String {
        if let error = error as? InitialValidationError {
            switch error {
            case .symbolicLink:
                return "拒绝编辑符号链接"
            case .notRegularFile:
                return "目标不是普通文件"
            case .hardLinked:
                return "文件存在硬链接别名，为避免路径分叉已拒绝编辑"
            case .notReadable:
                return "文件不可读"
            case .notWritable:
                return "文件不可写"
            case .changedDuringInspection:
                return "文件在安全检查期间发生变化"
            }
        }
        if let error = error as? SafeMetadataFileSystemError {
            switch error.code {
            case ENOENT:
                return "文件不存在"
            case EACCES, EPERM:
                return "没有权限检查或读取文件"
            case ELOOP:
                return "拒绝编辑符号链接"
            default:
                return "无法完成文件安全检查"
            }
        }
        return "无法完成文件安全检查"
    }

    private func copyFailureDetail(_ error: Error) -> String {
        guard let error = error as? SafeMetadataFileSystemError else {
            return "文件复制失败"
        }
        switch error.code {
        case ENOSPC, EDQUOT:
            return "磁盘空间不足"
        case EACCES, EPERM:
            return "没有创建副本的权限"
        case ELOOP:
            return "源文件或目标路径包含符号链接"
        case EXDEV:
            return "无法在同一文件系统中创建副本"
        default:
            return "文件复制失败"
        }
    }

    private func swapFailureMessage(_ error: Error) -> String {
        if error is SafeMetadataCoordinationError {
            return "无法协调原文件替换"
        }
        guard let error = error as? SafeMetadataFileSystemError else {
            return "无法原子提交修改"
        }
        switch error.code {
        case EACCES, EPERM:
            return "无法原子提交修改：没有替换权限"
        case EXDEV:
            return "无法原子提交修改：工作副本与原文件不在同一卷"
        case ENOSPC, EDQUOT:
            return "无法原子提交修改：磁盘空间不足"
        case EBUSY:
            return "无法原子提交修改：文件正被占用"
        default:
            return "无法原子提交修改"
        }
    }

    private func result(
        for url: URL,
        status: BatchFileStatus,
        message: String?
    ) -> BatchFileResult {
        BatchFileResult(url: url, status: status, message: message)
    }
}

private struct OriginalFileSnapshot: Sendable {
    let nodeState: SafeMetadataFileNodeState
    let digest: Data
}

private struct OwnedTemporaryFile: Sendable {
    let url: URL
    let identity: SafeMetadataFileIdentity
}

private enum CleanupOutcome {
    case removed
    case notNeeded
    case identityMismatch
    case ownershipUnknown
    case failed(String)
}

private struct CoordinatedCommitResult {
    let outcome: CommitOutcome
    let temporary: OwnedTemporaryFile
}

private struct CoordinatedCommitFailure: Error {
    let cause: Error
    let temporary: OwnedTemporaryFile
}

private enum CommitOutcome {
    case cancelled
    case swapped(warning: String?)
}

private struct CommitValidationError: Error {
    let message: String
}

private struct TemporaryCreationError: Error {
    let message: String
}

private enum InitialValidationError: Error {
    case symbolicLink
    case notRegularFile
    case hardLinked
    case notReadable
    case notWritable
    case changedDuringInspection
}
