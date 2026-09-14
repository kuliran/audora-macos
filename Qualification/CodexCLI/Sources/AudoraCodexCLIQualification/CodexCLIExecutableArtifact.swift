import CryptoKit
import Darwin
import Foundation

/// An open, exact native executable vnode used for every probe and launch in one
/// qualification attempt. The descriptor pins the identity while the original
/// path remains the no-copy launch path, preserving macOS signing, quarantine,
/// and other filesystem provenance attached to that artifact.
final class CodexCLIExecutableArtifact: @unchecked Sendable {
    private static let byteCeiling: off_t = 512 * 1_024 * 1_024

    struct Identity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let byteCount: Int64
        let mode: UInt16
        let linkCount: UInt16
        let owner: UInt32
        let group: UInt32
        let fileFlags: UInt32
        let generation: UInt32
        let birthSeconds: Int64
        let birthNanoseconds: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64
        let sha256: String
    }

    let executableURL: URL
    let identity: Identity
    let descriptor: Int32

    init?(executableURL: URL) {
        let descriptor = executableURL.path.withCString {
            open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { return nil }
        guard let identity = Self.readIdentity(descriptor: descriptor) else {
            _ = close(descriptor)
            return nil
        }
        self.executableURL = executableURL
        self.identity = identity
        self.descriptor = descriptor
    }

    deinit {
        _ = close(descriptor)
    }

    func revalidate() -> Bool {
        guard Self.readIdentity(descriptor: descriptor) == identity else {
            return false
        }
        let currentDescriptor = executableURL.path.withCString {
            open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard currentDescriptor >= 0 else { return false }
        defer { _ = close(currentDescriptor) }
        return Self.readIdentity(descriptor: currentDescriptor) == identity
    }

    func pathStillNamesPinnedBytes() -> Bool {
        let currentDescriptor = executableURL.path.withCString {
            open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard currentDescriptor >= 0 else { return false }
        defer { _ = close(currentDescriptor) }
        guard let current = Self.readIdentity(descriptor: currentDescriptor)
        else { return false }
        return current.device == identity.device
            && current.inode == identity.inode
            && current.byteCount == identity.byteCount
            && current.sha256 == identity.sha256
    }

    func revalidateLaunchedProcess(_ processID: pid_t) -> Bool {
        var pathBuffer = [CChar](
            repeating: 0,
            count: Int(MAXPATHLEN) * 4
        )
        let pathByteCount = proc_pidpath(
            processID,
            &pathBuffer,
            UInt32(pathBuffer.count)
        )
        guard pathByteCount > 0 else { return false }
        let launchedPathBytes = pathBuffer
            .prefix(Int(pathByteCount))
            .prefix(while: { $0 != 0 })
            .map { UInt8(bitPattern: $0) }
        guard String(decoding: launchedPathBytes, as: UTF8.self)
            == executableURL.path
        else { return false }
        return launchedProcessMapsPinnedExecutable(processID) && revalidate()
    }

    func launchedProcessMapsPinnedExecutable(_ processID: pid_t) -> Bool {
        var address: UInt64 = 0
        for _ in 0 ..< 4_096 {
            var region = proc_regionwithpathinfo()
            let expectedByteCount = MemoryLayout<proc_regionwithpathinfo>.stride
            let byteCount = proc_pidinfo(
                processID,
                PROC_PIDREGIONPATHINFO,
                address,
                &region,
                Int32(expectedByteCount)
            )
            guard byteCount == expectedByteCount else { return false }

            let regionInfo = region.prp_prinfo
            let vnode = region.prp_vip.vip_vi.vi_stat
            let isExecutable = regionInfo.pri_protection
                & UInt32(VM_PROT_EXECUTE) != 0
            if isExecutable,
               UInt64(vnode.vst_dev) == identity.device,
               vnode.vst_ino == identity.inode,
               vnode.vst_size == identity.byteCount,
               vnode.vst_mode == identity.mode,
               vnode.vst_uid == identity.owner,
               vnode.vst_gid == identity.group,
               vnode.vst_mtime == identity.modificationSeconds,
               vnode.vst_mtimensec == identity.modificationNanoseconds,
               vnode.vst_ctime == identity.changeSeconds,
               vnode.vst_ctimensec == identity.changeNanoseconds
            {
                return true
            }

            let (nextAddress, overflow) = regionInfo.pri_address
                .addingReportingOverflow(regionInfo.pri_size)
            guard !overflow, nextAddress > address else { return false }
            address = nextAddress
        }
        return false
    }

    private static func readIdentity(descriptor: Int32) -> Identity? {
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 4,
              before.st_size <= byteCeiling
        else { return nil }

        let expectedByteCount = Int(before.st_size)
        var totalByteCount = 0
        var magic = Data()
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)

        while totalByteCount < expectedByteCount {
            let requestedByteCount = min(
                buffer.count,
                expectedByteCount - totalByteCount
            )
            let readByteCount = buffer.withUnsafeMutableBytes { bytes -> Int in
                while true {
                    let result = pread(
                        descriptor,
                        bytes.baseAddress,
                        requestedByteCount,
                        off_t(totalByteCount)
                    )
                    if result < 0, errno == EINTR { continue }
                    return result
                }
            }
            guard readByteCount > 0 else { return nil }

            let chunk = Data(buffer.prefix(readByteCount))
            if magic.count < 4 {
                magic.append(chunk.prefix(4 - magic.count))
                guard magic.count < 4 || isNativeMachO(magic) else { return nil }
            }
            hasher.update(data: chunk)
            totalByteCount += readByteCount
        }

        var trailingByte: UInt8 = 0
        let trailingByteCount = withUnsafeMutableBytes(of: &trailingByte) { bytes in
            while true {
                let result = pread(
                    descriptor,
                    bytes.baseAddress,
                    1,
                    off_t(expectedByteCount)
                )
                if result < 0, errno == EINTR { continue }
                return result
            }
        }
        var after = stat()
        guard trailingByteCount == 0,
              fstat(descriptor, &after) == 0,
              stableFields(of: after, equal: before)
        else { return nil }

        return Identity(
            device: UInt64(before.st_dev),
            inode: UInt64(before.st_ino),
            byteCount: Int64(before.st_size),
            mode: UInt16(before.st_mode),
            linkCount: UInt16(before.st_nlink),
            owner: UInt32(before.st_uid),
            group: UInt32(before.st_gid),
            fileFlags: UInt32(before.st_flags),
            generation: UInt32(before.st_gen),
            birthSeconds: Int64(before.st_birthtimespec.tv_sec),
            birthNanoseconds: Int64(before.st_birthtimespec.tv_nsec),
            modificationSeconds: Int64(before.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(before.st_mtimespec.tv_nsec),
            changeSeconds: Int64(before.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(before.st_ctimespec.tv_nsec),
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    private static func stableFields(of lhs: stat, equal rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_uid == rhs.st_uid
            && lhs.st_gid == rhs.st_gid
            && lhs.st_flags == rhs.st_flags
            && lhs.st_gen == rhs.st_gen
            && lhs.st_birthtimespec.tv_sec == rhs.st_birthtimespec.tv_sec
            && lhs.st_birthtimespec.tv_nsec == rhs.st_birthtimespec.tv_nsec
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func isNativeMachO(_ bytes: Data) -> Bool {
        let prefix = Array(bytes.prefix(4))
        return [
            [0xfe, 0xed, 0xfa, 0xce],
            [0xce, 0xfa, 0xed, 0xfe],
            [0xfe, 0xed, 0xfa, 0xcf],
            [0xcf, 0xfa, 0xed, 0xfe],
            [0xca, 0xfe, 0xba, 0xbe],
            [0xbe, 0xba, 0xfe, 0xca],
            [0xca, 0xfe, 0xba, 0xbf],
            [0xbf, 0xba, 0xfe, 0xca],
        ].contains(prefix)
    }
}
