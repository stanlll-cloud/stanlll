import SwiftUI
import AppKit

struct RecipeFile: Identifiable, Hashable {
    let url: URL
    var id: String { url.path }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var cameraVolume: URL?
    @Published var cameraRecipes: [RecipeFile] = []
    @Published var localRecipes: [RecipeFile] = []
    @Published var status = "Disconnected"

    let fm = FileManager.default
    let localDir: URL

    init() {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        localDir = base.appendingPathComponent("SonyRecipeStudio/Recipes", isDirectory: true)
        try? fm.createDirectory(at: localDir, withIntermediateDirectories: true)
        refreshLocal()
        scanForCamera()
    }

    func scanForCamera() {
        let volumes = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: [.volumeNameKey], options: [.skipsHiddenFiles])) ?? []
        var found: URL?
        for v in volumes {
            let recipes = v.appendingPathComponent("RECIPES", isDirectory: true)
            if fm.fileExists(atPath: recipes.path) {
                found = v
                break
            }
        }
        cameraVolume = found
        if let found {
            status = "Connected: \(found.lastPathComponent)"
            refreshCamera()
        } else {
            status = "No Sony camera storage found"
            cameraRecipes = []
        }
    }

    func refreshCamera() {
        guard let root = cameraVolume else { cameraRecipes = []; return }
        let dir = root.appendingPathComponent("RECIPES", isDirectory: true)
        cameraRecipes = listRecipes(in: dir)
    }

    func refreshLocal() { localRecipes = listRecipes(in: localDir) }

    private func listRecipes(in dir: URL) -> [RecipeFile] {
        let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return urls.filter { ["yml","yaml"].contains($0.pathExtension.lowercased()) }
            .map { RecipeFile(url: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func downloadFromCamera(_ recipe: RecipeFile) {
        let dst = uniqueDestination(in: localDir, preferredName: recipe.url.lastPathComponent)
        do {
            try fm.copyItem(at: recipe.url, to: dst)
            refreshLocal(); status = "Downloaded \(recipe.url.lastPathComponent)"
        } catch { status = "Download failed: \(error.localizedDescription)" }
    }

    func sendToCamera(_ recipe: RecipeFile) {
        guard let root = cameraVolume else { status = "Connect camera first"; return }
        let dir = root.appendingPathComponent("RECIPES", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let safe = cameraFilename(for: recipe.url.lastPathComponent)
            let dst = dir.appendingPathComponent(safe)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: recipe.url, to: dst)
            refreshCamera(); status = "Sent \(safe)"
        } catch { status = "Send failed: \(error.localizedDescription)" }
    }

    func importRecipe() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.allowedContentTypes = [.yaml, .plainText]
        guard p.runModal() == .OK else { return }
        for src in p.urls {
            let dst = uniqueDestination(in: localDir, preferredName: src.lastPathComponent)
            try? fm.copyItem(at: src, to: dst)
        }
        refreshLocal()
    }

    func exportRecipe(_ recipe: RecipeFile) {
        let p = NSSavePanel()
        p.nameFieldStringValue = recipe.url.lastPathComponent
        guard p.runModal() == .OK, let dst = p.url else { return }
        do {
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: recipe.url, to: dst)
            status = "Exported"
        } catch { status = "Export failed: \(error.localizedDescription)" }
    }

    func deleteLocal(_ recipe: RecipeFile) {
        try? fm.removeItem(at: recipe.url)
        refreshLocal()
    }

    private func uniqueDestination(in dir: URL, preferredName: String) -> URL {
        var out = dir.appendingPathComponent(preferredName)
        if !fm.fileExists(atPath: out.path) { return out }
        let stem = out.deletingPathExtension().lastPathComponent
        let ext = out.pathExtension
        var i = 2
        while fm.fileExists(atPath: out.path) {
            out = dir.appendingPathComponent("\(stem)-\(i).\(ext)")
            i += 1
        }
        return out
    }

    private func cameraFilename(for original: String) -> String {
        let stem = URL(fileURLWithPath: original).deletingPathExtension().lastPathComponent.uppercased()
        let allowed = stem.filter { $0.isLetter || $0.isNumber }
        let short = String(allowed.prefix(8))
        return "\(short.isEmpty ? "RECIPE" : short).YML"
    }
}

struct ContentView: View {
    @StateObject var model = AppModel()
    @State private var selectedCamera: RecipeFile?
    @State private var selectedLocal: RecipeFile?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sony Recipe Studio").font(.title2.bold())
                    Text(model.status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { model.scanForCamera() }
            }
            .padding()

            Divider()

            HSplitView {
                VStack(alignment: .leading) {
                    Text("Camera Recipes").font(.headline)
                    List(model.cameraRecipes, selection: $selectedCamera) { r in Text(r.name).tag(r) }
                    Button("Download") { if let r = selectedCamera { model.downloadFromCamera(r) } }
                        .disabled(selectedCamera == nil)
                }
                .padding()

                VStack(alignment: .leading) {
                    Text("Local Library").font(.headline)
                    List(model.localRecipes, selection: $selectedLocal) { r in Text(r.name).tag(r) }
                    HStack {
                        Button("Import") { model.importRecipe() }
                        Button("Export") { if let r = selectedLocal { model.exportRecipe(r) } }.disabled(selectedLocal == nil)
                        Button("Send to Camera") { if let r = selectedLocal { model.sendToCamera(r) } }.disabled(selectedLocal == nil || model.cameraVolume == nil)
                        Button("Delete") { if let r = selectedLocal { model.deleteLocal(r); selectedLocal = nil } }.disabled(selectedLocal == nil)
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 900, minHeight: 560)
    }
}

@main
struct SonyRecipeStudioApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
            .windowResizability(.contentMinSize)
    }
}