import Foundation

/// Independently implemented from SQLite's public WAL format:
/// https://www.sqlite.org/fileformat2.html#wal_format
/// Only a checksum-valid prefix ending in a commit can change the snapshot.
enum WALReplay {
    struct Frame {
        let pageNumber: UInt32
        let data: Data
    }
    struct Plan {
        let frames: [Frame]
        let databasePageCount: UInt32?
    }

    static func plan(_ input: Data, expectedPageSize: Int) throws -> Plan {
        let data = Data(input)
        if data.isEmpty { return Plan(frames: [], databasePageCount: nil) }
        guard data.count >= 32 else { throw DecryptorError.readFailed("Incomplete WAL header") }
        let magic = word(data, 0)
        guard magic == 0x377f0682 || magic == 0x377f0683,
              word(data, 4) == 3_007_000,
              Int(word(data, 8)) == expectedPageSize else {
            throw DecryptorError.readFailed("Unsupported WAL header or page size")
        }
        let littleEndian = magic == 0x377f0682
        var checksum = sum(data.subdata(in: 0..<24), seed: (0, 0), littleEndian: littleEndian)
        guard checksum.0 == word(data, 24), checksum.1 == word(data, 28) else {
            throw DecryptorError.readFailed("Invalid WAL header checksum")
        }
        let salt1 = word(data, 16), salt2 = word(data, 20)
        var frames: [Frame] = []
        var committedCount = 0
        var pageCount: UInt32?
        var offset = 32
        while offset + 24 + expectedPageSize <= data.count {
            let page = word(data, offset)
            guard page > 0, page < UInt32.max,
                  word(data, offset + 8) == salt1,
                  word(data, offset + 12) == salt2 else { break }
            let contents = data.subdata(in: offset + 24..<offset + 24 + expectedPageSize)
            var next = sum(data.subdata(in: offset..<offset + 8), seed: checksum, littleEndian: littleEndian)
            next = sum(contents, seed: next, littleEndian: littleEndian)
            guard next.0 == word(data, offset + 16), next.1 == word(data, offset + 20) else { break }
            checksum = next
            frames.append(Frame(pageNumber: page, data: contents))
            let committedPages = word(data, offset + 4)
            if committedPages > 0 {
                guard committedPages < UInt32.max else { break }
                committedCount = frames.count
                pageCount = committedPages
            }
            offset += 24 + expectedPageSize
        }
        return Plan(frames: Array(frames.prefix(committedCount)), databasePageCount: pageCount)
    }

    private static func word(_ data: Data, _ offset: Int, littleEndian: Bool = false) -> UInt32 {
        let bytes = data[offset..<offset + 4]
        return littleEndian
            ? bytes.reversed().reduce(0) { ($0 << 8) | UInt32($1) }
            : bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func sum(_ data: Data, seed: (UInt32, UInt32), littleEndian: Bool) -> (UInt32, UInt32) {
        var (s0, s1) = seed
        for offset in stride(from: 0, to: data.count, by: 8) {
            s0 = s0 &+ word(data, offset, littleEndian: littleEndian) &+ s1
            s1 = s1 &+ word(data, offset + 4, littleEndian: littleEndian) &+ s0
        }
        return (s0, s1)
    }
}
