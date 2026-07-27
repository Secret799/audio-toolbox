import Foundation

public protocol SafeMetadataWriting: Sendable {
    func apply(to target: BatchEditTarget, patch: MetadataPatch) async -> BatchFileResult
}

public actor SafeMetadataWriter: SafeMetadataWriting {
    private static let maximumWorkspaceNameAttempts = 16
    private static let changedFileMessage = "文件已变化，请重新扫描确认"

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
        commitGate = { true }
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

    public func apply(to target: BatchEditTarget, patch: MetadataPatch) async -> BatchFileResult {
        let cancellationFlag: SafeMetadataCancellationFlag
        do {
            cancellationFlag = try SafeMetadataCancellationFlag()
        } catch {
            return result(for: target.url, status: .failed, message: "无法初始化安全写入状态")
        }

        return await withTaskCancellationHandler {
            await applyInternal(to: target, patch: patch, cancellationFlag: cancellationFlag)
        } onCancel: {
            cancellationFlag.cancel()
        }
    }

    func apply(to url: URL, patch: MetadataPatch) async -> BatchFileResult {
        do {
            let fingerprint = try StableFileIdentityResolver.fingerprint(for: url)
            return await apply(
                to: BatchEditTarget(
                    url: url,
                    fileIdentity: fingerprint.fileIdentity,
                    fileSize: fingerprint.fileSize,
                    modificationDate: fingerprint.modificationDate
                ),
                patch: patch
            )
        } catch {
            return result(for: url, status: .failed, message: "无法完成文件安全检查")
        }
    }

    private func applyInternal(
        to target: BatchEditTarget,
        patch: MetadataPatch,
        cancellationFlag: SafeMetadataCancellationFlag
    ) async -> BatchFileResult {
        let url = target.url
        guard !cancellationFlag.isCancelled else {
            return result(for: url, status: .notProcessed, message: "操作已取消")
        }
        guard patch.artist != nil || patch.album != nil || patch.composer != nil else {
            return result(for: url, status: .failed, message: "没有需要写入的标签")
        }

        let operations = fileOperations
        let initialSnapshot: SafeMetadataFileSnapshot
        do {
            initialSnapshot = try await Self.runBlocking {
                try operations.snapshotURL(url, cancellationFlag)
            }
            try validateInitialSnapshot(
                initialSnapshot,
                url: url,
                operations: operations
            )
        } catch is CancellationError {
            return result(for: url, status: .notProcessed, message: "操作已取消")
        } catch {
            return result(
                for: url,
                status: .failed,
                message: initialFailureMessage(error)
            )
        }

        do {
            let fingerprint = try await Self.runBlocking {
                try StableFileIdentityResolver.fingerprint(for: url)
            }
            guard target.matches(fingerprint) else {
                return result(
                    for: url,
                    status: .failed,
                    message: Self.changedFileMessage
                )
            }
        } catch is CancellationError {
            return result(for: url, status: .notProcessed, message: "操作已取消")
        } catch {
            return result(
                for: url,
                status: .failed,
                message: Self.changedFileMessage
            )
        }

        let canWrite = await metadataService.canWrite(url: url)
        guard !cancellationFlag.isCancelled else {
            return result(for: url, status: .notProcessed, message: "操作已取消")
        }
        guard canWrite else {
            return result(for: url, status: .failed, message: "文件格式不支持标签写入")
        }

        let initialOwnedWork: OwnedWorkFile
        do {
            initialOwnedWork = try await createOwnedWorkFile(
                originalURL: url,
                initialSnapshot: initialSnapshot,
                cancellationFlag: cancellationFlag
            )
        } catch let error as WorkspaceCancellationError {
            return result(
                for: url,
                status: .notProcessed,
                message: error.message,
                recoveryURL: error.recoveryURL
            )
        } catch is CancellationError {
            return result(for: url, status: .notProcessed, message: "操作已取消")
        } catch let error as WorkspaceCreationError {
            return result(
                for: url,
                status: .failed,
                message: error.message,
                recoveryURL: error.recoveryURL
            )
        } catch {
            return result(for: url, status: .failed, message: copyFailureMessage(error))
        }

        guard !cancellationFlag.isCancelled else {
            return await finishBeforeCommit(
                url: url,
                status: .notProcessed,
                message: "操作已取消",
                ownedWork: initialOwnedWork
            )
        }

        let workspace = initialOwnedWork.workspace
        let initialWorkIdentity = initialOwnedWork.identity
        do {
            try await Self.runBlocking {
                try operations.validateWorkspacePath(
                    workspace,
                    initialWorkIdentity
                )
            }
        } catch {
            return await finishBeforeCommit(
                url: url,
                status: .failed,
                message: "私有工作区路径身份发生变化，已拒绝写入",
                ownedWork: initialOwnedWork
            )
        }

        guard !cancellationFlag.isCancelled else {
            return await finishBeforeCommit(
                url: url,
                status: .notProcessed,
                message: "操作已取消",
                ownedWork: initialOwnedWork
            )
        }

        do {
            try await metadataService.write(url: workspace.fileURL, patch: patch)
        } catch is CancellationError where cancellationFlag.isCancelled {
            return await finishBeforeCommit(
                url: url,
                status: .notProcessed,
                message: "操作已取消",
                ownedWork: initialOwnedWork
            )
        } catch {
            return await finishBeforeCommit(
                url: url,
                status: .failed,
                message: "元数据写入失败",
                ownedWork: initialOwnedWork
            )
        }

        let writtenSnapshot: SafeMetadataFileSnapshot
        do {
            writtenSnapshot = try await Self.runBlocking {
                let snapshot = try operations.snapshotWorkspace(
                    workspace,
                    cancellationFlag
                )
                if workspace.supportsStableFileIdentity,
                   snapshot.nodeState.identity != initialWorkIdentity
                {
                    throw WorkValidationError.identityChanged
                }
                try operations.validateWorkspacePath(
                    workspace,
                    snapshot.nodeState.identity
                )
                return snapshot
            }
        } catch is CancellationError {
            return await finishBeforeCommit(
                url: url,
                status: .notProcessed,
                message: "操作已取消",
                ownedWork: initialOwnedWork
            )
        } catch {
            return await finishBeforeCommit(
                url: url,
                status: .failed,
                message: "工作副本身份发生变化，已拒绝提交",
                ownedWork: initialOwnedWork
            )
        }

        let ownedWork = OwnedWorkFile(
            workspace: workspace,
            identity: writtenSnapshot.nodeState.identity,
            copiedExpected: initialOwnedWork.copiedExpected
        )
        guard writtenSnapshot.nodeState.isRegularFile,
              writtenSnapshot.nodeState.linkCount == 1
        else {
            return await finishBeforeCommit(
                url: url,
                status: .failed,
                message: "工作副本身份发生变化，已拒绝提交",
                ownedWork: ownedWork
            )
        }
        guard writtenSnapshot.preservesFileSystemMetadata(
            of: initialOwnedWork.copiedExpected
        ) else {
            return await finishBeforeCommit(
                url: url,
                status: .failed,
                message: "元数据服务改变了必须保留的文件系统属性，已拒绝提交",
                ownedWork: ownedWork
            )
        }

        do {
            try await Self.runBlocking {
                try operations.validateWorkspacePath(
                    ownedWork.workspace,
                    ownedWork.identity
                )
            }
        } catch {
            return await finishBeforeCommit(
                url: url,
                status: .failed,
                message: "私有工作区路径身份发生变化，已拒绝验证",
                ownedWork: ownedWork
            )
        }

        guard !cancellationFlag.isCancelled else {
            return await finishBeforeCommit(
                url: url,
                status: .notProcessed,
                message: "操作已取消",
                ownedWork: ownedWork
            )
        }

        let savedMetadata: AudioMetadata
        do {
            savedMetadata = try await metadataService.read(url: ownedWork.workspace.fileURL)
        } catch is CancellationError where cancellationFlag.isCancelled {
            return await finishBeforeCommit(
                url: url,
                status: .notProcessed,
                message: "操作已取消",
                ownedWork: ownedWork
            )
        } catch {
            return await finishBeforeCommit(
                url: url,
                status: .failed,
                message: "写入后验证失败：无法读取工作副本",
                ownedWork: ownedWork
            )
        }

        if let verificationMessage = verificationFailureMessage(
            metadata: savedMetadata,
            patch: patch
        ) {
            return await finishBeforeCommit(
                url: url,
                status: .failed,
                message: verificationMessage,
                ownedWork: ownedWork
            )
        }

        let editedExpected: SafeMetadataFileSnapshot
        do {
            editedExpected = try await Self.runBlocking {
                try operations.validateWorkspacePath(
                    ownedWork.workspace,
                    ownedWork.identity
                )
                return try operations.snapshotWorkspace(
                    ownedWork.workspace,
                    cancellationFlag
                )
            }
            guard editedExpected == writtenSnapshot else {
                throw WorkValidationError.changedAfterVerification
            }
        } catch is CancellationError {
            return await finishBeforeCommit(
                url: url,
                status: .notProcessed,
                message: "操作已取消",
                ownedWork: ownedWork
            )
        } catch {
            return await finishBeforeCommit(
                url: url,
                status: .failed,
                message: "已验证工作副本在读取期间发生变化，已拒绝提交",
                ownedWork: ownedWork
            )
        }

        guard !cancellationFlag.isCancelled else {
            return await finishBeforeCommit(
                url: url,
                status: .notProcessed,
                message: "操作已取消",
                ownedWork: ownedWork
            )
        }

        let gate = commitGate
        let commitResult: CommitExecutionResult
        do {
            commitResult = try await Self.runBlocking {
                try Self.executeCommit(
                    target: target,
                    originalURL: url,
                    initialSnapshot: initialSnapshot,
                    editedExpected: editedExpected,
                    ownedWork: ownedWork,
                    operations: operations,
                    cancellationFlag: cancellationFlag,
                    commitGate: gate
                )
            }
        } catch is CancellationError {
            return await finishBeforeCommit(
                url: url,
                status: .notProcessed,
                message: "操作已取消",
                ownedWork: ownedWork
            )
        } catch {
            return await finishBeforeCommit(
                url: url,
                status: .failed,
                message: Self.commitFailureMessage(error),
                ownedWork: ownedWork
            )
        }

        switch commitResult.disposition {
        case let .committed(coordinatorTailWarning):
            let cleanup = await cleanupWorkspace(
                ownedWork.workspace,
                expectedFileIdentity: commitResult.cleanupIdentity
            )
            var messages: [String] = []
            if coordinatorTailWarning {
                messages.append("修改已提交，但文件协调收尾异常")
            }
            if let warning = cleanup.warning {
                messages.append(warning)
            }
            return result(
                for: url,
                status: .succeeded,
                message: messages.isEmpty ? nil : messages.joined(separator: "；"),
                recoveryURL: cleanup.recoveryURL
            )

        case let .rolledBack(coordinatorTailWarning):
            let cleanup = await cleanupWorkspace(
                ownedWork.workspace,
                expectedFileIdentity: commitResult.cleanupIdentity
            )
            var message = "提交后检测到并发修改或耐久同步失败，已安全回滚"
            if coordinatorTailWarning {
                message += "；文件协调收尾异常"
            }
            if let warning = cleanup.warning {
                message += "；\(warning)"
            }
            return result(
                for: url,
                status: .failed,
                message: message,
                recoveryURL: cleanup.recoveryURL
            )

        case let .cancelled(coordinatorTailWarning):
            let cleanup = await cleanupWorkspace(
                ownedWork.workspace,
                expectedFileIdentity: editedExpected.nodeState.identity
            )
            var message = "操作已取消"
            if coordinatorTailWarning {
                message += "；文件协调收尾异常"
            }
            if let warning = cleanup.warning {
                message += "；\(warning)"
            }
            return result(
                for: url,
                status: .notProcessed,
                message: message,
                recoveryURL: cleanup.recoveryURL
            )

        case let .preSwapFailed(message, coordinatorTailWarning):
            let cleanup = await cleanupWorkspace(
                ownedWork.workspace,
                expectedFileIdentity: editedExpected.nodeState.identity
            )
            var finalMessage = message
            if coordinatorTailWarning {
                finalMessage += "；文件协调收尾异常"
            }
            if let warning = cleanup.warning {
                finalMessage += "；\(warning)"
            }
            return result(
                for: url,
                status: .failed,
                message: finalMessage,
                recoveryURL: cleanup.recoveryURL
            )

        case let .uncertain(message, recoveryURL):
            ownedWork.workspace.closeDescriptors()
            return result(
                for: url,
                status: .failed,
                message: "\(message)；提交状态不确定，恢复文件路径：\(recoveryURL.path)",
                recoveryURL: recoveryURL
            )
        }
    }

    private func validateInitialSnapshot(
        _ snapshot: SafeMetadataFileSnapshot,
        url: URL,
        operations: SafeMetadataFileOperations
    ) throws {
        if snapshot.nodeState.isSymbolicLink {
            throw InitialValidationError.symbolicLink
        }
        guard snapshot.nodeState.isRegularFile else {
            throw InitialValidationError.notRegularFile
        }
        guard snapshot.nodeState.linkCount == 1 else {
            throw InitialValidationError.hardLinked
        }
        guard snapshot.nodeState.mode & UInt16(S_ISUID | S_ISGID) == 0 else {
            throw InitialValidationError.privilegedMode
        }
        guard operations.isReadable(url) else {
            throw InitialValidationError.notReadable
        }
        guard operations.isWritable(url) else {
            throw InitialValidationError.notWritable
        }
    }

    private func createOwnedWorkFile(
        originalURL: URL,
        initialSnapshot: SafeMetadataFileSnapshot,
        cancellationFlag: SafeMetadataCancellationFlag
    ) async throws -> OwnedWorkFile {
        let operations = fileOperations
        for _ in 0..<Self.maximumWorkspaceNameAttempts {
            if cancellationFlag.isCancelled { throw CancellationError() }
            let identifier = temporaryIdentifierProvider()
            let workspace: SafeMetadataWorkspace
            do {
                workspace = try await Self.runBlocking {
                    try operations.createWorkspace(originalURL, identifier)
                }
            } catch let error as SafeMetadataFileSystemError where error.code == EEXIST {
                continue
            } catch let error as SafeMetadataWorkspaceSetupError {
                throw WorkspaceCreationError(
                    message: "无法完成私有工作目录初始化；为避免误删已保守保留：\(error.preservedURL.path)",
                    recoveryURL: error.preservedURL
                )
            }

            var copiedIdentity: SafeMetadataFileIdentity?
            do {
                let copiedState = try await Self.runBlocking {
                    try operations.copyIntoWorkspace(
                        originalURL,
                        workspace,
                        cancellationFlag
                    )
                }
                copiedIdentity = copiedState.identity
                guard copiedState.isRegularFile,
                      copiedState.linkCount == 1
                else {
                    let cleanup = await cleanupWorkspace(
                        workspace,
                        expectedFileIdentity: copiedState.identity
                    )
                    throw WorkspaceCreationError(
                        message: appendCleanupWarning(
                            "无法创建安全工作副本：副本类型不安全",
                            cleanup.warning
                        ),
                        recoveryURL: cleanup.recoveryURL
                    )
                }
                let copiedExpected = try await Self.runBlocking {
                    try operations.snapshotWorkspace(
                        workspace,
                        cancellationFlag
                    )
                }
                guard copiedExpected.nodeState.identity == copiedState.identity else {
                    throw WorkValidationError.identityChanged
                }
                guard copiedExpected.isEquivalentTransactionInput(
                    to: initialSnapshot
                ) else {
                    throw WorkValidationError.copiedInputMismatch
                }
                return OwnedWorkFile(
                    workspace: workspace,
                    identity: copiedState.identity,
                    copiedExpected: copiedExpected
                )
            } catch is CancellationError {
                let cleanup = await cleanupWorkspace(
                    workspace,
                    expectedFileIdentity: copiedIdentity
                )
                throw WorkspaceCancellationError(
                    message: appendCleanupWarning("操作已取消", cleanup.warning),
                    recoveryURL: cleanup.recoveryURL
                )
            } catch WorkValidationError.copiedInputMismatch {
                let cleanup = await cleanupWorkspace(
                    workspace,
                    expectedFileIdentity: copiedIdentity
                )
                throw WorkspaceCreationError(
                    message: appendCleanupWarning(
                        "复制后的文件属性或内容不完整，已拒绝编辑",
                        cleanup.warning
                    ),
                    recoveryURL: cleanup.recoveryURL
                )
            } catch let error as SafeMetadataFileSystemError {
                let cleanup = await cleanupWorkspace(
                    workspace,
                    expectedFileIdentity: error.ownedNodeState?.identity ?? copiedIdentity
                )
                if error.code == ECANCELED || cancellationFlag.isCancelled {
                    throw WorkspaceCancellationError(
                        message: appendCleanupWarning("操作已取消", cleanup.warning),
                        recoveryURL: cleanup.recoveryURL
                    )
                }
                throw WorkspaceCreationError(
                    message: appendCleanupWarning(
                        copyFailureMessage(error),
                        cleanup.warning
                    ),
                    recoveryURL: cleanup.recoveryURL
                )
            } catch let error as WorkspaceCreationError {
                throw error
            } catch {
                let cleanup = await cleanupWorkspace(
                    workspace,
                    expectedFileIdentity: copiedIdentity
                )
                throw WorkspaceCreationError(
                    message: appendCleanupWarning(
                        "无法创建安全工作副本：文件复制失败",
                        cleanup.warning
                    ),
                    recoveryURL: cleanup.recoveryURL
                )
            }
        }
        throw WorkspaceCreationError(message: "无法创建安全工作副本：私有工作目录名持续冲突")
    }

    private func finishBeforeCommit(
        url: URL,
        status: BatchFileStatus,
        message: String,
        ownedWork: OwnedWorkFile
    ) async -> BatchFileResult {
        let cleanup = await cleanupWorkspace(
            ownedWork.workspace,
            expectedFileIdentity: ownedWork.identity
        )
        return result(
            for: url,
            status: status,
            message: appendCleanupWarning(message, cleanup.warning),
            recoveryURL: cleanup.recoveryURL
        )
    }

    private func cleanupWorkspace(
        _ workspace: SafeMetadataWorkspace,
        expectedFileIdentity: SafeMetadataFileIdentity?
    ) async -> WorkspaceCleanupReport {
        let operations = fileOperations
        return await (try? Self.runBlocking {
            Self.cleanupWorkspaceSynchronously(
                workspace,
                expectedFileIdentity: expectedFileIdentity,
                operations: operations
            )
        }) ?? WorkspaceCleanupReport(
            warning: "私有工作区清理失败，已保守保留：\(workspace.directoryURL.path)",
            recoveryURL: workspace.directoryURL
        )
    }

    private nonisolated static func cleanupWorkspaceSynchronously(
        _ workspace: SafeMetadataWorkspace,
        expectedFileIdentity: SafeMetadataFileIdentity?,
        operations: SafeMetadataFileOperations
    ) -> WorkspaceCleanupReport {
        defer { workspace.closeDescriptors() }

        if let expectedFileIdentity {
            switch operations.removeWorkspaceFileIfOwned(workspace, expectedFileIdentity) {
            case .removed, .missing:
                break
            case let .identityMismatch(preservedURL):
                return WorkspaceCleanupReport(
                    warning: "私有工作文件身份已变化，为避免误删已保守保留：\(preservedURL.path)",
                    recoveryURL: preservedURL
                )
            case let .failed(error, preservedURL):
                let path = preservedURL ?? workspace.fileURL
                return WorkspaceCleanupReport(
                    warning: "私有工作文件未能清理（\(cleanupFailureDetail(error))），恢复文件路径：\(path.path)",
                    recoveryURL: path
                )
            }
        }

        switch operations.removeWorkspaceDirectoryIfOwned(workspace) {
        case .removed, .missing:
            return WorkspaceCleanupReport(warning: nil)
        case let .identityMismatch(preservedURL):
            return WorkspaceCleanupReport(
                warning: "私有工作目录路径身份已变化，为避免误删已保守保留：\(preservedURL.path)",
                recoveryURL: preservedURL
            )
        case let .failed(error, preservedURL):
            let path = preservedURL ?? workspace.directoryURL
            return WorkspaceCleanupReport(
                warning: "私有工作目录未能清理（\(cleanupFailureDetail(error))），已保留：\(path.path)",
                recoveryURL: path
            )
        }
    }

    private nonisolated static func executeCommit(
        target: BatchEditTarget,
        originalURL: URL,
        initialSnapshot: SafeMetadataFileSnapshot,
        editedExpected: SafeMetadataFileSnapshot,
        ownedWork: OwnedWorkFile,
        operations: SafeMetadataFileOperations,
        cancellationFlag: SafeMetadataCancellationFlag,
        commitGate: @Sendable () -> Bool
    ) throws -> CommitExecutionResult {
        let uncancellableFlag = try SafeMetadataCancellationFlag()
        var observed = ObservedCommitState.notStarted

        do {
            try operations.coordinateReplacing(
                originalURL,
                ownedWork.workspace.fileURL
            ) { coordinatedOriginal, coordinatedWork in
                let coordinatedFingerprint: StableFileFingerprint
                do {
                    coordinatedFingerprint = try StableFileIdentityResolver.fingerprint(
                        for: coordinatedOriginal
                    )
                } catch {
                    observed = .preSwapFailed(Self.changedFileMessage)
                    return
                }
                guard target.matches(coordinatedFingerprint) else {
                    observed = .preSwapFailed(Self.changedFileMessage)
                    return
                }

                let commitOriginal = try operations.snapshotURL(
                    coordinatedOriginal,
                    cancellationFlag
                )
                guard commitOriginal == initialSnapshot else {
                    observed = .preSwapFailed(Self.changedFileMessage)
                    return
                }

                try operations.validateWorkspacePath(
                    ownedWork.workspace,
                    editedExpected.nodeState.identity
                )
                let coordinatedWorkSnapshot = try operations.snapshotURL(
                    coordinatedWork,
                    cancellationFlag
                )
                guard coordinatedWorkSnapshot == editedExpected
                else {
                    observed = .preSwapFailed("已验证工作副本在提交前发生变化，已取消替换")
                    return
                }

                guard !cancellationFlag.isCancelled,
                      commitGate()
                else {
                    observed = .cancelled
                    return
                }

                do {
                    try operations.syncWorkspaceFile(
                        ownedWork.workspace,
                        editedExpected.nodeState.identity
                    )
                    try operations.syncWorkspaceDirectory(ownedWork.workspace)
                } catch {
                    observed = .preSwapFailed("提交前耐久同步失败，未执行替换")
                    return
                }

                do {
                    try operations.swap(coordinatedOriginal, coordinatedWork)
                } catch {
                    observed = Self.inspectAfterSwapError(
                        originalURL: coordinatedOriginal,
                        workURL: coordinatedWork,
                        commitOriginal: commitOriginal,
                        editedExpected: editedExpected,
                        ownedWork: ownedWork,
                        operations: operations,
                        uncancellableFlag: uncancellableFlag
                    )
                    if case .notStarted = observed {
                        if isUnsupportedSwap(error) {
                            observed = commitUsingExclusiveCopyFallback(
                                commitOriginal: commitOriginal,
                                editedExpected: editedExpected,
                                ownedWork: ownedWork,
                                operations: operations,
                                uncancellableFlag: uncancellableFlag
                            )
                        } else {
                            observed = .preSwapFailed(swapFailureMessage(error))
                        }
                    } else {
                        observed = Self.finalizeDurabilityIfCommitted(
                            observed,
                            originalURL: coordinatedOriginal,
                            workURL: coordinatedWork,
                            commitOriginal: commitOriginal,
                            editedExpected: editedExpected,
                            ownedWork: ownedWork,
                            operations: operations,
                            uncancellableFlag: uncancellableFlag
                        )
                    }
                    return
                }

                observed = Self.resolvePostSwapState(
                    originalURL: coordinatedOriginal,
                    workURL: coordinatedWork,
                    commitOriginal: commitOriginal,
                    editedExpected: editedExpected,
                    ownedWork: ownedWork,
                    operations: operations,
                    uncancellableFlag: uncancellableFlag
                )
                observed = Self.finalizeDurabilityIfCommitted(
                    observed,
                    originalURL: coordinatedOriginal,
                    workURL: coordinatedWork,
                    commitOriginal: commitOriginal,
                    editedExpected: editedExpected,
                    ownedWork: ownedWork,
                    operations: operations,
                    uncancellableFlag: uncancellableFlag
                )
            }
        } catch {
            if case .notStarted = observed,
               error is CancellationError || cancellationFlag.isCancelled
            {
                observed = .cancelled
            }
            return Self.resultAfterCoordinatorError(
                observed: observed,
                fallbackError: error,
                editedExpected: editedExpected
            )
        }

        return Self.executionResult(
            observed: observed,
            coordinatorTailWarning: false,
            editedExpected: editedExpected
        )
    }

    private nonisolated static func commitUsingExclusiveCopyFallback(
        commitOriginal: SafeMetadataFileSnapshot,
        editedExpected: SafeMetadataFileSnapshot,
        ownedWork: OwnedWorkFile,
        operations: SafeMetadataFileOperations,
        uncancellableFlag: SafeMetadataCancellationFlag
    ) -> ObservedCommitState {
        let workspace = ownedWork.workspace
        let recovery: SafeMetadataFileSnapshot
        do {
            try operations.moveOriginalToWorkspaceEntry(
                workspace,
                workspace.recoveryFileName
            )
            recovery = try operations.snapshotWorkspaceEntry(
                workspace,
                workspace.recoveryFileName,
                uncancellableFlag
            )
        } catch {
            if let original = try? operations.snapshotOriginal(
                ownedWork.workspace,
                uncancellableFlag
            ),
               fallbackSnapshotMatches(
                    original,
                    expected: commitOriginal,
                    workspace: workspace
               )
            {
                return .preSwapFailed("所在文件系统不支持原子交换，且无法保留原文件")
            }
            guard let movedOriginal = try? operations.snapshotWorkspaceEntry(
                workspace,
                workspace.recoveryFileName,
                uncancellableFlag
            ) else {
                return .uncertain(
                    "保留原文件后无法确认恢复副本状态",
                    recoveryURL: ownedWork.workspace.currentDirectoryURL()
                )
            }
            recovery = movedOriginal
        }

        guard fallbackSnapshotMatches(
            recovery,
            expected: commitOriginal,
            workspace: ownedWork.workspace
        ) else {
            return restoreFallbackOriginalBeforeCommit(
                expectedOriginal: recovery,
                editedExpected: editedExpected,
                ownedWork: ownedWork,
                operations: operations,
                uncancellableFlag: uncancellableFlag,
                failureMessage: Self.changedFileMessage
            )
        }

        do {
            try operations.syncWorkspaceEntry(
                workspace,
                workspace.recoveryFileName,
                recovery.nodeState.identity
            )
            try operations.syncWorkspaceDirectory(workspace)
            try operations.syncParentDirectory(workspace)
        } catch {
            return restoreFallbackOriginalBeforeCommit(
                expectedOriginal: commitOriginal,
                editedExpected: editedExpected,
                ownedWork: ownedWork,
                operations: operations,
                uncancellableFlag: uncancellableFlag,
                failureMessage: "兼容提交前耐久同步失败，未执行替换"
            )
        }

        do {
            _ = try operations.copyWorkspaceEntryToOriginal(
                workspace,
                workspace.fileName,
                uncancellableFlag
            )
        } catch {
            let installed = try? operations.snapshotOriginal(
                ownedWork.workspace,
                uncancellableFlag
            )
            if installed.map({
                $0.isEquivalentTransactionInput(to: editedExpected)
            }) != true {
                if let error = error as? SafeMetadataFileSystemError,
                   error.code == EEXIST,
                   error.ownedNodeState == nil
                {
                    return .uncertain(
                        "兼容提交时原路径被并发占用",
                        recoveryURL: ownedWork.workspace.currentDirectoryURL()
                    )
                }
                if let error = error as? SafeMetadataFileSystemError,
                   error.ownedNodeState != nil
                {
                    return restoreFallbackAfterPartialCopy(
                        expectedOriginal: commitOriginal,
                        ownedWork: ownedWork,
                        operations: operations,
                        uncancellableFlag: uncancellableFlag
                    )
                }
                return restoreFallbackOriginalBeforeCommit(
                    expectedOriginal: commitOriginal,
                    editedExpected: editedExpected,
                    ownedWork: ownedWork,
                    operations: operations,
                    uncancellableFlag: uncancellableFlag,
                    failureMessage: "所在文件系统的兼容替换失败，未提交修改"
                )
            }
        }

        let replacedOriginal: SafeMetadataFileSnapshot
        do {
            replacedOriginal = try operations.snapshotOriginal(
                ownedWork.workspace,
                uncancellableFlag
            )
            guard replacedOriginal.isEquivalentTransactionInput(to: editedExpected) else {
                return rollbackExclusiveCopyFallback(
                    commitOriginal: commitOriginal,
                    editedExpected: editedExpected,
                    ownedWork: ownedWork,
                    operations: operations,
                    uncancellableFlag: uncancellableFlag,
                    failureMessage: "兼容提交后文件状态异常且自动回滚未能确认"
                )
            }
            try operations.syncOriginal(
                ownedWork.workspace,
                replacedOriginal.nodeState.identity
            )
            try operations.syncParentDirectory(ownedWork.workspace)
            let durableOriginal = try operations.snapshotOriginal(
                ownedWork.workspace,
                uncancellableFlag
            )
            guard durableOriginal.isEquivalentTransactionInput(to: editedExpected) else {
                return rollbackExclusiveCopyFallback(
                    commitOriginal: commitOriginal,
                    editedExpected: editedExpected,
                    ownedWork: ownedWork,
                    operations: operations,
                    uncancellableFlag: uncancellableFlag,
                    failureMessage: "兼容提交耐久确认异常且自动回滚未能确认"
                )
            }
            do {
                try operations.validateOriginalParentPath(ownedWork.workspace)
            } catch {
                return .uncertain(
                    "修改已提交，但原目录路径发生变化",
                    recoveryURL: ownedWork.workspace.currentDirectoryURL()
                )
            }
        } catch {
            return rollbackExclusiveCopyFallback(
                commitOriginal: commitOriginal,
                editedExpected: editedExpected,
                ownedWork: ownedWork,
                operations: operations,
                uncancellableFlag: uncancellableFlag,
                failureMessage: "兼容提交失败且自动回滚未能确认"
            )
        }

        guard cleanupFallbackEntries(
            [
                (workspace.fileName, editedExpected),
                (workspace.recoveryFileName, recovery)
            ],
            workspace: workspace,
            operations: operations
        ) else {
            return .uncertain(
                "修改已提交，但私有副本无法安全清理",
                recoveryURL: workspace.currentDirectoryURL()
            )
        }
        return .committed(cleanupIdentity: nil)
    }

    private nonisolated static func restoreFallbackAfterPartialCopy(
        expectedOriginal: SafeMetadataFileSnapshot,
        ownedWork: OwnedWorkFile,
        operations: SafeMetadataFileOperations,
        uncancellableFlag: SafeMetadataCancellationFlag
    ) -> ObservedCommitState {
        do {
            try operations.moveOriginalToWorkspaceEntry(
                ownedWork.workspace,
                ownedWork.workspace.rollbackFileName
            )
            do {
                _ = try operations.copyWorkspaceEntryToOriginal(
                    ownedWork.workspace,
                    ownedWork.workspace.recoveryFileName,
                    uncancellableFlag
                )
            } catch let error as SafeMetadataFileSystemError
                where error.ownedNodeState != nil
            {
                try operations.moveOriginalToWorkspaceEntry(
                    ownedWork.workspace,
                    ownedWork.workspace.partialFileName
                )
                _ = try operations.copyWorkspaceEntryToOriginal(
                    ownedWork.workspace,
                    ownedWork.workspace.recoveryFileName,
                    uncancellableFlag
                )
            }
            let restored = try operations.snapshotOriginal(
                ownedWork.workspace,
                uncancellableFlag
            )
            guard restored.isEquivalentTransactionInput(to: expectedOriginal) else {
                throw WorkValidationError.changedAfterVerification
            }
            try operations.syncOriginal(
                ownedWork.workspace,
                restored.nodeState.identity
            )
            try operations.syncWorkspaceDirectory(ownedWork.workspace)
            try operations.syncParentDirectory(ownedWork.workspace)
            let durableOriginal = try operations.snapshotOriginal(
                ownedWork.workspace,
                uncancellableFlag
            )
            guard durableOriginal.isEquivalentTransactionInput(to: expectedOriginal) else {
                throw WorkValidationError.changedAfterVerification
            }
            return .uncertain(
                "兼容复制失败，原文件已恢复，部分文件已保留",
                recoveryURL: ownedWork.workspace.currentDirectoryURL()
            )
        } catch {
            return .uncertain(
                "兼容复制失败且自动恢复未能确认",
                recoveryURL: ownedWork.workspace.currentDirectoryURL()
            )
        }
    }

    private nonisolated static func restoreFallbackOriginalBeforeCommit(
        expectedOriginal: SafeMetadataFileSnapshot,
        editedExpected: SafeMetadataFileSnapshot,
        ownedWork: OwnedWorkFile,
        operations: SafeMetadataFileOperations,
        uncancellableFlag: SafeMetadataCancellationFlag,
        failureMessage: String
    ) -> ObservedCommitState {
        do {
            _ = try operations.copyWorkspaceEntryToOriginal(
                ownedWork.workspace,
                ownedWork.workspace.recoveryFileName,
                uncancellableFlag
            )
            let restored = try operations.snapshotOriginal(
                ownedWork.workspace,
                uncancellableFlag
            )
            guard restored.isEquivalentTransactionInput(to: expectedOriginal) else {
                return .uncertain(
                    "恢复原文件后状态无法确认",
                    recoveryURL: ownedWork.workspace.currentDirectoryURL()
                )
            }
            do {
                try operations.validateOriginalParentPath(ownedWork.workspace)
            } catch {
                return .uncertain(
                    "原文件已恢复，但原目录路径发生变化",
                    recoveryURL: ownedWork.workspace.currentDirectoryURL()
                )
            }
            try operations.syncOriginal(
                ownedWork.workspace,
                restored.nodeState.identity
            )
            try operations.syncParentDirectory(ownedWork.workspace)
            let durableOriginal = try operations.snapshotOriginal(
                ownedWork.workspace,
                uncancellableFlag
            )
            guard durableOriginal.isEquivalentTransactionInput(to: expectedOriginal) else {
                return .uncertain(
                    "恢复原文件后耐久状态无法确认",
                    recoveryURL: ownedWork.workspace.currentDirectoryURL()
                )
            }
            guard cleanupFallbackEntries(
                [
                    (ownedWork.workspace.fileName, editedExpected),
                    (ownedWork.workspace.recoveryFileName, expectedOriginal)
                ],
                workspace: ownedWork.workspace,
                operations: operations
            ) else {
                return .uncertain(
                    "原文件已恢复，但私有副本无法安全清理",
                    recoveryURL: ownedWork.workspace.currentDirectoryURL()
                )
            }
            return .preSwapFailed(failureMessage)
        } catch {
            return .uncertain(
                "原文件已保留，但自动恢复未能确认",
                recoveryURL: ownedWork.workspace.currentDirectoryURL()
            )
        }
    }

    private nonisolated static func rollbackExclusiveCopyFallback(
        commitOriginal: SafeMetadataFileSnapshot,
        editedExpected: SafeMetadataFileSnapshot,
        ownedWork: OwnedWorkFile,
        operations: SafeMetadataFileOperations,
        uncancellableFlag: SafeMetadataCancellationFlag,
        failureMessage: String
    ) -> ObservedCommitState {
        var didPreservePartial = false
        do {
            try operations.moveOriginalToWorkspaceEntry(
                ownedWork.workspace,
                ownedWork.workspace.rollbackFileName
            )
            let preservedCurrent = try operations.snapshotWorkspaceEntry(
                ownedWork.workspace,
                ownedWork.workspace.rollbackFileName,
                uncancellableFlag
            )
            do {
                _ = try operations.copyWorkspaceEntryToOriginal(
                    ownedWork.workspace,
                    ownedWork.workspace.recoveryFileName,
                    uncancellableFlag
                )
            } catch let error as SafeMetadataFileSystemError
                where error.ownedNodeState != nil
            {
                didPreservePartial = true
                try operations.moveOriginalToWorkspaceEntry(
                    ownedWork.workspace,
                    ownedWork.workspace.partialFileName
                )
                _ = try operations.copyWorkspaceEntryToOriginal(
                    ownedWork.workspace,
                    ownedWork.workspace.recoveryFileName,
                    uncancellableFlag
                )
            }
            let restored = try operations.snapshotOriginal(
                ownedWork.workspace,
                uncancellableFlag
            )
            try operations.syncOriginal(
                ownedWork.workspace,
                restored.nodeState.identity
            )
            try operations.syncWorkspaceEntry(
                ownedWork.workspace,
                ownedWork.workspace.rollbackFileName,
                preservedCurrent.nodeState.identity
            )
            try operations.syncWorkspaceDirectory(ownedWork.workspace)
            try operations.syncParentDirectory(ownedWork.workspace)
            let durableOriginal = try operations.snapshotOriginal(
                ownedWork.workspace,
                uncancellableFlag
            )
            let durableCurrent = try operations.snapshotWorkspaceEntry(
                ownedWork.workspace,
                ownedWork.workspace.rollbackFileName,
                uncancellableFlag
            )
            guard restored.isEquivalentTransactionInput(to: commitOriginal),
                  durableOriginal.isEquivalentTransactionInput(to: commitOriginal),
                  fallbackSnapshotMatches(
                    durableCurrent,
                    expected: preservedCurrent,
                    workspace: ownedWork.workspace
                  )
            else {
                return .uncertain(
                    failureMessage,
                    recoveryURL: ownedWork.workspace.currentDirectoryURL()
                )
            }
            guard preservedCurrent.isEquivalentTransactionInput(to: editedExpected) else {
                return .uncertain(
                    failureMessage,
                    recoveryURL: ownedWork.workspace.currentDirectoryURL()
                )
            }
            do {
                try operations.validateOriginalParentPath(ownedWork.workspace)
            } catch {
                return .uncertain(
                    "原文件已恢复，但原目录路径发生变化",
                    recoveryURL: ownedWork.workspace.currentDirectoryURL()
                )
            }
            guard !didPreservePartial else {
                return .uncertain(
                    "原文件已恢复，失败的部分副本已保留",
                    recoveryURL: ownedWork.workspace.currentDirectoryURL()
                )
            }
            guard cleanupFallbackEntries(
                [
                    (ownedWork.workspace.fileName, editedExpected),
                    (ownedWork.workspace.recoveryFileName, commitOriginal),
                    (ownedWork.workspace.rollbackFileName, durableCurrent)
                ],
                workspace: ownedWork.workspace,
                operations: operations
            ) else {
                return .uncertain(
                    "原文件已恢复，但私有副本无法安全清理",
                    recoveryURL: ownedWork.workspace.currentDirectoryURL()
                )
            }
            return .rolledBack(cleanupIdentity: nil)
        } catch {
            return .uncertain(
                failureMessage,
                recoveryURL: ownedWork.workspace.currentDirectoryURL()
            )
        }
    }

    private nonisolated static func cleanupFallbackEntries(
        _ entries: [(String, SafeMetadataFileSnapshot)],
        workspace: SafeMetadataWorkspace,
        operations: SafeMetadataFileOperations
    ) -> Bool {
        for (entryName, expectedSnapshot) in entries {
            switch operations.removeWorkspaceEntryIfOwned(
                workspace,
                entryName,
                expectedSnapshot
            ) {
            case .removed, .missing:
                continue
            case .identityMismatch, .failed:
                return false
            }
        }
        return true
    }

    private nonisolated static func isUnsupportedSwap(_ error: Error) -> Bool {
        guard let error = error as? SafeMetadataFileSystemError,
              error.operation == .swap else {
            return false
        }
        return error.code == ENOTSUP || error.code == EOPNOTSUPP
    }

    private nonisolated static func fallbackSnapshotMatches(
        _ actual: SafeMetadataFileSnapshot,
        expected: SafeMetadataFileSnapshot,
        workspace: SafeMetadataWorkspace
    ) -> Bool {
        if workspace.supportsStableFileIdentity {
            return actual.matchesAfterRename(expected)
        }
        return actual.isEquivalentTransactionInput(to: expected)
    }

    private nonisolated static func resolvePostSwapState(
        originalURL: URL,
        workURL: URL,
        commitOriginal: SafeMetadataFileSnapshot,
        editedExpected: SafeMetadataFileSnapshot,
        ownedWork: OwnedWorkFile,
        operations: SafeMetadataFileOperations,
        uncancellableFlag: SafeMetadataCancellationFlag
    ) -> ObservedCommitState {
        let originalAfter: SafeMetadataFileSnapshot
        let recoveryAfter: SafeMetadataFileSnapshot
        do {
            originalAfter = try operations.snapshotURL(originalURL, uncancellableFlag)
            recoveryAfter = try operations.snapshotWorkspace(
                ownedWork.workspace,
                uncancellableFlag
            )
        } catch {
            return .uncertain(
                "swap 后无法确认 original 或 recovery 的完整状态",
                recoveryURL: ownedWork.workspace.fileURL
            )
        }

        if originalAfter.matchesAfterRename(editedExpected),
           recoveryAfter.matchesAfterRename(commitOriginal)
        {
            return .committed(cleanupIdentity: recoveryAfter.nodeState.identity)
        }

        return rollbackAndSynchronize(
            originalURL: originalURL,
            workURL: workURL,
            expectedOriginal: recoveryAfter,
            expectedWork: editedExpected,
            ownedWork: ownedWork,
            operations: operations,
            uncancellableFlag: uncancellableFlag,
            failureMessage: "检测到提交状态异常且自动回滚未能耐久确认"
        )
    }

    private nonisolated static func finalizeDurabilityIfCommitted(
        _ observed: ObservedCommitState,
        originalURL: URL,
        workURL: URL,
        commitOriginal: SafeMetadataFileSnapshot,
        editedExpected: SafeMetadataFileSnapshot,
        ownedWork: OwnedWorkFile,
        operations: SafeMetadataFileOperations,
        uncancellableFlag: SafeMetadataCancellationFlag
    ) -> ObservedCommitState {
        guard case .committed = observed else { return observed }
        do {
            try operations.syncURLFile(
                originalURL,
                editedExpected.nodeState.identity
            )
            try operations.syncParentDirectory(ownedWork.workspace)

            let durableOriginal = try operations.snapshotURL(
                originalURL,
                uncancellableFlag
            )
            let durableRecovery = try operations.snapshotWorkspace(
                ownedWork.workspace,
                uncancellableFlag
            )
            guard durableOriginal.matchesAfterRename(editedExpected),
                  durableRecovery.matchesAfterRename(commitOriginal)
            else {
                return rollbackAndSynchronize(
                    originalURL: originalURL,
                    workURL: workURL,
                    expectedOriginal: commitOriginal,
                    expectedWork: editedExpected,
                    ownedWork: ownedWork,
                    operations: operations,
                    uncancellableFlag: uncancellableFlag,
                    failureMessage: "耐久同步后文件状态发生变化且自动回滚未能耐久确认"
                )
            }
            return observed
        } catch {
            return rollbackAndSynchronize(
                originalURL: originalURL,
                workURL: workURL,
                expectedOriginal: commitOriginal,
                expectedWork: editedExpected,
                ownedWork: ownedWork,
                operations: operations,
                uncancellableFlag: uncancellableFlag,
                failureMessage: "提交后耐久同步失败且自动回滚未能耐久确认"
            )
        }
    }

    private nonisolated static func rollbackAndSynchronize(
        originalURL: URL,
        workURL: URL,
        expectedOriginal: SafeMetadataFileSnapshot,
        expectedWork: SafeMetadataFileSnapshot,
        ownedWork: OwnedWorkFile,
        operations: SafeMetadataFileOperations,
        uncancellableFlag: SafeMetadataCancellationFlag,
        failureMessage: String
    ) -> ObservedCommitState {
        do {
            try operations.swap(originalURL, workURL)
            let restoredOriginal = try operations.snapshotURL(
                originalURL,
                uncancellableFlag
            )
            let restoredWork = try operations.snapshotWorkspace(
                ownedWork.workspace,
                uncancellableFlag
            )
            guard restoredOriginal.matchesAfterRename(expectedOriginal),
                  restoredWork.matchesAfterRename(expectedWork)
            else {
                return .uncertain(
                    failureMessage,
                    recoveryURL: ownedWork.workspace.fileURL
                )
            }

            try operations.syncURLFile(
                originalURL,
                restoredOriginal.nodeState.identity
            )
            try operations.syncWorkspaceFile(
                ownedWork.workspace,
                restoredWork.nodeState.identity
            )
            try operations.syncWorkspaceDirectory(ownedWork.workspace)
            try operations.syncParentDirectory(ownedWork.workspace)

            let durableOriginal = try operations.snapshotURL(
                originalURL,
                uncancellableFlag
            )
            let durableWork = try operations.snapshotWorkspace(
                ownedWork.workspace,
                uncancellableFlag
            )
            guard durableOriginal.matchesAfterRename(expectedOriginal),
                  durableWork.matchesAfterRename(expectedWork)
            else {
                return .uncertain(
                    failureMessage,
                    recoveryURL: ownedWork.workspace.fileURL
                )
            }
            return .rolledBack(cleanupIdentity: durableWork.nodeState.identity)
        } catch {
            return .uncertain(
                failureMessage,
                recoveryURL: ownedWork.workspace.fileURL
            )
        }
    }

    private nonisolated static func inspectAfterSwapError(
        originalURL: URL,
        workURL: URL,
        commitOriginal: SafeMetadataFileSnapshot,
        editedExpected: SafeMetadataFileSnapshot,
        ownedWork: OwnedWorkFile,
        operations: SafeMetadataFileOperations,
        uncancellableFlag: SafeMetadataCancellationFlag
    ) -> ObservedCommitState {
        guard let original = try? operations.snapshotURL(originalURL, uncancellableFlag),
              let coordinatedWork = try? operations.snapshotURL(workURL, uncancellableFlag),
              let work = try? operations.snapshotWorkspace(
                ownedWork.workspace,
                uncancellableFlag
              ),
              coordinatedWork.matchesAfterRename(work)
        else {
            return .uncertain(
                "原子交换报告失败且文件状态无法确认",
                recoveryURL: ownedWork.workspace.fileURL
            )
        }
        if original.matchesAfterRename(commitOriginal),
           work.matchesAfterRename(editedExpected)
        {
            return .notStarted
        }
        if original.matchesAfterRename(editedExpected),
           work.matchesAfterRename(commitOriginal)
        {
            return .committed(cleanupIdentity: work.nodeState.identity)
        }
        return .uncertain(
            "原子交换报告失败且文件状态不一致",
            recoveryURL: ownedWork.workspace.fileURL
        )
    }

    private nonisolated static func resultAfterCoordinatorError(
        observed: ObservedCommitState,
        fallbackError: Error,
        editedExpected: SafeMetadataFileSnapshot
    ) -> CommitExecutionResult {
        switch observed {
        case .committed, .rolledBack, .cancelled, .preSwapFailed, .uncertain:
            return executionResult(
                observed: observed,
                coordinatorTailWarning: true,
                editedExpected: editedExpected
            )
        case .notStarted:
            return CommitExecutionResult(
                disposition: .preSwapFailed(
                    commitFailureMessage(fallbackError),
                    coordinatorTailWarning: false
                ),
                cleanupIdentity: editedExpected.nodeState.identity
            )
        }
    }

    private nonisolated static func executionResult(
        observed: ObservedCommitState,
        coordinatorTailWarning: Bool,
        editedExpected: SafeMetadataFileSnapshot
    ) -> CommitExecutionResult {
        switch observed {
        case let .committed(cleanupIdentity):
            return CommitExecutionResult(
                disposition: .committed(
                    coordinatorTailWarning: coordinatorTailWarning
                ),
                cleanupIdentity: cleanupIdentity
            )
        case let .rolledBack(cleanupIdentity):
            return CommitExecutionResult(
                disposition: .rolledBack(
                    coordinatorTailWarning: coordinatorTailWarning
                ),
                cleanupIdentity: cleanupIdentity
            )
        case .cancelled:
            return CommitExecutionResult(
                disposition: .cancelled(
                    coordinatorTailWarning: coordinatorTailWarning
                ),
                cleanupIdentity: editedExpected.nodeState.identity
            )
        case let .preSwapFailed(message):
            return CommitExecutionResult(
                disposition: .preSwapFailed(
                    message,
                    coordinatorTailWarning: coordinatorTailWarning
                ),
                cleanupIdentity: editedExpected.nodeState.identity
            )
        case let .uncertain(message, recoveryURL):
            return CommitExecutionResult(
                disposition: .uncertain(message, recoveryURL: recoveryURL),
                cleanupIdentity: nil
            )
        case .notStarted:
            return CommitExecutionResult(
                disposition: .preSwapFailed(
                    "未进入原子提交阶段",
                    coordinatorTailWarning: coordinatorTailWarning
                ),
                cleanupIdentity: editedExpected.nodeState.identity
            )
        }
    }

    private nonisolated static func runBlocking<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .utility, operation: operation).value
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
        if let expectedComposer = patch.composer,
           metadata.composers.first != expectedComposer
        {
            return "写入后验证失败：作曲者标签不匹配"
        }
        return nil
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
            case .privilegedMode:
                return "文件包含 setuid/setgid 特权位，已拒绝编辑"
            case .notReadable:
                return "文件不可读"
            case .notWritable:
                return "文件不可写"
            }
        }
        if error is CancellationError { return "操作已取消" }
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

    private func copyFailureMessage(_ error: Error) -> String {
        "无法创建安全工作副本：\(Self.copyFailureDetail(error))"
    }

    private nonisolated static func copyFailureDetail(_ error: Error) -> String {
        guard let error = error as? SafeMetadataFileSystemError else {
            return "文件复制失败"
        }
        switch error.code {
        case ENOSPC, EDQUOT:
            return "磁盘空间不足"
        case EACCES, EPERM:
            return "没有创建副本的权限"
        case ECANCELED:
            return "操作已取消"
        default:
            return "文件复制失败"
        }
    }

    private nonisolated static func commitFailureMessage(_ error: Error) -> String {
        if error is CancellationError { return "操作已取消" }
        guard let error = error as? SafeMetadataFileSystemError else {
            return "无法完成原子提交"
        }
        switch error.operation {
        case .coordinate:
            return "无法协调原文件替换"
        case .swap:
            return swapFailureMessage(error)
        default:
            return "提交前文件状态验证失败"
        }
    }

    private nonisolated static func swapFailureMessage(_ error: Error) -> String {
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

    private nonisolated static func cleanupFailureDetail(
        _ error: SafeMetadataFileSystemError
    ) -> String {
        switch error.code {
        case EACCES, EPERM:
            return "没有删除权限"
        case EBUSY:
            return "文件正被占用"
        case EROFS:
            return "所在文件系统为只读"
        case ENOTEMPTY:
            return "目录中存在未识别对象"
        default:
            return "删除操作失败"
        }
    }

    private func appendCleanupWarning(
        _ message: String,
        _ warning: String?
    ) -> String {
        Self.appendCleanupWarning(message, warning)
    }

    private nonisolated static func appendCleanupWarning(
        _ message: String,
        _ warning: String?
    ) -> String {
        guard let warning else { return message }
        return "\(message)；\(warning)"
    }

    private func result(
        for url: URL,
        status: BatchFileStatus,
        message: String?,
        recoveryURL: URL? = nil
    ) -> BatchFileResult {
        BatchFileResult(
            url: url,
            status: status,
            message: message,
            recoveryURL: recoveryURL
        )
    }
}

private struct OwnedWorkFile: Sendable {
    let workspace: SafeMetadataWorkspace
    let identity: SafeMetadataFileIdentity
    let copiedExpected: SafeMetadataFileSnapshot
}

private struct WorkspaceCleanupReport: Sendable {
    let warning: String?
    let recoveryURL: URL?

    init(warning: String?, recoveryURL: URL? = nil) {
        self.warning = warning
        self.recoveryURL = recoveryURL
    }
}

private enum ObservedCommitState: Sendable {
    case notStarted
    case cancelled
    case preSwapFailed(String)
    case committed(cleanupIdentity: SafeMetadataFileIdentity?)
    case rolledBack(cleanupIdentity: SafeMetadataFileIdentity?)
    case uncertain(String, recoveryURL: URL)
}

private struct CommitExecutionResult: Sendable {
    let disposition: CommitDisposition
    let cleanupIdentity: SafeMetadataFileIdentity?
}

private enum CommitDisposition: Sendable {
    case committed(coordinatorTailWarning: Bool)
    case rolledBack(coordinatorTailWarning: Bool)
    case cancelled(coordinatorTailWarning: Bool)
    case preSwapFailed(String, coordinatorTailWarning: Bool)
    case uncertain(String, recoveryURL: URL)
}

private struct WorkspaceCreationError: Error, Sendable {
    let message: String
    let recoveryURL: URL?

    init(message: String, recoveryURL: URL? = nil) {
        self.message = message
        self.recoveryURL = recoveryURL
    }
}

private struct WorkspaceCancellationError: Error, Sendable {
    let message: String
    let recoveryURL: URL?

    init(message: String, recoveryURL: URL? = nil) {
        self.message = message
        self.recoveryURL = recoveryURL
    }
}

private enum WorkValidationError: Error {
    case identityChanged
    case copiedInputMismatch
    case preservedMetadataChanged
    case changedAfterVerification
}

private enum InitialValidationError: Error {
    case symbolicLink
    case notRegularFile
    case hardLinked
    case privilegedMode
    case notReadable
    case notWritable
}
