import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ExportSheet: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var job: ExportJob
    @Binding var isPresented: Bool

    private var settings: ExportSettings { model.project.export }

    private func binding<T>(_ keyPath: WritableKeyPath<ExportSettings, T>) -> Binding<T> {
        Binding(get: { model.project.export[keyPath: keyPath] },
                set: { v in model.mutate("export") { $0.export[keyPath: keyPath] = v } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export").font(.title2.weight(.semibold))

            switch job.status {
            case .idle, .cancelled, .failed:
                form
                if case .failed(let message) = job.status {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                    Button("Export…") { chooseDestination() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            case .running:
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: job.progress)
                    Text("Rendering… \(Int(job.progress * 100))%").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Cancel export") { job.cancel() }
                }
            case .finished(let url):
                Label("Exported \(url.lastPathComponent)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(fileSize(url)).font(.callout).foregroundStyle(.secondary)
                SupportThankYouCard(visible: $job.reachedSupportMilestone)
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("Copy to clipboard") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([url as NSURL])
                    }
                    Button("Open") { NSWorkspace.shared.open(url) }
                    Spacer()
                    Button("Done") { isPresented = false }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 460)

    }

    private var form: some View {
        Form {
            Picker("Format", selection: binding(\.format)) {
                ForEach(ExportFormat.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            if settings.format == .gif {
                Picker("Frame rate", selection: binding(\.gifFps)) {
                    ForEach([10, 15, 20, 25, 30], id: \.self) { Text("\($0) fps").tag($0) }
                }
                Picker("Max width", selection: binding(\.gifMaxWidth)) {
                    ForEach([480, 640, 800, 960, 1280], id: \.self) { Text("\($0) px").tag($0) }
                }
            } else {
                Picker("Codec", selection: binding(\.codec)) {
                    ForEach(ExportCodec.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Resolution", selection: binding(\.resolution)) {
                    ForEach(ExportResolution.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Frame rate", selection: binding(\.fps)) {
                    ForEach([24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
                }
                if settings.codec != .prores {
                    Picker("Quality", selection: binding(\.quality)) {
                        ForEach(ExportQuality.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
            }
            LabeledContent("Output size") {
                Text(outputSizeLabel).monospacedDigit()
            }
            LabeledContent("Duration") {
                Text(formatTime(model.duration))
            }
        }
        .formStyle(.grouped)
    }

    private var outputSizeLabel: String {
        var size = model.renderState.canvasSize(shortSide: CGFloat(settings.resolution.shortSide))
        if settings.format == .gif, size.width > CGFloat(settings.gifMaxWidth) {
            let s = CGFloat(settings.gifMaxWidth) / size.width
            size = CGSize(width: size.width * s, height: size.height * s)
        }
        return "\(Int(size.width)) × \(Int(size.height))"
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        let ext = (settings.format == .mp4 && settings.codec == .prores) ? "mov" : settings.format.fileExtension
        panel.nameFieldStringValue = "\(model.project.name).\(ext)"
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .movie]
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.saveNow()
        job.start(state: model.renderState, settings: settings, destination: url)
    }

    private func fileSize(_ url: URL) -> String {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
