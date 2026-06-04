import Foundation

struct CameraInspectionResult: Identifiable, Equatable {
    let id = UUID()
    let fileName: String
    let fileExtension: String
    let fileSizeBytes: Int
    let make: String?
    let model: String?
    let firmware: String?
    let lensModel: String?
    let serialNumber: String?
    let captureDate: String?
    let shutterCount: Int?
    let shutterCountSource: String?
    let fileTypeStatus: String
    let metadataStatus: String
    let warnings: [String]
    let rawBrand: CameraBrand

    var cameraDescription: String {
        let cleanedMake = Self.cleaned(make)
        let cleanedModel = Self.cleaned(model)
        switch (cleanedMake, cleanedModel) {
        case let (.some(make), .some(model)):
            if model.localizedCaseInsensitiveContains(make) { return model }
            return "\(make) \(model)"
        case let (.some(make), .none):
            return make
        case let (.none, .some(model)):
            return model
        default:
            return "Unknown camera"
        }
    }

    var lensDescription: String {
        Self.cleaned(lensModel) ?? "Unknown / not stored"
    }

    var firmwareDescription: String {
        Self.cleaned(firmware) ?? "Unknown / not stored"
    }

    var serialDescription: String {
        Self.cleaned(serialNumber) ?? "Unknown / not stored"
    }

    var dateDescription: String {
        Self.cleaned(captureDate) ?? "Unknown / not stored"
    }

    var shutterCountDescription: String {
        if let shutterCount { return "\(shutterCount)" }
        return "Unavailable"
    }

    var countLevelLabel: String {
        guard let shutterCount else { return "No count" }
        switch shutterCount {
        case 0...20: return "Very low"
        case 21...100: return "Low"
        case 101...999: return "Used"
        default: return "High"
        }
    }

    var verdict: String {
        guard let shutterCount else {
            switch rawBrand {
            case .canon, .sony:
                return "This file contains camera metadata, but this brand often does not expose a reliable shutter count in normal RAW EXIF data. Use the metadata fields as a condition report, not as shutter-count proof."
            case .nikon:
                return "Nikon shutter count was not found in this file. Some Nikon files expose it in MakerNote data, but not every file or model stores it in a readable way."
            case .fujifilm:
                return "Fujifilm Image Count was not found. Use an untouched RAF copied directly from the SD card."
            case .unknown:
                return "This file type or camera brand is not fully supported for shutter-count extraction."
            }
        }

        switch shutterCount {
        case 0...20:
            return "Very low count. This is normal for a new or almost-new camera, especially after factory testing and first setup."
        case 21...100:
            return "Low count. Still possible after factory or shop testing, but check the seller claim and packaging condition."
        case 101...999:
            return "Not a high professional count, but suspicious if the camera was sold as brand new and never used."
        default:
            return "High for a camera sold as brand new. Ask the seller for an explanation before accepting the purchase."
        }
    }

    var reportText: String {
        var lines: [String] = []
        lines.append("Camera RAW Inspection Report")
        lines.append("Generated locally on device")
        lines.append("")
        lines.append("File: \(fileName)")
        lines.append("File type: \(fileExtension.uppercased())")
        lines.append("File size: \(Self.formattedFileSize(fileSizeBytes))")
        lines.append("File verification: \(fileTypeStatus)")
        lines.append("Metadata status: \(metadataStatus)")
        lines.append("")
        lines.append("Camera model: \(cameraDescription)")
        lines.append("Brand: \(rawBrand.displayName)")
        lines.append("Serial number: \(serialDescription)")
        lines.append("Firmware/software: \(firmwareDescription)")
        lines.append("Lens used: \(lensDescription)")
        lines.append("Capture date: \(dateDescription)")
        lines.append("")
        lines.append("Shutter / image count: \(shutterCountDescription)")
        lines.append("Count source: \(shutterCountSource ?? "Not available")")
        lines.append("Interpretation: \(verdict)")
        if !warnings.isEmpty {
            lines.append("")
            lines.append("Warnings:")
            warnings.forEach { lines.append("- \($0)") }
        }
        lines.append("")
        lines.append("Privacy: processed locally. No upload, no analytics, no advertising.")
        lines.append("Legal: © 2026 Soroosh AGHAEI. All rights reserved. Independent utility; not affiliated with camera manufacturers.")
        return lines.joined(separator: "\n")
    }

    static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    static func formattedFileSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

enum CameraBrand: String, Equatable {
    case fujifilm
    case nikon
    case canon
    case sony
    case unknown

    var displayName: String {
        switch self {
        case .fujifilm: return "Fujifilm"
        case .nikon: return "Nikon"
        case .canon: return "Canon"
        case .sony: return "Sony"
        case .unknown: return "Unknown / unsupported"
        }
    }
}

enum RawMetadataInspectorError: LocalizedError, Equatable {
    case emptyFile
    case fileReadFailed

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "The selected file is empty."
        case .fileReadFailed:
            return "The selected file could not be read."
        }
    }
}

final class RawMetadataInspector {
    private enum ByteOrder {
        case little
        case big
    }

    private struct TIFFContext {
        let tiffBase: Int
        let byteOrder: ByteOrder
        let ifd0Offset: Int
        let sourceDescription: String
    }

    private struct IFDEntry {
        let tag: UInt16
        let type: UInt16
        let count: UInt32
        let valueOrOffset: UInt32
        let entryOffset: Int
    }

    static let supportedExtensions: Set<String> = ["raf", "nef", "nrw", "cr2", "cr3", "arw", "sr2", "srf"]

    static func inspect(data: Data, fileName: String) -> CameraInspectionResult {
        let fileExtension = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        let bytes = [UInt8](data)
        var warnings: [String] = []

        if bytes.isEmpty {
            return CameraInspectionResult(
                fileName: fileName,
                fileExtension: fileExtension,
                fileSizeBytes: 0,
                make: nil,
                model: nil,
                firmware: nil,
                lensModel: nil,
                serialNumber: nil,
                captureDate: nil,
                shutterCount: nil,
                shutterCountSource: nil,
                fileTypeStatus: "Empty file",
                metadataStatus: "No metadata",
                warnings: ["The file is empty."],
                rawBrand: .unknown
            )
        }

        let headerBrand = inferBrandFromHeader(bytes: bytes, fileExtension: fileExtension)
        let extensionSupported = supportedExtensions.contains(fileExtension)
        let fileTypeStatus: String
        if extensionSupported {
            fileTypeStatus = "Recognized RAW extension (.\(fileExtension.uppercased()))"
        } else {
            fileTypeStatus = "Unsupported or non-RAW extension (.\(fileExtension.uppercased()))"
            warnings.append("Use original RAW files. JPEG, PNG, HEIC, screenshots, and exported previews cannot be trusted for shutter-count checks.")
        }

        if data.count < 5_000_000 && extensionSupported {
            warnings.append("This file is unusually small for a RAW file. It may be a preview, converted file, or incomplete copy.")
        }

        guard let context = findTIFFContext(bytes) else {
            if fileExtension == "cr3" {
                warnings.append("CR3 support is limited. Some CR3 files keep EXIF in an ISO container that this lightweight parser may not fully decode.")
            } else {
                warnings.append("No readable TIFF/EXIF metadata block was found.")
            }
            return CameraInspectionResult(
                fileName: fileName,
                fileExtension: fileExtension,
                fileSizeBytes: data.count,
                make: nil,
                model: nil,
                firmware: nil,
                lensModel: nil,
                serialNumber: nil,
                captureDate: nil,
                shutterCount: nil,
                shutterCountSource: nil,
                fileTypeStatus: fileTypeStatus,
                metadataStatus: "No readable EXIF/TIFF metadata",
                warnings: warnings,
                rawBrand: headerBrand
            )
        }

        let ifd0 = parseIFD(bytes, tiffBase: context.tiffBase, relativeOffset: context.ifd0Offset, byteOrder: context.byteOrder)
        var make = asciiValue(bytes, entry: firstEntry(ifd0, tag: 0x010F), tiffBase: context.tiffBase, byteOrder: context.byteOrder)
        let model = asciiValue(bytes, entry: firstEntry(ifd0, tag: 0x0110), tiffBase: context.tiffBase, byteOrder: context.byteOrder)
        let firmware = asciiValue(bytes, entry: firstEntry(ifd0, tag: 0x0131), tiffBase: context.tiffBase, byteOrder: context.byteOrder)
        let dateTime = asciiValue(bytes, entry: firstEntry(ifd0, tag: 0x0132), tiffBase: context.tiffBase, byteOrder: context.byteOrder)

        var dateOriginal: String? = nil
        var lensModel: String? = nil
        var serialNumber: String? = nil
        var makerNoteStart: Int? = nil
        var makerNoteLength: Int = 0

        if let exifPointerEntry = firstEntry(ifd0, tag: 0x8769),
           let exifRelativeOffset = integerValue(bytes, entry: exifPointerEntry, tiffBase: context.tiffBase, byteOrder: context.byteOrder) {
            let exifIFD = parseIFD(bytes, tiffBase: context.tiffBase, relativeOffset: exifRelativeOffset, byteOrder: context.byteOrder)
            dateOriginal = asciiValue(bytes, entry: firstEntry(exifIFD, tag: 0x9003), tiffBase: context.tiffBase, byteOrder: context.byteOrder)
            lensModel = asciiValue(bytes, entry: firstEntry(exifIFD, tag: 0xA434), tiffBase: context.tiffBase, byteOrder: context.byteOrder)
            serialNumber = asciiValue(bytes, entry: firstEntry(exifIFD, tag: 0xA431), tiffBase: context.tiffBase, byteOrder: context.byteOrder)

            if let makerNoteEntry = firstEntry(exifIFD, tag: 0x927C),
               let start = valueDataOffset(entry: makerNoteEntry, tiffBase: context.tiffBase),
               start >= 0,
               start < bytes.count {
                makerNoteStart = start
                makerNoteLength = Int(makerNoteEntry.count)
            }
        } else {
            warnings.append("The EXIF IFD pointer was not found. Some camera details may be missing.")
        }

        if let makeValue = CameraInspectionResult.cleaned(make), makeValue.localizedCaseInsensitiveContains("FUJIFILM") {
            make = "FUJIFILM"
        }
        if let software = CameraInspectionResult.cleaned(firmware), looksEditedSoftware(software) {
            warnings.append("The software field mentions an editing/conversion application. Prefer a RAW copied directly from the SD card.")
        }

        let brand = inferBrand(make: make, fileExtension: fileExtension, headerBrand: headerBrand)
        var shutterCount: Int? = nil
        var shutterSource: String? = nil

        if let makerNoteStart {
            switch brand {
            case .fujifilm:
                if let count = parseFujifilmImageCount(bytes, makerNoteStart: makerNoteStart, makerNoteLength: makerNoteLength) {
                    shutterCount = count
                    shutterSource = "Fujifilm MakerNote tag 0x1438 / ImageCount"
                } else {
                    warnings.append("Fujifilm MakerNote was present, but Image Count tag 0x1438 was not found.")
                }
            case .nikon:
                if let count = parseNikonShutterCount(bytes, makerNoteStart: makerNoteStart, makerNoteLength: makerNoteLength) {
                    shutterCount = count
                    shutterSource = "Nikon MakerNote tag 0x00A7 / Shutter Count"
                } else {
                    warnings.append("Nikon MakerNote was present, but a readable shutter-count value was not found.")
                }
            case .canon:
                warnings.append("Canon shutter count is not reliably stored in normal RAW EXIF/MakerNote data for many models. Metadata report is available, but shutter count may require model-specific service data.")
            case .sony:
                warnings.append("Sony shutter count is not exposed consistently in ordinary RAW metadata. Metadata report is available, but shutter count may be unavailable for many ARW files.")
            case .unknown:
                warnings.append("Camera brand is not fully supported for shutter-count extraction.")
            }
        } else {
            warnings.append("MakerNote data was not found. Shutter count usually requires original MakerNote metadata.")
        }

        let metadataStatus = makerNoteStart == nil ? "EXIF found; MakerNote missing" : "EXIF and MakerNote found"

        return CameraInspectionResult(
            fileName: fileName,
            fileExtension: fileExtension,
            fileSizeBytes: data.count,
            make: make,
            model: model,
            firmware: firmware,
            lensModel: lensModel,
            serialNumber: serialNumber,
            captureDate: dateOriginal ?? dateTime,
            shutterCount: shutterCount,
            shutterCountSource: shutterSource,
            fileTypeStatus: fileTypeStatus,
            metadataStatus: metadataStatus,
            warnings: uniqueWarnings(warnings),
            rawBrand: brand
        )
    }

    private static func uniqueWarnings(_ warnings: [String]) -> [String] {
        var seen = Set<String>()
        return warnings.filter { seen.insert($0).inserted }
    }

    private static func looksEditedSoftware(_ software: String) -> Bool {
        let editedWords = ["adobe", "lightroom", "photoshop", "capture one", "affinity", "dxo", "on1", "pixelmator", "darktable", "rawtherapee"]
        let lower = software.lowercased()
        return editedWords.contains { lower.contains($0) }
    }

    private static func inferBrand(make: String?, fileExtension: String, headerBrand: CameraBrand) -> CameraBrand {
        if let make = CameraInspectionResult.cleaned(make)?.lowercased() {
            if make.contains("fujifilm") || make.contains("fuji") { return .fujifilm }
            if make.contains("nikon") { return .nikon }
            if make.contains("canon") { return .canon }
            if make.contains("sony") { return .sony }
        }

        if headerBrand != .unknown { return headerBrand }

        switch fileExtension {
        case "raf": return .fujifilm
        case "nef", "nrw": return .nikon
        case "cr2", "cr3": return .canon
        case "arw", "sr2", "srf": return .sony
        default: return .unknown
        }
    }

    private static func inferBrandFromHeader(bytes: [UInt8], fileExtension: String) -> CameraBrand {
        let header = String(bytes: bytes.prefix(16), encoding: .ascii) ?? ""
        if header.contains("FUJIFILM") { return .fujifilm }
        switch fileExtension {
        case "raf": return .fujifilm
        case "nef", "nrw": return .nikon
        case "cr2", "cr3": return .canon
        case "arw", "sr2", "srf": return .sony
        default: return .unknown
        }
    }

    private static func findTIFFContext(_ bytes: [UInt8]) -> TIFFContext? {
        if let context = tiffContextAt(bytes, offset: 0, sourceDescription: "File header TIFF") {
            return context
        }

        if let exifMarker = find(bytes, pattern: [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]) {
            let tiffBase = exifMarker + 6
            return tiffContextAt(bytes, offset: tiffBase, sourceDescription: "Embedded EXIF TIFF")
        }

        return nil
    }

    private static func tiffContextAt(_ bytes: [UInt8], offset: Int, sourceDescription: String) -> TIFFContext? {
        guard offset >= 0, offset + 8 <= bytes.count else { return nil }
        let byteOrder: ByteOrder
        if bytes[offset] == 0x49 && bytes[offset + 1] == 0x49 {
            byteOrder = .little
        } else if bytes[offset] == 0x4D && bytes[offset + 1] == 0x4D {
            byteOrder = .big
        } else {
            return nil
        }

        guard readUInt16(bytes, offset + 2, byteOrder) == 42,
              let ifdOffset = readUInt32(bytes, offset + 4, byteOrder) else {
            return nil
        }
        let ifd0Offset = Int(ifdOffset)
        guard ifd0Offset > 0, offset + ifd0Offset < bytes.count else { return nil }
        return TIFFContext(tiffBase: offset, byteOrder: byteOrder, ifd0Offset: ifd0Offset, sourceDescription: sourceDescription)
    }

    private static func parseFujifilmImageCount(_ bytes: [UInt8], makerNoteStart: Int, makerNoteLength: Int) -> Int? {
        let header = [UInt8]("FUJIFILM".utf8)
        guard makerNoteStart + header.count + 4 < bytes.count else { return nil }
        guard Array(bytes[makerNoteStart..<(makerNoteStart + header.count)]) == header else { return nil }

        let maxMakerNoteEnd = makerNoteLength > 0 ? min(bytes.count, makerNoteStart + makerNoteLength) : bytes.count

        for order in [ByteOrder.little, ByteOrder.big] {
            let storedOffset = readUInt32(bytes, makerNoteStart + 8, order).map(Int.init) ?? 12
            let candidateOffsets = Array(Set([storedOffset, 12])).filter { $0 >= 0 }.sorted()

            for offset in candidateOffsets {
                let ifdStart = makerNoteStart + offset
                guard ifdStart + 2 <= maxMakerNoteEnd else { continue }
                guard let entryCount = readUInt16(bytes, ifdStart, order) else { continue }
                guard entryCount > 0 && entryCount < 300 else { continue }

                for index in 0..<Int(entryCount) {
                    let entryOffset = ifdStart + 2 + index * 12
                    guard entryOffset + 12 <= maxMakerNoteEnd else { break }
                    guard let tag = readUInt16(bytes, entryOffset, order), tag == 0x1438 else { continue }
                    guard let type = readUInt16(bytes, entryOffset + 2, order),
                          let count = readUInt32(bytes, entryOffset + 4, order) else { continue }

                    if type == 3 && count == 1, let value = readUInt16(bytes, entryOffset + 8, order) {
                        return Int(value)
                    }
                    if type == 4 && count == 1, let value = readUInt32(bytes, entryOffset + 8, order) {
                        return Int(value)
                    }
                    if let raw = makerNoteEntryValueBytes(bytes, entryOffset: entryOffset, makerNoteStart: makerNoteStart, maxMakerNoteEnd: maxMakerNoteEnd, order: order),
                       let string = String(bytes: raw, encoding: .ascii),
                       let parsed = Int(string.replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespacesAndNewlines)) {
                        return parsed
                    }
                }
            }
        }
        return nil
    }

    private static func parseNikonShutterCount(_ bytes: [UInt8], makerNoteStart: Int, makerNoteLength: Int) -> Int? {
        let makerEnd = makerNoteLength > 0 ? min(bytes.count, makerNoteStart + makerNoteLength) : bytes.count
        let searchEnd = min(makerEnd, makerNoteStart + 64)
        guard makerNoteStart < searchEnd else { return nil }

        for base in makerNoteStart..<searchEnd {
            guard let context = tiffContextAt(bytes, offset: base, sourceDescription: "Nikon MakerNote TIFF") else { continue }
            let entries = parseIFD(bytes, tiffBase: context.tiffBase, relativeOffset: context.ifd0Offset, byteOrder: context.byteOrder)
            if let entry = firstEntry(entries, tag: 0x00A7),
               let value = integerOrASCIIValue(bytes, entry: entry, tiffBase: context.tiffBase, byteOrder: context.byteOrder) {
                return value
            }
        }
        return nil
    }

    private static func makerNoteEntryValueBytes(_ bytes: [UInt8], entryOffset: Int, makerNoteStart: Int, maxMakerNoteEnd: Int, order: ByteOrder) -> [UInt8]? {
        guard let type = readUInt16(bytes, entryOffset + 2, order),
              let count = readUInt32(bytes, entryOffset + 4, order) else { return nil }
        let size = typeSize(type) * Int(count)
        guard size > 0 else { return nil }
        if size <= 4 {
            guard entryOffset + 8 + size <= bytes.count else { return nil }
            return Array(bytes[(entryOffset + 8)..<(entryOffset + 8 + size)])
        }
        guard let relative = readUInt32(bytes, entryOffset + 8, order) else { return nil }
        let start = makerNoteStart + Int(relative)
        guard start >= 0, start + size <= maxMakerNoteEnd else { return nil }
        return Array(bytes[start..<(start + size)])
    }

    private static func parseIFD(_ bytes: [UInt8], tiffBase: Int, relativeOffset: Int, byteOrder: ByteOrder) -> [IFDEntry] {
        let ifdStart = tiffBase + relativeOffset
        guard ifdStart >= 0,
              ifdStart + 2 <= bytes.count,
              let entryCount = readUInt16(bytes, ifdStart, byteOrder),
              entryCount < 2000 else { return [] }

        var entries: [IFDEntry] = []
        entries.reserveCapacity(Int(entryCount))
        for index in 0..<Int(entryCount) {
            let entryOffset = ifdStart + 2 + index * 12
            guard entryOffset + 12 <= bytes.count else { break }
            guard let tag = readUInt16(bytes, entryOffset, byteOrder),
                  let type = readUInt16(bytes, entryOffset + 2, byteOrder),
                  let count = readUInt32(bytes, entryOffset + 4, byteOrder),
                  let valueOrOffset = readUInt32(bytes, entryOffset + 8, byteOrder) else { continue }
            entries.append(IFDEntry(tag: tag, type: type, count: count, valueOrOffset: valueOrOffset, entryOffset: entryOffset))
        }
        return entries
    }

    private static func firstEntry(_ entries: [IFDEntry], tag: UInt16) -> IFDEntry? {
        entries.first { $0.tag == tag }
    }

    private static func asciiValue(_ bytes: [UInt8], entry: IFDEntry?, tiffBase: Int, byteOrder: ByteOrder) -> String? {
        guard let entry, entry.type == 2 else { return nil }
        guard let raw = entryValueBytes(bytes, entry: entry, tiffBase: tiffBase, byteOrder: byteOrder) else { return nil }
        return String(bytes: raw.prefix { $0 != 0 }, encoding: .utf8)
            ?? String(bytes: raw.prefix { $0 != 0 }, encoding: .ascii)
    }

    private static func integerValue(_ bytes: [UInt8], entry: IFDEntry, tiffBase: Int, byteOrder: ByteOrder) -> Int? {
        if let value = integerOrASCIIValue(bytes, entry: entry, tiffBase: tiffBase, byteOrder: byteOrder) {
            return value
        }
        return nil
    }

    private static func integerOrASCIIValue(_ bytes: [UInt8], entry: IFDEntry, tiffBase: Int, byteOrder: ByteOrder) -> Int? {
        if entry.type == 3 && entry.count == 1 {
            return readUInt16(bytes, entry.entryOffset + 8, byteOrder).map(Int.init)
        }
        if entry.type == 4 && entry.count == 1 {
            return readUInt32(bytes, entry.entryOffset + 8, byteOrder).map(Int.init)
        }
        if entry.type == 2,
           let raw = entryValueBytes(bytes, entry: entry, tiffBase: tiffBase, byteOrder: byteOrder),
           let string = String(bytes: raw, encoding: .ascii),
           let value = Int(string.replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespacesAndNewlines)) {
            return value
        }
        if let raw = entryValueBytes(bytes, entry: entry, tiffBase: tiffBase, byteOrder: byteOrder), raw.count <= 8 {
            let text = raw.map { String(format: "%02x", $0) }.joined()
            return Int(text, radix: 16)
        }
        return nil
    }

    private static func entryValueBytes(_ bytes: [UInt8], entry: IFDEntry, tiffBase: Int, byteOrder: ByteOrder) -> [UInt8]? {
        let size = typeSize(entry.type) * Int(entry.count)
        guard size > 0 else { return nil }
        if size <= 4 {
            guard entry.entryOffset + 8 + size <= bytes.count else { return nil }
            return Array(bytes[(entry.entryOffset + 8)..<(entry.entryOffset + 8 + size)])
        }
        guard let start = valueDataOffset(entry: entry, tiffBase: tiffBase), start + size <= bytes.count else { return nil }
        return Array(bytes[start..<(start + size)])
    }

    private static func valueDataOffset(entry: IFDEntry, tiffBase: Int) -> Int? {
        let size = typeSize(entry.type) * Int(entry.count)
        guard size > 4 else { return entry.entryOffset + 8 }
        return tiffBase + Int(entry.valueOrOffset)
    }

    private static func typeSize(_ type: UInt16) -> Int {
        switch type {
        case 1, 2, 6, 7: return 1
        case 3, 8: return 2
        case 4, 9, 11: return 4
        case 5, 10, 12: return 8
        default: return 0
        }
    }

    private static func find(_ bytes: [UInt8], pattern: [UInt8]) -> Int? {
        guard !pattern.isEmpty, bytes.count >= pattern.count else { return nil }
        let lastStart = bytes.count - pattern.count
        var index = 0
        while index <= lastStart {
            if bytes[index] == pattern[0] {
                var matched = true
                for patternIndex in 1..<pattern.count where bytes[index + patternIndex] != pattern[patternIndex] {
                    matched = false
                    break
                }
                if matched { return index }
            }
            index += 1
        }
        return nil
    }

    private static func readUInt16(_ bytes: [UInt8], _ offset: Int, _ order: ByteOrder) -> UInt16? {
        guard offset >= 0, offset + 1 < bytes.count else { return nil }
        let a = UInt16(bytes[offset])
        let b = UInt16(bytes[offset + 1])
        switch order {
        case .little: return a | (b << 8)
        case .big: return (a << 8) | b
        }
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int, _ order: ByteOrder) -> UInt32? {
        guard offset >= 0, offset + 3 < bytes.count else { return nil }
        let a = UInt32(bytes[offset])
        let b = UInt32(bytes[offset + 1])
        let c = UInt32(bytes[offset + 2])
        let d = UInt32(bytes[offset + 3])
        switch order {
        case .little: return a | (b << 8) | (c << 16) | (d << 24)
        case .big: return (a << 24) | (b << 16) | (c << 8) | d
        }
    }
}
