import SwiftUI

/// 新建会话表单：选文件夹、模型、可选的会话名，在 iTerm 新标签页里启动 claude。
struct NewSessionView: View {
    @ObservedObject var store: SessionStore
    let onClose: () -> Void

    /// 空字符串表示不传 --model，用 Claude Code 里配置的默认模型。
    private static let models: [(label: String, value: String)] = [
        ("默认", ""), ("opus", "opus"), ("sonnet", "sonnet"), ("fable", "fable"), ("haiku", "haiku"),
    ]

    @State private var folder = UserDefaults.standard.string(forKey: "newSession.folder") ?? ""
    @State private var model = UserDefaults.standard.string(forKey: "newSession.model") ?? ""
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button(action: onClose) { Image(systemName: "chevron.left") }.buttonStyle(.plain)
                Text("新建会话").font(.system(size: 14, weight: .semibold))
                Spacer()
            }

            field("文件夹") {
                Menu {
                    ForEach(folderChoices, id: \.self) { path in
                        Button(Format.tildePath(path)) { folder = path }
                    }
                    Divider()
                    Button("选择其他文件夹…", action: chooseFolder)
                } label: {
                    Text(folder.isEmpty ? "请选择" : Format.tildePath(folder)).lineLimit(1).truncationMode(.head)
                }
                if let branch = folder.isEmpty ? nil : Git.branch(at: folder) {
                    Text("⎇ " + branch).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            field("模型") {
                Picker("", selection: $model) {
                    ForEach(Self.models, id: \.value) { Text($0.label).tag($0.value) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            field("会话名称（选填）") {
                TextField("例如：滤网二维码过期时间", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit(create)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("将在 iTerm 新标签页执行：").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(command.isEmpty ? "—" : command)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            }

            Spacer()
            HStack {
                Spacer()
                Button("取消", action: onClose).keyboardShortcut(.cancelAction)
                Button("在 iTerm 中打开", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(folder.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 390, height: 560)
        .onAppear {
            if folder.isEmpty || !FileManager.default.fileExists(atPath: folder) { folder = folderChoices.first ?? "" }
            nameFocused = true
        }
    }

    private var folderChoices: [String] {
        var choices = store.recentFolders
        if !folder.isEmpty && !choices.contains(folder) { choices.insert(folder, at: 0) }
        return choices
    }

    private var command: String {
        guard !folder.isEmpty else { return "" }
        var parts = ["cd", Format.shellQuote(folder), "&&", "claude"]
        if !model.isEmpty { parts += ["--model", model] }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { parts += ["-n", Format.shellQuote(trimmed)] }
        return parts.joined(separator: " ")
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        if !folder.isEmpty { panel.directoryURL = URL(fileURLWithPath: folder) }
        // 面板是浮动层，选择框要比它高，否则会被挡在后面。
        panel.level = .modalPanel
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    private func create() {
        guard !folder.isEmpty else { return }
        UserDefaults.standard.set(folder, forKey: "newSession.folder")
        UserDefaults.standard.set(model, forKey: "newSession.model")
        store.launch(command)
        name = ""
        onClose()
    }
}
