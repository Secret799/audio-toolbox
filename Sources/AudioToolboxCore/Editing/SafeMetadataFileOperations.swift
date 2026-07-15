import CryptoKit
import Darwin
import Foundation

struct SafeMetadataFileNodeState: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let statusChangeSeconds: Int64
    let statusChangeNanoseconds: Int64
    let linkCount: UInt64
    let mode: UInt16

    var identity: SafeMetadataFileIdentity {
        SafeMetadataFileIdentity(device: device, inode: inode)
    }

    var isRegularFile: Bool {
        mode & UInt16(S_IFMT) == UInt16(S_IFREG)
    }

    var isSymbolicLink: Bool {
        mode & UInt16(S_IFMT) == UInt16(S_IFLNK)
    }
}

struct SafeMetadataFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

enum SafeMetadataFileSystemOperation: Sendable {
    case copy
    case stat
    case digest
    case swap
    case unlink
}

struct SafeMetadataFileSystemError: Error, Sendable {
    let operation: SafeMetadataFileSystemOperation
    let code: Int32
    let ownedNodeState: SafeMetadataFileNodeState?

    init(
        operation: SafeMetadataFileSystemOperation,
        code: Int32,
        ownedNodeState: SafeMetadataFileNodeState? = nil
    ) {
        self.operation = operation
        self.code = code
        self.ownedNodeState = ownedNodeState
    }
}

// These immutable closures are invoked only by SafeMetadataWriter's actor-isolated state machine.
struct SafeMetadataFileOperations: @unchecked Sendable {
    let copyExclusive: (URL, URL) throws -> SafeMetadataFileNodeState
    let nodeState: (URL) throws -> SafeMetadataFileNodeState
    let digest: (URL) throws -> Data
    let isReadable: (URL) -> Bool
    let isWritable: (URL) -> Bool
    let coordinateReplacing: (URL, URL, (URL, URL) throws -> Void) throws -> Void
    let swap: (URL, URL) throws -> Void
    let unlink: (URL) throws -> Void

    // Keep FileManager in the factory signature for public initializer source compatibility;
    // transactional mutations use Darwin primitives with explicit inode ownership.
    static func live(fileManager _: FileManager = .default) -> Self {
        Self(
            copyExclusive: copyExclusive,
            nodeState: nodeState,
            digest: digest,
            isReadable: { url in
                url.path.withCString { access($0, R_OK) == 0 }
            },
            isWritable: { url in
                url.path.withCString { access($0, W_OK) == 0 }
            },
            coordinateReplacing: coordinateReplacing,
            swap: swap,
            unlink: unlink
        )
    }

    func overriding(
        copyExclusive: ((URL, URL) throws -> SafeMetadataFileNodeState)? = nil,
        nodeState: ((URL) throws -> SafeMetadataFileNodeState)? = nil,
        digest: ((URL) throws -> Data)? = nil,
        isReadable: ((URL) -> Bool)? = nil,
        isWritable: ((URL) -> Bool)? = nil,
        coordinateReplacing: ((URL, URL, (URL, URL) throws -> Void) throws -> Void)? = nil,
        swap: ((URL, URL) throws -> Void)? = nil,
        unlink: ((URL) throws -> Void)? = nil
    ) -> Self {
        Self(
            copyExclusive: copyExclusive ?? self.copyExclusive,
            nodeState: nodeState ?? self.nodeState,
            digest: digest ?? self.digest,
            isReadable: isReadable ?? self.isReadable,
            isWritable: isWritable ?? self.isWritable,
            coordinateReplacing: coordinateReplacing ?? self.coordinateReplacing,
            swap: swap ?? self.swap,
            unlink: unlink ?? self.unlink
        )
    }

    private static func copyExclusive(
        source: URL,
        destination: URL
    ) throws -> SafeMetadataFileNodeState {
        guard let state = copyfile_state_alloc() else {
            throw SafeMetadataFileSystemError(operation: .copy, code: ENOMEM)
        }
        defer { copyfile_state_free(state) }

        let flags = copyfile_flags_t(
            COPYFILE_ALL
                | COPYFILE_EXCL
                | COPYFILE_NOFOLLOW_SRC
                | COPYFILE_NOFOLLOW_DST
        )
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                copyfile(sourcePath, destinationPath, state, flags)
            }
        }
        guard result == 0 else {
            let errorCode = errno
            throw SafeMetadataFileSystemError(
                operation: .copy,
                code: errorCode,
                ownedNodeState: destinationState(from: state)
            )
        }

        guard let destinationState = destinationState(from: state) else {
            throw SafeMetadataFileSystemError(operation: .copy, code: EIO)
        }
        return destinationState
    }

    private static func destinationState(
        from copyState: copyfile_state_t
    ) -> SafeMetadataFileNodeState? {
        var descriptor: Int32 = -1
        guard copyfile_state_get(
            copyState,
            UInt32(COPYFILE_STATE_DST_FD),
            &descriptor
        ) == 0,
            descriptor >= 0
        else {
            return nil
        }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else { return nil }
        return SafeMetadataFileNodeState(status)
    }

    private static func nodeState(url: URL) throws -> SafeMetadataFileNodeState {
        var status = stat()
        let result = url.path.withCString { path in
            lstat(path, &status)
        }
        guard result == 0 else {
            throw SafeMetadataFileSystemError(operation: .stat, code: errno)
        }
        return SafeMetadataFileNodeState(status)
    }

    private static func digest(url: URL) throws -> Data {
        let descriptor = url.path.withCString { path in
            open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw SafeMetadataFileSystemError(operation: .digest, code: errno)
        }
        defer { close(descriptor) }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw SafeMetadataFileSystemError(operation: .digest, code: errno)
            }
            hasher.update(data: Data(buffer[0..<count]))
        }
        return Data(hasher.finalize())
    }

    private static func coordinateReplacing(
        original: URL,
        temporary: URL,
        accessor: (URL, URL) throws -> Void
    ) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var accessorError: Error?
        var didEnterAccessor = false

        coordinator.coordinate(
            writingItemAt: original,
            options: .forReplacing,
            writingItemAt: temporary,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedOriginal, coordinatedTemporary in
            didEnterAccessor = true
            do {
                try accessor(coordinatedOriginal, coordinatedTemporary)
            } catch {
                accessorError = error
            }
        }

        if let accessorError { throw accessorError }
        guard coordinationError == nil, didEnterAccessor else {
            throw SafeMetadataCoordinationError.failed
        }
    }

    private static func swap(original: URL, temporary: URL) throws {
        let result = original.path.withCString { originalPath in
            temporary.path.withCString { temporaryPath in
                renameatx_np(
                    AT_FDCWD,
                    originalPath,
                    AT_FDCWD,
                    temporaryPath,
                    UInt32(RENAME_SWAP)
                )
            }
        }
        guard result == 0 else {
            throw SafeMetadataFileSystemError(operation: .swap, code: errno)
        }
    }

    private static func unlink(url: URL) throws {
        let result = url.path.withCString { path in
            Darwin.unlink(path)
        }
        guard result == 0 else {
            throw SafeMetadataFileSystemError(operation: .unlink, code: errno)
        }
    }
}

private extension SafeMetadataFileNodeState {
    init(_ status: stat) {
        device = UInt64(status.st_dev)
        inode = UInt64(status.st_ino)
        size = Int64(status.st_size)
        modificationSeconds = Int64(status.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(status.st_mtimespec.tv_nsec)
        statusChangeSeconds = Int64(status.st_ctimespec.tv_sec)
        statusChangeNanoseconds = Int64(status.st_ctimespec.tv_nsec)
        linkCount = UInt64(status.st_nlink)
        mode = UInt16(status.st_mode)
    }
}


enum SafeMetadataCoordinationError: Error {
    case failed
}
