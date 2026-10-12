import SwiftUI
import AVFoundation
import AppKit

struct ProjectSummary: Identifiable, Hashable {
    let folder: URL
    let name: String
    let date: Date
    let duration: Double
    var id: URL { folder }
}

@MainActor
final class ProjectLibrary: ObservableObject {
    @Published private(set) var projects: [ProjectSummary] = []
    @Published var search = ""

    func reload() {
        let root = AppSettings.shared.projectsFolder
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        projects = folders.compactMap { folder in
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(Project.fileName).path),
                  let project = try? Project.load(from: folder) else { return nil }
            let date = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? project.createdAt
            return ProjectSummary(folder: folder, name: project.name, date: date, duration: project.clipMap.outputDuration)
        }
        .sorted { $0.date > $1.date }
    }

    var filtered: [ProjectSummary] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return projects }
        return projects.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    func rename(_ project: ProjectSummary, to name: String) {
        guard var p = try? Project.load(from: project.folder) else { return }
        p.name = name
        try? p.save(to: project.folder)
        reload()
    }

    func duplicate(_ project: ProjectSummary) {
        let dest = project.folder.deletingLastPathComponent().appendingPathComponent(project.folder.lastPathComponent + " copy")
        try? FileManager.default.copyItem(at: project.folder, to: dest)
        if var p = try? Project.load(from: dest) {
            p.name += " copy"
            try? p.save(to: dest)
        }
        reload()
    }

    func moveToTrash(_ project: ProjectSummary) {
        ProjectLoader.evict(folder: project.folder)
        try? FileManager.default.trashItem(at: project.folder, resultingItemURL: nil)
        reload()
    }

    static func thumbnail(for folder: URL) async -> NSImage? {
        let thumbURL = folder.appendingPathComponent("thumbnail.jpg")
        if let image = NSImage(contentsOf: thumbURL) { return image }
        let asset = AVURLAsset(url: folder.appendingPathComponent("screen.mov"))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        guard let cg = try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        if let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.75]) {
            try? data.write(to: thumbURL)
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

struct ProjectsWindow: View {
    @StateObject private var library = ProjectLibrary()
    @Environment(\.openWindow) private var openWindow
    @State private var renaming: ProjectSummary?
    @State private var renameDraft = ""
    @State private var trashing: ProjectSummary?

    var body: some View {
        VStack(spacing: 0) {
            SupportBanner()
            if library.filtered.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "film.stack").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text(library.projects.isEmpty ? "No recordings yet" : "No matches").font(.headline)
                    Text("Recordings are saved to \(AppSettings.shared.projectsFolder.path)").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                        ForEach(library.filtered) { project in
                            ProjectCard(project: project)
                                .onTapGesture(count: 2) { openWindow(value: project.folder) }
                                .contextMenu {
                                    Button("Open") { openWindow(value: project.folder) }
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.folder]) }
                                    Button("Rename…") {
                                        renameDraft = project.name
                                        renaming = project
                                    }
                                    Button("Duplicate") { library.duplicate(project) }
                                    Divider()
                                    Button("Move to Trash", role: .destructive) { trashing = project }
                                }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 620, minHeight: 420)
        .navigationTitle("Recordings")
        .navigationSubtitle("\(library.projects.count) recordings")
        .searchable(text: $library.search, placement: .toolbar, prompt: "Search recordings")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    library.reload()
                } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Refresh")
                Button {
                    NSWorkspace.shared.open(AppSettings.shared.projectsFolder)
                } label: { Label("Show in Finder", systemImage: "folder") }
                    .help("Open the recordings folder in Finder")
            }
        }
        .onAppear { library.reload() }
        .alert("Rename recording", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameDraft)
            Button("Rename") {
                if let renaming { library.rename(renaming, to: renameDraft) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Move “\(trashing?.name ?? "")” to the Trash?", isPresented: Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let trashing { library.moveToTrash(trashing) }
                trashing = nil
            }
        } message: {
            Text("You can restore it from the Trash later.")
        }
    }
}

private struct ProjectCard: View {
    let project: ProjectSummary
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(Color.gray.opacity(0.25))
                    }
                }
                .frame(height: 130)
                .clipped()
                Text(formatTime(project.duration, tenths: false))
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(project.name).font(.callout.weight(.medium)).lineLimit(1)
            Text(project.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .task(id: project.folder) { thumbnail = await ProjectLibrary.thumbnail(for: project.folder) }
    }
}

/// The standard macOS Settings window (⌘,), with toolbar tabs.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            RecordingSettingsTab()
                .tabItem { Label("Recording", systemImage: "record.circle") }
            NewProjectSettingsTab()
                .tabItem { Label("New Projects", systemImage: "doc.badge.plus") }
            ShortcutsSettingsTab()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 540)
    }
}

private struct GeneralSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Projects folder") {
                    HStack {
                        Text(settings.projectsFolderPath).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Change…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.canCreateDirectories = true
                            if panel.runModal() == .OK, let url = panel.url { settings.projectsFolderPath = url.path }
                        }
                    }
                }
                Toggle("Show in Dock", isOn: $settings.showInDock)
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
            }
            UpdateSettingsSection()
            Section("Permissions") {
                Text("Screen Recording, Camera, Microphone, Accessibility (cursor tracking), Input Monitoring (keystrokes) and Speech Recognition (captions) are managed in System Settings.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Open Privacy & Security…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 500)
    }
}

private struct RecordingSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Capture") {
                Picker("Countdown", selection: $settings.countdownSeconds) {
                    Text("Off").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                }
                Picker("Frame rate", selection: $settings.recordingFps) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Toggle("High quality capture", isOn: $settings.highQualityCapture)
                    .help("Up to 4K with a higher bitrate")
                Toggle("Record keystrokes", isOn: $settings.recordKeystrokes)
                    .help("Needed for shortcut overlays")
                Toggle("Create automatic zooms from clicks", isOn: $settings.createAutomaticZooms)
            }
            Section("While recording") {
                Toggle("Hide desktop icons", isOn: $settings.hideDesktopIcons)
                Toggle("Hide Dock icon", isOn: $settings.hideDockIconWhileRecording)
                Toggle("Show recording controls", isOn: $settings.showRecordingWidget)
                Toggle("Show camera preview", isOn: $settings.showCameraPreview)
                Toggle("Play start and stop sounds", isOn: $settings.playRecordingSounds)
            }
            Section {
                Picker("After recording", selection: $settings.afterRecording) {
                    ForEach(AfterRecordingAction.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 520)
    }
}

private struct NewProjectSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var presets = PresetStore.names()

    var body: some View {
        Form {
            Section {
                Picker("Start with preset", selection: Binding(get: { settings.defaultPresetName ?? "" }, set: { settings.defaultPresetName = $0.isEmpty ? nil : $0 })) {
                    Text("Built-in defaults").tag("")
                    ForEach(presets, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Otherwise reuse the last edited project’s style", isOn: $settings.useLastStyleForNewProjects)
            } footer: {
                Text("Save presets from the Presets menu in the editor toolbar.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 200)
        .onAppear { presets = PresetStore.names() }
    }
}

private struct ShortcutsSettingsTab: View {
    var body: some View {
        Form {
            Section("Anywhere") {
                LabeledContent("Start / stop recording") { Text("⌥⇧⌘R").monospaced() }
                LabeledContent("Pause / resume recording") { Text("⌥⇧⌘P").monospaced() }
                LabeledContent("Cancel recording") { Text("⌥⇧⌘X").monospaced() }
            }
            Section("Editor") {
                LabeledContent("Play / pause") { Text("Space").monospaced() }
                LabeledContent("Split at playhead") { Text("⌘B").monospaced() }
                LabeledContent("Add zoom") { Text("⌥Z").monospaced() }
                LabeledContent("Delete selection") { Text("⌫").monospaced() }
                LabeledContent("Previous / next frame") { Text("← →").monospaced() }
                LabeledContent("Undo / redo") { Text("⌘Z  ⇧⌘Z").monospaced() }
                LabeledContent("Export") { Text("⌘E").monospaced() }
            }
        }
        .formStyle(.grouped)
        .frame(height: 440)
    }
}
