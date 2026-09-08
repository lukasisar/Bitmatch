import SwiftUI
import UniformTypeIdentifiers

/// One shared queue/history surface; choosing another card never mutates the active transfer.
struct TransferLibraryView: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @ObservedObject var journal: LocalTransferJournal
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var showAddTransfer = false
    @State private var showHistory = false
    @State private var errorMessage: String?
    @State private var exportDocument: TransferHistoryDocument?
    @State private var showExport = false
    @State private var exportType = UTType.json

    private var visibleRecords: [LocalTransferRecord] {
        journal.records.filter { record in
            let inSection = showHistory || [.queued, .running, .interrupted, .issues].contains(record.state)
            let haystack = [record.title, record.summary, record.reportSettings.projectName]
                + record.destinations.map { $0.url.lastPathComponent }
            return inSection && (search.isEmpty || haystack.joined(separator: " ").localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Transfers", selection: $showHistory) {
                        Text("Queue").tag(false)
                        Text("History").tag(true)
                    }.pickerStyle(.segmented)
                    TextField("Search cards, jobs, or backups", text: $search)
                        .textFieldStyle(.roundedBorder)
                    if let message = coordinator.queueMessage ?? journal.persistenceError ?? errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    if !showHistory {
                        HStack {
                            Button("Add transfer", systemImage: "plus") { showAddTransfer = true }
                            Spacer()
                            if coordinator.queueIsRunning {
                                Button("Stop after current") { coordinator.stopQueueAfterCurrentTransfer() }
                            } else {
                                Button("Run queue", systemImage: "play.fill") { coordinator.startQueue() }
                                    .disabled(journal.persistenceError != nil || !journal.records.contains { $0.state == .queued && $0.projectID == nil })
                            }
                        }
                        Text("Queued transfers keep their own folders and settings. The queue stops when a transfer needs attention.")
                            .font(.callout).foregroundStyle(.secondary)
                        #if os(iOS)
                        Text("Keep BitMatch open. If iOS interrupts a transfer, reconnect the original folders and retry here.")
                            .font(.callout).foregroundStyle(.secondary)
                        #endif
                    }
                    if visibleRecords.isEmpty {
                        ContentUnavailableView(showHistory ? "No transfer history" : "No queued transfers",
                                               systemImage: "tray", description: Text("Completed and interrupted transfers stay here for review."))
                    }
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(visibleRecords) { record in recordView(record) }
                    }
                }.padding()
            }
            .navigationTitle("Transfers")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showAddTransfer) { AddQueuedTransferView(coordinator: coordinator) }
            .fileExporter(isPresented: $showExport, document: exportDocument, contentType: exportType,
                          defaultFilename: "BitMatch-transfer") { result in
                if case .failure(let error) = result { errorMessage = error.localizedDescription }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 700, minHeight: 480, idealHeight: 650)
        #endif
    }

    private func recordView(_ record: LocalTransferRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.title).font(.headline).textSelection(.enabled)
                Spacer()
                Text(record.state.rawValue.capitalized).font(.subheadline)
                    .foregroundStyle(record.state == .completed ? Color.green : Color.secondary)
            }
            Text(record.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
            Text(record.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
            Text(record.destinations.map { $0.url.lastPathComponent }.joined(separator: " · "))
                .font(.callout).foregroundStyle(.secondary)
            Text("\(record.verificationMode.rawValue) · \(record.results.count) reported files")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if record.state == .queued {
                    Button("Remove from queue", role: .destructive) {
                        do { try journal.cancel(id: record.id, summary: "Removed from queue before copying.") }
                        catch { errorMessage = error.localizedDescription }
                    }
                } else if record.canRetry {
                    Button("Retry") { coordinator.retryTransfer(record.id) }
                }
                Spacer()
                if !record.results.isEmpty {
                    Menu("Export") {
                        Button("JSON report") { export(record, asCSV: false) }
                        Button("CSV results") { export(record, asCSV: true) }
                    }
                }
            }
            if record.projectID != nil && record.state != .completed {
                Text("Review this card in its project before preparing another ingest.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Details") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Source: \(record.source.url.path)").textSelection(.enabled)
                    ForEach(record.destinations.indices, id: \.self) { index in
                        Text("Backup: \(record.destinations[index].url.path)").textSelection(.enabled)
                    }
                    if record.canRetry && record.state != .queued && record.generateASCMHL {
                        Button("Retry without ASC MHL") {
                            coordinator.retryTransfer(record.id, generateASCMHL: false)
                        }
                        Text("Rechecks copies and retries unfinished work. Existing ASC MHL histories are preserved; this attempt won’t create new ones.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(record.results.prefix(100)) { row in
                        VStack(alignment: .leading) {
                            Text(row.fileName)
                            Text("\(row.destination ?? "Backup"): \(row.status)").foregroundStyle(.secondary)
                        }
                    }
                    if record.results.count > 100 { Text("Showing the first 100 files. Export includes every result.") }
                }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func export(_ record: LocalTransferRecord, asCSV: Bool) {
        do {
            exportDocument = try TransferHistoryDocument(record: record, asCSV: asCSV)
            exportType = asCSV ? .commaSeparatedText : .json
            showExport = true
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct AddQueuedTransferView: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var source: URL?
    @State private var destinations: [URL] = []
    @State private var mode = VerificationMode.standard
    @State private var generateASCMHL = true
    @State private var showSourcePicker = false
    @State private var showDestinationPicker = false
    @State private var scopedURLs: [URL] = []
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Source") {
                    if let source { Text(source.lastPathComponent).font(.headline) }
                    Button("Choose card or folder") { showSourcePicker = true }
                }
                Section("Backups") {
                    ForEach(destinations, id: \.self) { destination in
                        HStack {
                            Text(destination.lastPathComponent)
                            Spacer()
                            Button("Remove", role: .destructive) { destinations.removeAll { $0 == destination } }
                        }
                    }
                    Button("Add backup folder") { showDestinationPicker = true }
                }
                Section {
                    Text(verificationSummary)
                    DisclosureGroup("Advanced") {
                        Picker("Verification", selection: $mode) {
                            ForEach(VerificationMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Text(mode.description).font(.callout)
                        Toggle("ASC MHL handoff record", isOn: $generateASCMHL).disabled(mode == .quick)
                    }
                    Text("Creates a one-time transfer using the current report settings. Locations and free space are checked again before copying.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.orange) }
            }
            .formStyle(.grouped)
            .navigationTitle("Add transfer")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add to queue") { enqueue() }.disabled(source == nil || destinations.isEmpty)
                }
            }
            .fileImporter(isPresented: $showSourcePicker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                select(result, isSource: true)
            }
            .fileImporter(isPresented: $showDestinationPicker, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
                select(result, isSource: false)
            }
        }
        .onDisappear { scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 440)
        #endif
    }

    private var verificationSummary: String {
        switch mode {
        case .quick: return "Copy only · size check"
        case .standard: return "Verified copy · SHA-256"
        case .thorough: return "Verified copy · SHA-256 and MD5"
        case .paranoid: return "Verified copy · checksums and byte comparison"
        }
    }

    private func select(_ result: Result<[URL], Error>, isSource: Bool) {
        do {
            for url in try result.get() {
                if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
                if isSource { source = url }
                else if !destinations.contains(url) { destinations.append(url) }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func enqueue() {
        guard let source else { return }
        do {
            let settings = CameraLabelSettings()
            try SafetyValidator.validateResolvedDestinationRoots(source: source, destinations: destinations, settings: settings)
            try coordinator.transferJournal.enqueue(sourceURL: source, destinationURLs: destinations,
                verificationMode: mode, cameraSettings: settings, reportSettings: coordinator.reportSettings,
                generateASCMHL: generateASCMHL)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct TransferHistoryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText] }
    let data: Data
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }

    init(record: LocalTransferRecord, asCSV: Bool) throws {
        if asCSV {
            func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            let header = "source,destination,status,bytes,checksum,verification,transfer_state,transfer_summary\n"
            let rows = record.results.map { row in
                [row.path, row.destinationPath ?? row.destination ?? "", row.status, String(row.size), row.checksum ?? "",
                 record.verificationMode.rawValue, record.state.rawValue, record.summary].map(quote).joined(separator: ",")
            }
            data = Data((header + rows.joined(separator: "\n") + "\n").utf8)
        } else {
            // Do not export security-scoped bookmarks or credentials from the journal.
            struct Report: Encodable {
                let id: UUID
                let source: String
                let destinations: [String]
                let state: LocalTransferState
                let summary: String
                let createdAt: Date
                let verificationMode: VerificationMode
                let results: [ResultRow]
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            data = try encoder.encode(Report(id: record.id, source: record.source.url.path,
                destinations: record.destinations.map { $0.url.path }, state: record.state, summary: record.summary,
                createdAt: record.createdAt, verificationMode: record.verificationMode, results: record.results))
        }
    }
}
