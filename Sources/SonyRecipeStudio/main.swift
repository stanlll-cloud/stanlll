import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RecipeFile: Identifiable, Hashable {
    let url: URL
    var id: String { url.path }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

struct RecipeDraft {
    var name = "新配方"
    var style = "standard"
    var saturation = "0"
    var contrast = "0"
    var sharpness = "0"
    var whiteBalance = "auto"
    var exposure = "0.0"

    func yaml() -> String {
        """
        name: "\(name)"
        style: \(style)
        saturation: \(saturation)
        contrast: \(contrast)
        sharpness: \(sharpness)
        white-balance: \(whiteBalance)
        exposure: \(exposure)
        """
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var cameraVolume: URL?
    @Published var cameraRecipes: [RecipeFile] = []
    @Published var localRecipes: [RecipeFile] = []
    @Published var status = "尚未连接相机"
    @Published var lastMessage = "请先连接 Sony 相机，并将 USB Connection 设置为 Mass Storage。"

    let fm = FileManager.default
    let localDir: URL

    init() {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        localDir = base.appendingPathComponent("SonyRecipeStudio/Recipes", isDirectory: true)
        try? fm.createDirectory(at: localDir, withIntermediateDirectories: true)
        refreshLocal()
        scanForCamera()
    }

    var isConnected: Bool { cameraVolume != nil }

    func scanForCamera() {
        let volumes = (try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Volumes"),
            includingPropertiesForKeys: [.volumeNameKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let candidates = volumes.filter { volume in
            let recipes = volume.appendingPathComponent("RECIPES", isDirectory: true)
            let dcim = volume.appendingPathComponent("DCIM", isDirectory: true)
            return fm.fileExists(atPath: recipes.path) || fm.fileExists(atPath: dcim.path)
        }

        if let found = candidates.first {
            connectToVolume(found)
        } else {
            cameraVolume = nil
            cameraRecipes = []
            status = "未检测到 Sony 相机"
            lastMessage = "相机开机后连接 USB，并把 USB Connection 设为 Mass Storage，然后点击“重新检测”。"
        }
    }

    func chooseCameraVolume() {
        let p = NSOpenPanel()
        p.title = "选择 Sony 相机 / 存储卡"
        p.prompt = "连接"
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.allowsMultipleSelection = false
        p.directoryURL = URL(fileURLWithPath: "/Volumes")
        guard p.runModal() == .OK, let url = p.url else { return }
        connectToVolume(url)
    }

    private func connectToVolume(_ url: URL) {
        cameraVolume = url
        let recipes = url.appendingPathComponent("RECIPES", isDirectory: true)
        if !fm.fileExists(atPath: recipes.path) {
            do {
                try fm.createDirectory(at: recipes, withIntermediateDirectories: true)
                lastMessage = "已连接 \(url.lastPathComponent)，并创建 RECIPES 文件夹。"
            } catch {
                lastMessage = "已连接 \(url.lastPathComponent)，但无法创建 RECIPES 文件夹。"
            }
        } else {
            lastMessage = "已连接 \(url.lastPathComponent)。"
        }
        status = "已连接：\(url.lastPathComponent)"
        refreshCamera()
    }

    func refreshCamera() {
        guard let root = cameraVolume else { cameraRecipes = []; return }
        cameraRecipes = listRecipes(in: root.appendingPathComponent("RECIPES", isDirectory: true))
    }

    func refreshLocal() { localRecipes = listRecipes(in: localDir) }

    private func listRecipes(in dir: URL) -> [RecipeFile] {
        let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { ["yml", "yaml"].contains($0.pathExtension.lowercased()) }
            .map { RecipeFile(url: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func downloadFromCamera(_ recipe: RecipeFile) {
        let dst = uniqueDestination(in: localDir, preferredName: recipe.url.lastPathComponent)
        do {
            try fm.copyItem(at: recipe.url, to: dst)
            refreshLocal()
            lastMessage = "已下载：\(recipe.url.lastPathComponent)"
        } catch {
            lastMessage = "下载失败：\(error.localizedDescription)"
        }
    }

    func downloadAllFromCamera() {
        guard !cameraRecipes.isEmpty else {
            lastMessage = "相机里没有找到配方文件。"
            return
        }
        var ok = 0
        for recipe in cameraRecipes {
            let dst = uniqueDestination(in: localDir, preferredName: recipe.url.lastPathComponent)
            if (try? fm.copyItem(at: recipe.url, to: dst)) != nil { ok += 1 }
        }
        refreshLocal()
        lastMessage = "已下载 \(ok) 个配方到 Mac。"
    }

    func sendToCamera(_ recipe: RecipeFile) {
        guard let root = cameraVolume else {
            lastMessage = "请先连接相机。"
            return
        }
        let dir = root.appendingPathComponent("RECIPES", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let safe = cameraFilename(for: recipe.url.lastPathComponent)
            let dst = dir.appendingPathComponent(safe)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: recipe.url, to: dst)
            refreshCamera()
            lastMessage = "已写入相机：\(safe)"
        } catch {
            lastMessage = "写入失败：\(error.localizedDescription)"
        }
    }

    func sendAllToCamera() {
        guard isConnected else {
            lastMessage = "请先连接相机。"
            return
        }
        for recipe in localRecipes { sendToCamera(recipe) }
        lastMessage = "本地配方已批量写入相机。"
    }

    func importRecipe() {
        let p = NSOpenPanel()
        p.title = "导入配方"
        p.allowsMultipleSelection = true
        p.allowedContentTypes = [.yaml, .plainText]
        guard p.runModal() == .OK else { return }
        var count = 0
        for src in p.urls {
            let dst = uniqueDestination(in: localDir, preferredName: src.lastPathComponent)
            if (try? fm.copyItem(at: src, to: dst)) != nil { count += 1 }
        }
        refreshLocal()
        lastMessage = "已导入 \(count) 个配方。"
    }

    func exportRecipe(_ recipe: RecipeFile) {
        let p = NSSavePanel()
        p.title = "导出配方"
        p.nameFieldStringValue = recipe.url.lastPathComponent
        guard p.runModal() == .OK, let dst = p.url else { return }
        do {
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: recipe.url, to: dst)
            lastMessage = "已导出配方。"
        } catch {
            lastMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    func deleteLocal(_ recipe: RecipeFile) {
        do {
            try fm.removeItem(at: recipe.url)
            refreshLocal()
            lastMessage = "已删除：\(recipe.name)"
        } catch {
            lastMessage = "删除失败：\(error.localizedDescription)"
        }
    }

    func openLocalFolder() {
        NSWorkspace.shared.open(localDir)
    }

    func readText(_ recipe: RecipeFile) -> String {
        (try? String(contentsOf: recipe.url, encoding: .utf8)) ?? ""
    }

    func saveText(_ text: String, to recipe: RecipeFile) {
        do {
            try text.write(to: recipe.url, atomically: true, encoding: .utf8)
            refreshLocal()
            lastMessage = "已保存修改：\(recipe.name)"
        } catch {
            lastMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    func createRecipe(_ draft: RecipeDraft) {
        let filename = cameraFilename(for: draft.name + ".YML")
        let dst = uniqueDestination(in: localDir, preferredName: filename)
        do {
            try draft.yaml().write(to: dst, atomically: true, encoding: .utf8)
            refreshLocal()
            lastMessage = "已新建配方：\(draft.name)"
        } catch {
            lastMessage = "新建失败：\(error.localizedDescription)"
        }
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

struct RecipeEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    let recipe: RecipeFile
    @State private var text: String

    init(model: AppModel, recipe: RecipeFile) {
        self.model = model
        self.recipe = recipe
        _text = State(initialValue: model.readText(recipe))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("编辑配方：\(recipe.name)").font(.title3.bold())
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 640, minHeight: 420)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    model.saveText(text, to: recipe)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

struct NewRecipeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    @State private var draft = RecipeDraft()

    var body: some View {
        Form {
            TextField("配方名称", text: $draft.name)
            TextField("Creative Style", text: $draft.style)
            TextField("Saturation", text: $draft.saturation)
            TextField("Contrast", text: $draft.contrast)
            TextField("Sharpness", text: $draft.sharpness)
            TextField("White Balance", text: $draft.whiteBalance)
            TextField("Exposure", text: $draft.exposure)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("创建") {
                    model.createRecipe(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

struct ContentView: View {
    @StateObject var model = AppModel()
    @State private var selectedCamera: RecipeFile?
    @State private var selectedLocal: RecipeFile?
    @State private var editingRecipe: RecipeFile?
    @State private var showNewRecipe = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            connectionGuide
            Divider()
            HSplitView {
                cameraPanel
                localPanel
            }
            Divider()
            footer
        }
        .frame(minWidth: 1050, minHeight: 680)
        .sheet(item: $editingRecipe) { recipe in
            RecipeEditorSheet(model: model, recipe: recipe)
        }
        .sheet(isPresented: $showNewRecipe) {
            NewRecipeSheet(model: model)
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sony Recipe Studio").font(.title.bold())
                Text("Sony 相机配方管理工具 · macOS")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(model.isConnected ? "相机已连接" : "相机未连接",
                  systemImage: model.isConnected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(model.isConnected ? .green : .orange)
            Button("重新检测") { model.scanForCamera() }
            Button("手动选择相机") { model.chooseCameraVolume() }
        }
        .padding(20)
    }

    private var connectionGuide: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("连接步骤").font(.headline)
                Text("1. 相机开机并插入存储卡")
                Text("2. 相机菜单：USB Connection → Mass Storage")
                Text("3. 用 USB 连接 Mac，然后点“重新检测”")
            }
            .font(.callout)

            Divider().frame(height: 72)

            VStack(alignment: .leading, spacing: 6) {
                Text("当前状态").font(.headline)
                Text(model.status)
                Text(model.lastMessage).foregroundStyle(.secondary)
            }
            .font(.callout)

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.quaternary.opacity(0.35))
    }

    private var cameraPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("相机里的配方", systemImage: "camera")
                    .font(.headline)
                Spacer()
                Text("\(model.cameraRecipes.count) 个")
                    .foregroundStyle(.secondary)
            }

            List(model.cameraRecipes, selection: $selectedCamera) { r in
                Text(r.name).tag(r)
            }
            .overlay {
                if model.cameraRecipes.isEmpty {
                    VStack(spacing: 10) {
                            Image(systemName: "camera").font(.system(size: 34)).foregroundStyle(.secondary)
                            Text(model.isConnected ? "相机里暂无配方" : "尚未连接相机").font(.headline)
                            Text(model.isConnected ? "可以把本地配方写入相机。" : "按上方步骤连接 Sony 相机。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                }
            }

            HStack {
                Button("下载选中配方") {
                    if let r = selectedCamera { model.downloadFromCamera(r) }
                }
                .disabled(selectedCamera == nil)

                Button("全部下载到 Mac") { model.downloadAllFromCamera() }
                    .disabled(!model.isConnected || model.cameraRecipes.isEmpty)

                Spacer()
            }
        }
        .padding(18)
        .frame(minWidth: 460)
    }

    private var localPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Mac 本地配方库", systemImage: "folder")
                    .font(.headline)
                Spacer()
                Text("\(model.localRecipes.count) 个")
                    .foregroundStyle(.secondary)
            }

            List(model.localRecipes, selection: $selectedLocal) { r in
                Text(r.name).tag(r)
            }
            .overlay {
                if model.localRecipes.isEmpty {
                    VStack(spacing: 10) {
                            Image(systemName: "square.and.arrow.down").font(.system(size: 34)).foregroundStyle(.secondary)
                            Text("本地配方库为空").font(.headline)
                            Text("可以从相机下载、导入 YML，或者新建一个配方。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                }
            }

            HStack(spacing: 8) {
                Button("导入 YML") { model.importRecipe() }
                Button("新建配方") { showNewRecipe = true }
                Button("编辑") {
                    if let r = selectedLocal { editingRecipe = r }
                }
                .disabled(selectedLocal == nil)

                Button("写入相机") {
                    if let r = selectedLocal { model.sendToCamera(r) }
                }
                .disabled(selectedLocal == nil || !model.isConnected)

                Button("全部写入相机") { model.sendAllToCamera() }
                    .disabled(!model.isConnected || model.localRecipes.isEmpty)

                Spacer()

                Button("导出") {
                    if let r = selectedLocal { model.exportRecipe(r) }
                }
                .disabled(selectedLocal == nil)

                Button("删除", role: .destructive) {
                    if let r = selectedLocal {
                        model.deleteLocal(r)
                        selectedLocal = nil
                    }
                }
                .disabled(selectedLocal == nil)
            }

            Button("打开本地配方文件夹") { model.openLocalFolder() }
                .buttonStyle(.link)
        }
        .padding(18)
        .frame(minWidth: 520)
    }

    private var footer: some View {
        HStack {
            Image(systemName: "info.circle")
            Text("Recipe 文件格式：YML。写入相机时会自动转换成最多 8 位文件名。")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

@main
struct SonyRecipeStudioApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentMinSize)
    }
}
