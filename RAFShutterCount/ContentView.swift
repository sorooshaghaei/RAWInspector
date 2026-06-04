import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UIKit
import PhotosUI


enum L10n {
    static func tr(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    static func tr(_ key: String, _ args: CVarArg...) -> String {
        String(format: NSLocalizedString(key, comment: ""), locale: Locale.current, arguments: args)
    }
}

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
                .tabItem { Label(L10n.tr("tab.inspect"), systemImage: "camera.viewfinder") }

            GuideView()
                .tabItem { Label(L10n.tr("tab.guide"), systemImage: "questionmark.circle") }

            AboutView()
                .tabItem { Label(L10n.tr("tab.about"), systemImage: "info.circle") }
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
                            Text(L10n.tr("result.inspection_results"))
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
            .navigationTitle(L10n.tr("app.title"))
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
                        failures.append(L10n.tr("photos.preview_warning", loaded.fileName))
                    }
                    lock.unlock()
                case .failure(let error):
                    lock.lock()
                    failures.append(L10n.tr("photos.error", index + 1, error.localizedDescription))
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
                    Text(L10n.tr("header.title"))
                        .font(.title2.weight(.bold))
                    Text(L10n.tr("header.subtitle"))
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
                    Label(isReading ? L10n.tr("status.reading_photos") : L10n.tr("button.choose_photos"), systemImage: "photo.on.rectangle")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isReading)
                .accessibilityHint(L10n.tr("hint.choose_photos"))

                Button(action: onChooseFiles) {
                    Label(L10n.tr("button.choose_files"), systemImage: "folder")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isReading)
                .accessibilityHint(L10n.tr("hint.choose_files"))
            }

            Text(L10n.tr("hint.photos_files"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if hasResults {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        Button(action: onPDF) { Label(L10n.tr("button.export_pdf"), systemImage: "doc.richtext") }
                        Button(action: onPNG) { Label(L10n.tr("button.export_png"), systemImage: "photo") }
                        Button(role: .destructive, action: onClear) { Label(L10n.tr("button.clear"), systemImage: "trash") }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Button(action: onPDF) { Label(L10n.tr("button.export_pdf_report"), systemImage: "doc.richtext") }
                        Button(action: onPNG) { Label(L10n.tr("button.export_png_report"), systemImage: "photo") }
                        Button(role: .destructive, action: onClear) { Label(L10n.tr("button.clear_results"), systemImage: "trash") }
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
            Text(L10n.tr("status.reading"))
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
            Text(L10n.tr("summary.title"))
                .font(.headline)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    StatBox(title: L10n.tr("summary.files"), value: "\(results.count)")
                    StatBox(title: L10n.tr("summary.counts_found"), value: "\(readableCounts)")
                    StatBox(title: L10n.tr("summary.warnings"), value: "\(warnings)")
                }
                VStack(spacing: 12) {
                    StatBox(title: L10n.tr("summary.files"), value: "\(results.count)")
                    StatBox(title: L10n.tr("summary.counts_found"), value: "\(readableCounts)")
                    StatBox(title: L10n.tr("summary.warnings"), value: "\(warnings)")
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
                    Text(L10n.tr("result.shutter_count"))
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

            DisclosureGroup(isExpanded: $showDetails) {
                VStack(spacing: 10) {
                    InfoRow(label: L10n.tr("result.camera_model"), value: result.cameraDescription)
                    InfoRow(label: L10n.tr("result.serial_number"), value: result.serialDescription)
                    InfoRow(label: L10n.tr("result.firmware"), value: result.firmwareDescription)
                    InfoRow(label: L10n.tr("result.lens"), value: result.lensDescription)
                    InfoRow(label: L10n.tr("result.capture_date"), value: result.dateDescription)
                    InfoRow(label: L10n.tr("result.file_size"), value: CameraInspectionResult.formattedFileSize(result.fileSizeBytes))
                    InfoRow(label: L10n.tr("result.file_verification"), value: result.fileTypeStatus)
                    InfoRow(label: L10n.tr("result.metadata_status"), value: result.metadataStatus)
                    InfoRow(label: L10n.tr("result.count_source"), value: result.shutterCountSource ?? L10n.tr("common.not_available"))
                }
                .padding(.top, 8)
            } label: {
                Text(L10n.tr("result.metadata"))
            }

            if !result.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label(L10n.tr("warning.title"), systemImage: "exclamationmark.triangle")
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
                Label(copied ? L10n.tr("result.copied_report") : L10n.tr("result.copy_report"), systemImage: copied ? "checkmark" : "doc.on.doc")
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
            Label(L10n.tr("error.import_problem"), systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.tr("error.import_help"))
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
            Text(L10n.tr("limits.title"))
                .font(.headline)
            Text(L10n.tr("limits.brand_specific"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.tr("limits.not_proof"))
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
                    GuideSection(title: L10n.tr("guide.how_to_use"), rows: [
                        L10n.tr("guide.how_to_use.1"),
                        L10n.tr("guide.how_to_use.2"),
                        L10n.tr("guide.how_to_use.3"),
                        L10n.tr("guide.how_to_use.4")
                    ])

                    GuideSection(title: L10n.tr("guide.report_fields"), rows: [
                        L10n.tr("guide.report_fields.1"),
                        L10n.tr("guide.report_fields.2"),
                        L10n.tr("guide.report_fields.3"),
                        L10n.tr("guide.report_fields.4"),
                        L10n.tr("guide.report_fields.5"),
                        L10n.tr("guide.report_fields.6"),
                        L10n.tr("guide.report_fields.7")
                    ])

                    GuideSection(title: L10n.tr("guide.good_files"), rows: [
                        L10n.tr("guide.good_files.1"),
                        L10n.tr("guide.good_files.2"),
                        L10n.tr("guide.good_files.3"),
                        L10n.tr("guide.good_files.4")
                    ])

                    GuideSection(title: L10n.tr("guide.bad_files"), rows: [
                        L10n.tr("guide.bad_files.1"),
                        L10n.tr("guide.bad_files.2"),
                        L10n.tr("guide.bad_files.3")
                    ])
                }
                .frame(maxWidth: 920, alignment: .center)
                .padding()
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(L10n.tr("guide.title"))
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
                        Text(L10n.tr("app.title"))
                            .font(.title2.weight(.bold))
                        Text(L10n.tr("about.subtitle"))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .cardStyle()

                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.tr("about.privacy"))
                            .font(.headline)
                        Text(L10n.tr("about.privacy_text"))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .cardStyle()

                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.tr("about.current_support"))
                            .font(.headline)
                        Text(L10n.tr("about.support_text"))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .cardStyle()

                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.tr("about.legal"))
                            .font(.headline)
                        Text(L10n.tr("legal.copyright"))
                        Text(L10n.tr("about.legal_text"))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .cardStyle()
                }
                .frame(maxWidth: 920, alignment: .center)
                .padding()
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(L10n.tr("about.title"))
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
            return L10n.tr("error.photo_unreadable")
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
            return L10n.tr("error.no_results")
        case .pngCreationFailed:
            return L10n.tr("error.png_failed")
        }
    }
}

enum ReportExporter {
    static func exportPDF(results: [CameraInspectionResult]) throws -> URL {
        guard !results.isEmpty else { throw ReportExportError.noResults }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RAW_Inspector_Report_\(timestamp()).pdf")
        let pageBounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: pageBounds, format: pdfFormat())

        try renderer.writePDF(to: url) { context in
            context.beginPage()
            fillPDFBackground(context, pageBounds: pageBounds)
            var y: CGFloat = 36
            let margin: CGFloat = 36
            let width = pageBounds.width - margin * 2

            draw(L10n.tr("report.title"), at: &y, margin: margin, width: width, font: .boldSystemFont(ofSize: 22))
            draw(L10n.tr("legal.copyright"), at: &y, margin: margin, width: width, font: .systemFont(ofSize: 11))
            draw(L10n.tr("privacy.local_short"), at: &y, margin: margin, width: width, font: .systemFont(ofSize: 11))
            y += 14

            for (index, result) in results.enumerated() {
                if y > pageBounds.height - 180 {
                    context.beginPage()
                    fillPDFBackground(context, pageBounds: pageBounds)
                    y = 36
                }
                draw(L10n.tr("report.file_number", index + 1, result.fileName), at: &y, margin: margin, width: width, font: .boldSystemFont(ofSize: 15))
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RAW_Inspector_Report_\(timestamp()).png")
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
            (L10n.tr("report.title") as NSString).draw(in: CGRect(x: 64, y: 54, width: width - 128, height: 60), withAttributes: titleAttributes)
            (report as NSString).draw(in: CGRect(x: 64, y: 130, width: width - 128, height: estimatedHeight - 180), withAttributes: attributes)
        }
        guard let data = image.pngData() else { throw ReportExportError.pngCreationFailed }
        try data.write(to: url, options: [.atomic])
        return url
    }

    private static func fullReportText(results: [CameraInspectionResult]) -> String {
        var blocks: [String] = []
        blocks.append(L10n.tr("legal.copyright"))
        blocks.append(L10n.tr("privacy.local_short"))
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
            kCGPDFContextTitle as String: L10n.tr("report.title"),
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
