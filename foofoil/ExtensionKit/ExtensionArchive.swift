//  ExtensionArchive.swift
//  foofoil
//
//  Created by tolg on 2026/8/26.

import Compression
import Foundation
import FoofoilExtensionKit

struct ExtensionArchiveLimits: Equatable, Sendable {
    var maxFileCount: Int
    var maxFileSize: Int64
    var maxTotalSize: Int64

    static let `default` = ExtensionArchiveLimits(
        maxFileCount: 4_096,
        maxFileSize: 512 * 1024 * 1024,
        maxTotalSize: 1_024 * 1024 * 1024
    )
}

enum ExtensionArchiveError: LocalizedError, Equatable {
    case invalidArchive
    case unsupportedCompression
    case encryptedArchive
    case zip64Unsupported
    case pathEscape(String)
    case unsupportedEntry(String)
    case tooManyFiles
    case fileTooLarge
    case archiveTooLarge
    case checksumMismatch
    case missingBundle

    var errorDescription: String? {
        switch self {
        case .invalidArchive: "The extension archive is invalid."
        case .unsupportedCompression: "The extension archive uses unsupported compression."
        case .encryptedArchive: "Encrypted extension archives are not allowed."
        case .zip64Unsupported: "Zip64 extension archives are not supported."
        case .pathEscape(let name): "The extension archive contains an illegal path: \(name)."
        case .unsupportedEntry(let name): "The extension archive contains an unsupported entry: \(name)."
        case .tooManyFiles: "The extension archive contains too many files."
        case .fileTooLarge: "An extension archive file exceeds the size limit."
        case .archiveTooLarge: "The extracted extension archive exceeds the size limit."
        case .checksumMismatch: "The extension archive failed checksum verification."
        case .missingBundle: "The extension archive does not contain a foofoil extension bundle."
        }
    }
}

enum ExtensionArchive {
    private static let localFileHeader: UInt32 = 0x0403_4b50
    private static let centralDirectoryHeader: UInt32 = 0x0201_4b50
    private static let endOfCentralDirectory: UInt32 = 0x0605_4b50
    private static let zip64EndLocator: UInt32 = 0x0706_4b50
    private static let stored: UInt16 = 0
    private static let deflated: UInt16 = 8
    private static let unixSymlinkMask: UInt16 = 0o120000
    private static let unixTypeMask: UInt16 = 0o170000
    private static let unixRegularFile: UInt16 = 0o100000

    static func pack(files: [String: Data], validatePaths: Bool = true) throws -> Data {
        var localSection = Data()
        var centralSection = Data()
        let names = files.keys.sorted()
        for name in names {
            let payload = files[name]!
            if validatePaths {
                try validatePackPath(name)
            }
            let crc = crc32(payload)
            let localOffset = UInt32(localSection.count)
            appendUInt32(&localSection, localFileHeader)
            appendUInt16(&localSection, 20)
            appendUInt16(&localSection, 1 << 11) // UTF-8
            appendUInt16(&localSection, stored)
            appendUInt16(&localSection, 0)
            appendUInt16(&localSection, 0)
            appendUInt32(&localSection, crc)
            appendUInt32(&localSection, UInt32(payload.count))
            appendUInt32(&localSection, UInt32(payload.count))
            let nameData = Data(name.utf8)
            appendUInt16(&localSection, UInt16(nameData.count))
            appendUInt16(&localSection, 0)
            localSection.append(nameData)
            localSection.append(payload)

            appendUInt32(&centralSection, centralDirectoryHeader)
            appendUInt16(&centralSection, (3 << 8) | 20) // UNIX + version 2.0
            appendUInt16(&centralSection, 20)
            appendUInt16(&centralSection, 1 << 11)
            appendUInt16(&centralSection, stored)
            appendUInt16(&centralSection, 0)
            appendUInt16(&centralSection, 0)
            appendUInt32(&centralSection, crc)
            appendUInt32(&centralSection, UInt32(payload.count))
            appendUInt32(&centralSection, UInt32(payload.count))
            appendUInt16(&centralSection, UInt16(nameData.count))
            appendUInt16(&centralSection, 0)
            appendUInt16(&centralSection, 0)
            appendUInt16(&centralSection, 0)
            appendUInt16(&centralSection, 0)
            appendUInt32(&centralSection, UInt32(0o100644) << 16)
            appendUInt32(&centralSection, localOffset)
            centralSection.append(nameData)
        }

        var archive = localSection
        let centralOffset = UInt32(archive.count)
        archive.append(centralSection)
        appendUInt32(&archive, endOfCentralDirectory)
        appendUInt16(&archive, 0)
        appendUInt16(&archive, 0)
        appendUInt16(&archive, UInt16(names.count))
        appendUInt16(&archive, UInt16(names.count))
        appendUInt32(&archive, UInt32(centralSection.count))
        appendUInt32(&archive, centralOffset)
        appendUInt16(&archive, 0)
        return archive
    }

    /// 安全解压 ZIP：拒绝路径逃逸、符号链接、设备文件、加密、Zip64 和异常膨胀。
    @discardableResult
    static func extract(
        _ data: Data,
        to destination: URL,
        limits: ExtensionArchiveLimits = .default,
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let entries = try readEntries(from: data)
        guard entries.count <= limits.maxFileCount else { throw ExtensionArchiveError.tooManyFiles }

        var total: Int64 = 0
        for entry in entries {
            try validateExtractPath(entry.name)
            guard entry.compression == stored || entry.compression == deflated else {
                throw ExtensionArchiveError.unsupportedCompression
            }
            if entry.isEncrypted { throw ExtensionArchiveError.encryptedArchive }
            if entry.isZip64 { throw ExtensionArchiveError.zip64Unsupported }
            if !entry.isRegularFile { throw ExtensionArchiveError.unsupportedEntry(entry.name) }
            guard entry.uncompressedSize <= limits.maxFileSize else { throw ExtensionArchiveError.fileTooLarge }
            total += entry.uncompressedSize
            guard total <= limits.maxTotalSize else { throw ExtensionArchiveError.archiveTooLarge }

            let fileURL = destination.appendingPathComponent(entry.name)
            let parent = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            let payload = try decompress(entry, from: data)
            guard payload.count == entry.uncompressedSize,
                  crc32(payload) == entry.crc32 else {
                throw ExtensionArchiveError.checksumMismatch
            }
            try payload.write(to: fileURL, options: .atomic)
        }

        return try locateBundle(in: destination, fileManager: fileManager)
    }

    static func locateBundle(in directory: URL, fileManager: FileManager = .default) throws -> URL {
        if isExtensionBundle(directory) { return directory }
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let bundles = contents.filter { isExtensionBundle($0) }
        if bundles.count == 1 { return bundles[0] }
        if contents.count == 1, contents[0].hasDirectoryPath {
            return try locateBundle(in: contents[0], fileManager: fileManager)
        }
        throw ExtensionArchiveError.missingBundle
    }

    private static func isExtensionBundle(_ url: URL) -> Bool {
        let extensionName = url.pathExtension.lowercased()
        if extensionName == "foofoilextension" || extensionName == "bundle" { return true }
        let manifest = url
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("ExtensionManifest.json")
        return FileManager.default.fileExists(atPath: manifest.path)
    }

    private struct ZIPEntry {
        let name: String
        let compression: UInt16
        let crc32: UInt32
        let compressedSize: Int64
        let uncompressedSize: Int64
        let localHeaderOffset: Int
        let isEncrypted: Bool
        let isZip64: Bool
        let isRegularFile: Bool
    }

    private static func readEntries(from data: Data) throws -> [ZIPEntry] {
        guard let eocd = findEOCD(in: data) else { throw ExtensionArchiveError.invalidArchive }
        let diskNumber: UInt16 = try readUInt16(data, eocd)
        let startDisk: UInt16 = try readUInt16(data, eocd + 2)
        let entriesOnDisk: UInt16 = try readUInt16(data, eocd + 4)
        let totalEntries: UInt16 = try readUInt16(data, eocd + 6)
        let centralSize: UInt32 = try readUInt32(data, eocd + 8)
        let centralOffset: UInt32 = try readUInt32(data, eocd + 12)
        if diskNumber != 0 || startDisk != 0 || entriesOnDisk != totalEntries {
            throw ExtensionArchiveError.invalidArchive
        }
        if totalEntries == 0xFFFF || centralSize == 0xFFFF_FFFF || centralOffset == 0xFFFF_FFFF {
            throw ExtensionArchiveError.zip64Unsupported
        }
        // EOCD 起点是签名后 4 字节；Zip64 locator 紧挨在签名之前。
        if eocd >= 24 {
            let locatorSignature: UInt32 = (try? readUInt32(data, eocd - 24)) ?? 0
            if locatorSignature == zip64EndLocator {
                throw ExtensionArchiveError.zip64Unsupported
            }
        }

        var offset = Int(centralOffset)
        let centralEnd = offset + Int(centralSize)
        var entries: [ZIPEntry] = []
        for _ in 0..<totalEntries {
            guard offset + 46 <= centralEnd, offset + 46 <= data.count else {
                throw ExtensionArchiveError.invalidArchive
            }
            let signature: UInt32 = try readUInt32(data, offset)
            guard signature == centralDirectoryHeader else { throw ExtensionArchiveError.invalidArchive }
            let versionMadeBy: UInt16 = try readUInt16(data, offset + 4)
            let flags: UInt16 = try readUInt16(data, offset + 8)
            let compression: UInt16 = try readUInt16(data, offset + 10)
            let crc: UInt32 = try readUInt32(data, offset + 16)
            let compressedSize: UInt32 = try readUInt32(data, offset + 20)
            let uncompressedSize: UInt32 = try readUInt32(data, offset + 24)
            let nameLength: UInt16 = try readUInt16(data, offset + 28)
            let extraLength: UInt16 = try readUInt16(data, offset + 30)
            let commentLength: UInt16 = try readUInt16(data, offset + 32)
            let externalAttrs: UInt32 = try readUInt32(data, offset + 38)
            let localHeaderOffset: UInt32 = try readUInt32(data, offset + 42)
            let nameStart = offset + 46
            let nameEnd = nameStart + Int(nameLength)
            guard nameEnd <= data.count else { throw ExtensionArchiveError.invalidArchive }
            let name = String(data: data[nameStart..<nameEnd], encoding: .utf8) ?? ""
            let extraStart = nameEnd
            let extraEnd = extraStart + Int(extraLength)
            let extra = extraEnd <= data.count ? data[extraStart..<extraEnd] : Data()
            let isZip64 = uncompressedSize == 0xFFFF_FFFF
                || compressedSize == 0xFFFF_FFFF
                || localHeaderOffset == 0xFFFF_FFFF
                || extraContainsZip64(extra)
            let unixMode = UInt16((externalAttrs >> 16) & 0xFFFF)
            let unixType = unixMode & unixTypeMask
            let madeByUnix = (versionMadeBy >> 8) == 3
            let isDirectory = name.hasSuffix("/") || (externalAttrs & 0x10) != 0
            let isRegularFile = !isDirectory
                && (!madeByUnix || unixType == 0 || unixType == unixRegularFile)
                && unixType != unixSymlinkMask
            entries.append(
                ZIPEntry(
                    name: name,
                    compression: compression,
                    crc32: crc,
                    compressedSize: Int64(compressedSize),
                    uncompressedSize: Int64(uncompressedSize),
                    localHeaderOffset: Int(localHeaderOffset),
                    isEncrypted: (flags & 1) != 0,
                    isZip64: isZip64,
                    isRegularFile: isRegularFile
                )
            )
            offset = extraEnd + Int(commentLength)
        }
        return entries.filter { !$0.name.hasSuffix("/") }
    }

    private static func decompress(_ entry: ZIPEntry, from data: Data) throws -> Data {
        guard entry.localHeaderOffset + 30 <= data.count else { throw ExtensionArchiveError.invalidArchive }
        let signature: UInt32 = try readUInt32(data, entry.localHeaderOffset)
        guard signature == localFileHeader else { throw ExtensionArchiveError.invalidArchive }
        let nameLength: UInt16 = try readUInt16(data, entry.localHeaderOffset + 26)
        let extraLength: UInt16 = try readUInt16(data, entry.localHeaderOffset + 28)
        let dataStart = entry.localHeaderOffset + 30 + Int(nameLength) + Int(extraLength)
        let dataEnd = dataStart + Int(entry.compressedSize)
        guard dataEnd <= data.count else { throw ExtensionArchiveError.invalidArchive }
        let compressed = data[dataStart..<dataEnd]
        if entry.compression == stored {
            return Data(compressed)
        }
        return try inflate(Data(compressed), uncompressedSize: Int(entry.uncompressedSize))
    }

    private static func inflate(_ data: Data, uncompressedSize: Int) throws -> Data {
        var output = Data(count: uncompressedSize)
        let decodedCount = try output.withUnsafeMutableBytes { destination -> Int in
            try data.withUnsafeBytes { source -> Int in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else {
                    throw ExtensionArchiveError.invalidArchive
                }
                return compression_decode_buffer(
                    destinationBase,
                    uncompressedSize,
                    sourceBase,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard decodedCount == uncompressedSize else { throw ExtensionArchiveError.invalidArchive }
        return output
    }

    private static func findEOCD(in data: Data) -> Int? {
        let minimum = 22
        guard data.count >= minimum else { return nil }
        let maxScan = min(data.count - minimum + 1, 65_535 + 1)
        for offsetFromEnd in 0..<maxScan {
            let position = data.count - minimum - offsetFromEnd
            if let signature: UInt32 = try? readUInt32(data, position),
               signature == endOfCentralDirectory {
                if let commentLength: UInt16 = try? readUInt16(data, position + 20),
                   position + minimum + Int(commentLength) == data.count {
                    return position + 4
                }
            }
        }
        return nil
    }

    private static func extraContainsZip64(_ extra: Data) -> Bool {
        var offset = extra.startIndex
        while offset + 4 <= extra.endIndex {
            let headerID = UInt16(extra[offset]) | UInt16(extra[offset + 1]) << 8
            let size = Int(UInt16(extra[offset + 2]) | UInt16(extra[offset + 3]) << 8)
            if headerID == 0x0001 { return true }
            offset += 4 + size
        }
        return false
    }

    private static func validatePackPath(_ name: String) throws {
        try validateExtractPath(name)
    }

    private static func validateExtractPath(_ name: String) throws {
        guard !name.isEmpty else { throw ExtensionArchiveError.pathEscape(name) }
        if name.hasPrefix("/") || name.hasPrefix("\\") || name.contains(":") || name.contains("\0") {
            throw ExtensionArchiveError.pathEscape(name)
        }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.contains("..") || parts.contains("") {
            throw ExtensionArchiveError.pathEscape(name)
        }
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = crc32Table[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crc32Table: [UInt32] = {
        (0..<256).map { index in
            var crc = UInt32(index)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (0xEDB8_8320 ^ (crc >> 1)) : (crc >> 1)
            }
            return crc
        }
    }()

    private static func readUInt16(_ data: Data, _ offset: Int) throws -> UInt16 {
        guard offset + 2 <= data.count else { throw ExtensionArchiveError.invalidArchive }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func readUInt32(_ data: Data, _ offset: Int) throws -> UInt32 {
        guard offset + 4 <= data.count else { throw ExtensionArchiveError.invalidArchive }
        return UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }
}
