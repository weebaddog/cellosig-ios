import CryptoKit
import Foundation

/// Streaming AES-256-GCM for attachments, identical to Android's `crypto/ChunkedAead.kt` ("CSv2"):
///
///   header  = "CSv2" || chunkSize (u32 BE) || noncePrefix (8 random bytes)
///   chunk i = AES-GCM(key, nonce = noncePrefix || i (u32 BE), aad = i (u32 BE) || final (1 byte)) -> ct || tag
public enum ChunkedAead {
    public static let magic = Data("CSv2".utf8)
    public static let chunk = 64 * 1024
    static let tag = 16
    static let maxChunk = 1024 * 1024

    public enum Failure: Error { case notChunked, badChunkSize, truncated, tooLarge(Int64) }

    /// Encrypt `input` into `output`; returns the plaintext size.
    @discardableResult
    public static func encrypt(input: FileHandle, output: FileHandle, key: Data, maxBytes: Int64 = .max) throws -> Int64 {
        let prefix = Primitives.randomBytes(8)
        output.write(magic + Data.u32(chunk) + prefix)
        var index = 0
        var total: Int64 = 0
        var cur = try readUpTo(input, chunk)
        while true {
            total += Int64(cur.count)
            if total > maxBytes { throw Failure.tooLarge(maxBytes) }
            let next = cur.count == chunk ? try readUpTo(input, chunk) : Data()
            let final = next.isEmpty
            output.write(try seal(key, prefix, index, final, cur))
            if final { return total }
            cur = next
            index += 1
        }
    }

    /// Decrypt a whole blob held in memory (small files, previews).
    public static func decrypt(_ blob: Data, key: Data) throws -> Data {
        let out = NSMutableData()
        try decrypt(reader: DataReader(blob), key: key) { out.append($0) }
        return out as Data
    }

    /// Decrypt `input` (positioned at the start of the blob) into `output`; throws if anything was altered.
    public static func decrypt(input: FileHandle, output: FileHandle, key: Data) throws {
        try decrypt(reader: FileReader(input), key: key) { output.write($0) }
    }

    /// Authenticate every chunk of a blob without keeping the plaintext.
    public static func verify(input: FileHandle, key: Data) throws {
        try decrypt(reader: FileReader(input), key: key) { _ in }
    }

    /// Encrypt bytes held in memory (tests, small blobs).
    public static func encrypt(_ plaintext: Data, key: Data) throws -> Data {
        let prefix = Primitives.randomBytes(8)
        var out = magic + Data.u32(chunk) + prefix
        let n = max(1, (plaintext.count + chunk - 1) / chunk)
        for i in 0..<n {
            let s = plaintext.startIndex + i * chunk
            let part = plaintext[s..<min(s + chunk, plaintext.endIndex)]
            out += try seal(key, prefix, i, i == n - 1, Data(part))
        }
        return out
    }

    public static func isChunked(_ head: Data) -> Bool { head.count >= 4 && head.prefix(4) == magic }

    // MARK: -
    private static func decrypt(reader: ByteReader, key: Data, sink: (Data) -> Void) throws {
        let header = try reader.read(16)
        guard header.count == 16 else { throw Failure.truncated }
        guard header.prefix(4) == magic else { throw Failure.notChunked }
        let b = [UInt8](header)
        let size = Int(b[4]) << 24 | Int(b[5]) << 16 | Int(b[6]) << 8 | Int(b[7])
        guard size > 0, size <= maxChunk else { throw Failure.badChunkSize }
        let prefix = Data(b[8..<16])
        var index = 0
        var cur = try reader.read(size + tag)
        guard cur.count >= tag else { throw Failure.truncated }
        while true {
            let next = cur.count == size + tag ? try reader.read(size + tag) : Data()
            let final = next.isEmpty
            sink(try open(key, prefix, index, final, cur))
            if final { return }
            guard next.count >= tag else { throw Failure.truncated }
            cur = next
            index += 1
        }
    }

    private static func nonceAad(_ prefix: Data, _ i: Int, _ final: Bool) throws -> (AES.GCM.Nonce, Data) {
        let idx = Data.u32(i)
        return (try AES.GCM.Nonce(data: prefix + idx), idx + Data([final ? 1 : 0]))
    }

    static func seal(_ key: Data, _ prefix: Data, _ i: Int, _ final: Bool, _ pt: Data) throws -> Data {
        let (nonce, aad) = try nonceAad(prefix, i, final)
        let box = try AES.GCM.seal(pt, using: SymmetricKey(data: key), nonce: nonce, authenticating: aad)
        return box.ciphertext + box.tag
    }

    static func open(_ key: Data, _ prefix: Data, _ i: Int, _ final: Bool, _ ctAndTag: Data) throws -> Data {
        let (nonce, aad) = try nonceAad(prefix, i, final)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ctAndTag.prefix(ctAndTag.count - tag), tag: ctAndTag.suffix(tag))
        return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
    }

    private static func readUpTo(_ h: FileHandle, _ n: Int) throws -> Data {
        var out = Data()
        while out.count < n {
            guard let d = try h.read(upToCount: n - out.count), !d.isEmpty else { break }
            out += d
        }
        return out
    }
}

protocol ByteReader { func read(_ n: Int) throws -> Data }

final class FileReader: ByteReader {
    let h: FileHandle
    init(_ h: FileHandle) { self.h = h }
    func read(_ n: Int) throws -> Data {
        var out = Data()
        while out.count < n {
            guard let d = try h.read(upToCount: n - out.count), !d.isEmpty else { break }
            out += d
        }
        return out
    }
}

final class DataReader: ByteReader {
    let d: Data
    var pos: Int
    init(_ d: Data) { self.d = d; pos = d.startIndex }
    func read(_ n: Int) throws -> Data {
        let end = min(pos + n, d.endIndex)
        defer { pos = end }
        return Data(d[pos..<end])
    }
}
