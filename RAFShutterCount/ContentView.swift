import SwiftUI
import UniformTypeIdentifiers
import UIKit
import PhotosUI

private extension UTType {
    static var cameraRawAny: UTType { UTType("public.camera-raw-image") ?? .data }
    static var fujifilmRAF: UTType { UTType("com.fujifilm.raf-raw-image") ?? UTType(filenameExtension: "raf") ?? .data }
    static var canonCR2: UTType { UTType(filenameExtension: "cr2") ?? .data }
    static var canonCR3: UTType { UTType(filenameExtension: "cr3") ?? .data }
    static var nikonNEF: UTType { UTType(filenameExtension: "nef") ?? .data }
    static var sonyARW: UTType { UTType(filenameExtension: "arw") ?? .data }
}

struct RootView: View {
    var body: some View {
        TabView {
            InspectorView()
                .tabItem { Label("Inspect", systemImage: "camera.viewfinder") }

            GuideView()
                .tabItem { Label("Guide", systemImage: "questionmark.circle") }

            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
    }
}

struct InspectorView: View {
    @State private var isImporting = false
    @State private var isPhotoImporting = false
    @State private var isReading = false
    @State private var results: [CameraInspectionResult] = []
    @State private var errorMessage: String?
    @State private var shareItem: ShareItem?
    @State private var copiedID: UUID?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HeaderCard()

                    ActionPanel(
                        isReading: isReading,
                        hasResults: !results.isEmpty,
                        onChooseFiles: {
                            errorMessage = nil
                            copiedID = nil
                            isImporting = true
                        },
                        onChoosePhotos: {
                            errorMessage = nil
                            copiedID = nil
                            isPhotoImporting = true
                        },
                        onClear: {
                            results.removeAll()
                            errorMessage = nil
                            copiedID = nil
                        },
                        onPDF: exportPDF,
                        onPNG: exportPNG
                    )

                    if isReading {
                        ReadingCard()
                    }

                    if let errorMessage {
                        ErrorCard(message: errorMessage)
                    }

                    if !results.isEmpty {
                        SummaryCard(results: results)

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Inspection Results")
                                .font(.title3.weight(.semibold))
                            ForEach(results) { result in
                                ResultCard(result: result, copied: copiedID == result.id) {
                                    UIPasteboard.general.string = result.reportText
                                    copiedID = result.id
                                }
                            }
                        }
                    }

                    LimitsCard()
                }
                .frame(maxWidth: 920, alignment: .center)
                .padding()
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("RAW Inspector")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $isPhotoImporting) {
                PhotoLibraryPicker { items in
                    handlePhotoImport(items)
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.fujifilmRAF, .nikonNEF, .canonCR2, .canonCR3, .sonyARW, .cameraRawAny, .data],
                allowsMultipleSelection: true
            ) { result in
                handleImport(result)
            }
            .sheet(item: $shareItem) { item in
                ShareSheet(items: [item.url])
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        errorMessage = nil
        copiedID = nil

        do {
            let urls = try result.get()
            guard !urls.isEmpty else { return }
            isReading = true

            DispatchQueue.global(qos: .userInitiated).async {
                var inspected: [CameraInspectionResult] = []
                var failures: [String] = []

                for url in urls {
                    let access = url.startAccessingSecurityScopedResource()
                    defer {
                        if access { url.stopAccessingSecurityScopedResource() }
                    }

                    do {
                        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                        let result = RawMetadataInspector.inspect(data: data, fileName: url.lastPathComponent)
                        inspected.append(result)
                    } catch {
                        failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }

                DispatchQueue.main.async {
                    self.results = inspected.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
                    self.errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
                    self.isReading = false
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            isReading = false
        }
    }

    private func handlePhotoImport(_ items: [PickedPhotoItem]) {
        errorMessage = nil
        copiedID = nil

        guard !items.isEmpty else { return }
        isReading = true

        let group = DispatchGroup()
        let lock = NSLock()
        var inspected: [CameraInspectionResult] = []
        var failures: [String] = []

        for (index, item) in items.enumerated() {
            group.enter()
            loadPhotoProvider(item.provider, index: index) { outcome in
                defer { group.leave() }
                switch outcome {
                case .success(let loaded):
                    let result = RawMetadataInspector.inspect(data: loaded.data, fileName: loaded.fileName)
                    lock.lock()
                    inspected.append(result)
                    if loaded.wasFallbackPreview {
                        failures.append("\(loaded.fileName): Photos provided an image preview/converted representation. For reliable shutter count, use the original RAW file from Files if metadata is missing.")
                    }
                    lock.unlock()
                case .failure(let error):
                    lock.lock()
                    failures.append("Photo \(index + 1): \(error.localizedDescription)")
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .main) {
            self.results = inspected.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
            self.errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
            self.isReading = false
        }
    }

    private func loadPhotoProvider(_ provider: NSItemProvider, index: Int, completion: @escaping (Result<LoadedPhotoFile, Error>) -> Void) {
        let typeIdentifier = Self.bestTypeIdentifier(from: provider.registeredTypeIdentifiers)
        let fileName = Self.fileName(for: provider, index: index, typeIdentifier: typeIdentifier)
        let wasFallbackPreview = Self.isLikelyPreviewType(typeIdentifier)

        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
            if let url {
                do {
                    let data = try Data(contentsOf: url)
                    completion(.success(LoadedPhotoFile(data: data, fileName: fileName, wasFallbackPreview: wasFallbackPreview)))
                } catch {
                    completion(.failure(error))
                }
                return
            }

            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, dataError in
                if let data, !data.isEmpty {
                    completion(.success(LoadedPhotoFile(data: data, fileName: fileName, wasFallbackPreview: true)))
                    return
                }
                completion(.failure(error ?? dataError ?? PhotoImportError.unreadablePhoto))
            }
        }
    }

    private static func bestTypeIdentifier(from identifiers: [String]) -> String {
        let lower = identifiers.map { ($0, $0.lowercased()) }
        let rawPriority = ["raf", "fujifilm", "fuji", "nef", "nikon", "cr3", "cr2", "canon", "arw", "sony", "dng", "raw", "camera-raw"]

        for key in rawPriority {
            if let match = lower.first(where: { $0.1.contains(key) })?.0 {
                return match
            }
        }

        if let image = identifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
            return image
        }

        return identifiers.first ?? UTType.image.identifier
    }

    private static func fileName(for provider: NSItemProvider, index: Int, typeIdentifier: String) -> String {
        let suggested = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (suggested?.isEmpty == false ? suggested! : "Photo_\(index + 1)")
        if !URL(fileURLWithPath: base).pathExtension.isEmpty { return base }
        let ext = fileExtension(for: typeIdentifier)
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    private static func fileExtension(for typeIdentifier: String) -> String {
        let lower = typeIdentifier.lowercased()
        if lower.contains("raf") || lower.contains("fuji") || lower.contains("fujifilm") { return "RAF" }
        if lower.contains("nef") || lower.contains("nikon") { return "NEF" }
        if lower.contains("cr3") { return "CR3" }
        if lower.contains("cr2") || lower.contains("canon") { return "CR2" }
        if lower.contains("arw") || lower.contains("sony") { return "ARW" }
        if lower.contains("dng") { return "DNG" }
        if lower.contains("heic") || lower.contains("heif") { return "HEIC" }
        if lower.contains("jpeg") || lower.contains("jpg") { return "JPG" }
        if lower.contains("png") { return "PNG" }
        return UTType(typeIdentifier)?.preferredFilenameExtension?.uppercased() ?? ""
    }

    private static func isLikelyPreviewType(_ typeIdentifier: String) -> Bool {
        let lower = typeIdentifier.lowercased()
        if lower.contains("raf") || lower.contains("nef") || lower.contains("cr2") || lower.contains("cr3") || lower.contains("arw") || lower.contains("dng") || lower.contains("raw") || lower.contains("camera-raw") {
            return false
        }
        return true
    }

    private func exportPDF() {
        do {
            shareItem = ShareItem(url: try ReportExporter.exportPDF(results: results))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func exportPNG() {
        do {
            shareItem = ShareItem(url: try ReportExporter.exportPNG(results: results))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct HeaderCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "camera.aperture")
                    .font(.system(size: 42, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Camera RAW Inspection")
                        .font(.title2.weight(.bold))
                    Text("Choose from Photos or Files, check Fujifilm RAF image count, read camera metadata, inspect multiple RAW files, and export a seller/buyer report. Files stay local on this device.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .cardStyle()
    }
}

private struct ActionPanel: View {
    let isReading: Bool
    let hasResults: Bool
    let onChooseFiles: () -> Void
    let onChoosePhotos: () -> Void
    let onClear: () -> Void
    let onPDF: () -> Void
    let onPNG: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 10) {
                Button(action: onChoosePhotos) {
                    Label(isReading ? "Reading Photos…" : "Choose from Photos", systemImage: "photo.on.rectangle")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isReading)
                .accessibilityHint("Choose images or RAW files from the Photos library. If Photos provides only a preview, use Files for the original RAW file.")

                Button(action: onChooseFiles) {
                    Label("Choose from Files", systemImage: "folder")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isReading)
                .accessibilityHint("Choose one or more original RAW files from the Files app. This is the most reliable method.")
            }

            Text("Photos is easier. Files is more reliable for untouched RAW files and shutter count metadata.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if hasResults {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        Button(action: onPDF) { Label("Export PDF", systemImage: "doc.richtext") }
                        Button(action: onPNG) { Label("Export PNG", systemImage: "photo") }
                        Button(role: .destructive, action: onClear) { Label("Clear", systemImage: "trash") }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Button(action: onPDF) { Label("Export PDF Report", systemImage: "doc.richtext") }
                        Button(action: onPNG) { Label("Export PNG Report", systemImage: "photo") }
                        Button(role: .destructive, action: onClear) { Label("Clear Results", systemImage: "trash") }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
        .cardStyle()
    }
}

private struct ReadingCard: View {
    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Reading RAW metadata locally…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

private struct SummaryCard: View {
    let results: [CameraInspectionResult]

    var readableCounts: Int { results.filter { $0.shutterCount != nil }.count }
    var warnings: Int { results.reduce(0) { $0 + $1.warnings.count } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Batch Summary")
                .font(.headline)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    StatBox(title: "Files", value: "\(results.count)")
                    StatBox(title: "Counts found", value: "\(readableCounts)")
                    StatBox(title: "Warnings", value: "\(warnings)")
                }
                VStack(spacing: 12) {
                    StatBox(title: "Files", value: "\(results.count)")
                    StatBox(title: "Counts found", value: "\(readableCounts)")
                    StatBox(title: "Warnings", value: "\(warnings)")
                }
            }
        }
        .cardStyle()
    }
}

private struct StatBox: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.bold))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct ResultCard: View {
    let result: CameraInspectionResult
    let copied: Bool
    let onCopy: () -> Void
    @State private var showDetails = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.fileName)
                        .font(.headline)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Text(result.rawBrand.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(result.countLevelLabel)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.thinMaterial)
                    .clipShape(Capsule())
            }

            HStack(alignment: .firstTextBaseline, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shutter / Image Count")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(result.shutterCountDescription)
                        .font(.system(size: result.shutterCount == nil ? 36 : 56, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.55)
                        .lineLimit(1)
                }
                Spacer()
            }

            Text(result.verdict)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            DisclosureGroup("Metadata", isExpanded: $showDetails) {
                VStack(spacing: 10) {
                    InfoRow(label: "Camera model", value: result.cameraDescription)
                    InfoRow(label: "Serial number", value: result.serialDescription)
                    InfoRow(label: "Firmware/software", value: result.firmwareDescription)
                    InfoRow(label: "Lens used", value: result.lensDescription)
                    InfoRow(label: "Capture date", value: result.dateDescription)
                    InfoRow(label: "File size", value: CameraInspectionResult.formattedFileSize(result.fileSizeBytes))
                    InfoRow(label: "File verification", value: result.fileTypeStatus)
                    InfoRow(label: "Metadata status", value: result.metadataStatus)
                    InfoRow(label: "Count source", value: result.shutterCountSource ?? "Not available")
                }
                .padding(.top, 8)
            }

            if !result.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Warnings", systemImage: "exclamationmark.triangle")
                        .font(.subheadline.weight(.semibold))
                    ForEach(result.warnings, id: \.self) { warning in
                        Text("• \(warning)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            Button(action: onCopy) {
                Label(copied ? "Copied Report Text" : "Copy Report Text", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .cardStyle()
    }
}

private struct ErrorCard: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Import problem", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            Text("Use original RAW files copied directly from the SD card or camera storage. Photos import is convenient, but if Photos provides only a preview, use Files. Avoid Lightroom exports, WhatsApp, Instagram, screenshots, and compressed previews.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle()
    }
}

private struct LimitsCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Important limits")
                .font(.headline)
            Text("Shutter count is brand-specific. Fujifilm RAF Image Count is read from MakerNote tag 0x1438. Nikon support is best-effort where MakerNote tag 0x00A7 is present. Canon and Sony files often do not expose a reliable count in ordinary RAW metadata, so the app still generates a metadata report but may show the count as unavailable.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("The number is useful for buying and selling checks, but it is not absolute forensic proof. Firmware changes, service events, and stripped metadata can affect stored values.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle()
    }
}

struct GuideView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GuideSection(title: "How to use", rows: [
                        "Choose from Photos for convenience, or choose from Files for the most reliable original RAW file access.",
                        "For Fujifilm, use untouched .RAF files copied directly from the SD card when possible.",
                        "For Nikon, Canon, and Sony, the app reads available camera metadata and tries shutter-count extraction where the file exposes it.",
                        "Export a PDF or PNG report when buying or selling a camera."
                    ])

                    GuideSection(title: "Report fields", rows: [
                        "Camera model and brand",
                        "Shutter/image count when available",
                        "Firmware/software field",
                        "Lens used when stored in EXIF",
                        "Serial number when stored in EXIF",
                        "File type verification and metadata warnings",
                        "Local-only processing note"
                    ])

                    GuideSection(title: "Good files", rows: [
                        "DSCF0002.RAF copied from SD card",
                        "Original .NEF, .CR2, .CR3, or .ARW copied as a file",
                        "Files opened from the Files app, not from Photos previews",
                        "RAW files stored in Photos, when Photos provides the original asset representation"
                    ])

                    GuideSection(title: "Bad files", rows: [
                        "JPEG, PNG, HEIC, screenshots, Instagram, WhatsApp, or compressed previews",
                        "Lightroom or Photoshop exports",
                        "Files where MakerNote metadata was stripped"
                    ])
                }
                .frame(maxWidth: 920, alignment: .center)
                .padding()
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Guide")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct GuideSection: View {
    let title: String
    let rows: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            ForEach(rows, id: \.self) { row in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                        .accessibilityHidden(true)
                    Text(row)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .cardStyle()
    }
}

struct AboutView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Camera RAW Inspector")
                            .font(.title2.weight(.bold))
                        Text("A local utility for camera RAW metadata checks, Fujifilm RAF Image Count inspection, batch reports, and seller/buyer verification documents.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .cardStyle()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Privacy")
                            .font(.headline)
                        Text("Files are processed locally on this iPhone or iPad. The app does not upload images, does not use analytics, does not use advertising, and does not collect personal data.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .cardStyle()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Current support")
                            .font(.headline)
                        Text("Fujifilm RAF shutter count is the primary supported function. Nikon shutter count is best-effort when MakerNote tag 0x00A7 is readable. Canon and Sony metadata is supported, but shutter count may be unavailable because many files do not expose it reliably.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .cardStyle()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Legal")
                            .font(.headline)
                        Text("© 2026 Soroosh AGHAEI. All rights reserved.")
                        Text("This app is an independent utility and is not affiliated with, endorsed by, or sponsored by Fujifilm, Canon, Nikon, Sony, or any camera manufacturer.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .cardStyle()
                }
                .frame(maxWidth: 920, alignment: .center)
                .padding()
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 16)
                Text(value)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .foregroundStyle(.secondary)
                Text(value)
                    .textSelection(.enabled)
            }
        }
        .font(.subheadline)
    }
}

private extension View {
    func cardStyle() -> some View {
        self
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(.secondary.opacity(0.12), lineWidth: 1)
            }
    }
}

struct PickedPhotoItem {
    let provider: NSItemProvider
}

struct LoadedPhotoFile {
    let data: Data
    let fileName: String
    let wasFallbackPreview: Bool
}

enum PhotoImportError: LocalizedError {
    case unreadablePhoto

    var errorDescription: String? {
        switch self {
        case .unreadablePhoto:
            return "The selected Photos item could not be read. Try importing the original RAW file through Files."
        }
    }
}

struct PhotoLibraryPicker: UIViewControllerRepresentable {
    let onPick: ([PickedPhotoItem]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 0
        configuration.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: ([PickedPhotoItem]) -> Void

        init(onPick: @escaping ([PickedPhotoItem]) -> Void) {
            self.onPick = onPick
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            onPick(results.map { PickedPhotoItem(provider: $0.itemProvider) })
        }
    }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

enum ReportExportError: LocalizedError {
    case noResults
    case pngCreationFailed

    var errorDescription: String? {
        switch self {
        case .noResults:
            return "There are no inspection results to export."
        case .pngCreationFailed:
            return "The PNG report could not be created."
        }
    }
}

enum ReportExporter {
    static func exportPDF(results: [CameraInspectionResult]) throws -> URL {
        guard !results.isEmpty else { throw ReportExportError.noResults }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Camera_RAW_Inspection_Report_\(timestamp()).pdf")
        let pageBounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: pageBounds, format: pdfFormat())

        try renderer.writePDF(to: url) { context in
            context.beginPage()
            fillPDFBackground(context, pageBounds: pageBounds)
            var y: CGFloat = 36
            let margin: CGFloat = 36
            let width = pageBounds.width - margin * 2

            draw("Camera RAW Inspection Report", at: &y, margin: margin, width: width, font: .boldSystemFont(ofSize: 22))
            draw("© 2026 Soroosh AGHAEI. All rights reserved.", at: &y, margin: margin, width: width, font: .systemFont(ofSize: 11))
            draw("Processed locally. No upload, no analytics, no advertising.", at: &y, margin: margin, width: width, font: .systemFont(ofSize: 11))
            y += 14

            for (index, result) in results.enumerated() {
                if y > pageBounds.height - 180 {
                    context.beginPage()
                    fillPDFBackground(context, pageBounds: pageBounds)
                    y = 36
                }
                draw("File \(index + 1): \(result.fileName)", at: &y, margin: margin, width: width, font: .boldSystemFont(ofSize: 15))
                for line in result.reportText.components(separatedBy: "\n").dropFirst(2) {
                    if y > pageBounds.height - 54 {
                        context.beginPage()
                        fillPDFBackground(context, pageBounds: pageBounds)
                        y = 36
                    }
                    draw(line, at: &y, margin: margin, width: width, font: .systemFont(ofSize: 10.5))
                }
                y += 16
            }
        }
        return url
    }

    static func exportPNG(results: [CameraInspectionResult]) throws -> URL {
        guard !results.isEmpty else { throw ReportExportError.noResults }
        let report = fullReportText(results: results)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Camera_RAW_Inspection_Report_\(timestamp()).png")
        let width: CGFloat = 1240
        let estimatedHeight = CGFloat(max(1754, report.components(separatedBy: "\n").count * 42 + 220))
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: estimatedHeight))
        let image = renderer.image { _ in
            UIColor.white.setFill()
            UIBezierPath(rect: CGRect(x: 0, y: 0, width: width, height: estimatedHeight)).fill()
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 24, weight: .regular),
                .foregroundColor: UIColor.black,
                .paragraphStyle: paragraph
            ]
            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 36),
                .foregroundColor: UIColor.black,
                .paragraphStyle: paragraph
            ]
            ("Camera RAW Inspection Report" as NSString).draw(in: CGRect(x: 64, y: 54, width: width - 128, height: 60), withAttributes: titleAttributes)
            (report as NSString).draw(in: CGRect(x: 64, y: 130, width: width - 128, height: estimatedHeight - 180), withAttributes: attributes)
        }
        guard let data = image.pngData() else { throw ReportExportError.pngCreationFailed }
        try data.write(to: url, options: [.atomic])
        return url
    }

    private static func fullReportText(results: [CameraInspectionResult]) -> String {
        var blocks: [String] = []
        blocks.append("© 2026 Soroosh AGHAEI. All rights reserved.")
        blocks.append("Processed locally. No upload, no analytics, no advertising.")
        blocks.append("")
        for result in results {
            blocks.append(result.reportText)
            blocks.append("----------------------------------------")
        }
        return blocks.joined(separator: "\n")
    }

    private static func fillPDFBackground(_ context: UIGraphicsPDFRendererContext, pageBounds: CGRect) {
        context.cgContext.setFillColor(UIColor.white.cgColor)
        context.cgContext.fill(pageBounds)
    }

    private static func draw(_ text: String, at y: inout CGFloat, margin: CGFloat, width: CGFloat, font: UIFont) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.black,
            .paragraphStyle: paragraph
        ]
        let rect = CGRect(x: margin, y: y, width: width, height: 400)
        let needed = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        ).height
        (text as NSString).draw(in: rect, withAttributes: attributes)
        y += ceil(needed) + 5
    }

    private static func pdfFormat() -> UIGraphicsPDFRendererFormat {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: "Camera RAW Inspection Report",
            kCGPDFContextAuthor as String: "Soroosh AGHAEI"
        ]
        return format
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }
}
