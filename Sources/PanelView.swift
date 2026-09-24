import SwiftUI

/// 面板里的一行：开着的会话或历史会话。
enum Row: Identifiable {
    case live(LiveSession)
    case history(HistoryEntry)

    var id: String {
        switch self {
        case .live(let s): return "live:" + s.id
        case .history(let h): return "hist:" + h.id
        }
    }
}

struct PanelView: View {
    @ObservedObject var store: SessionStore
    @State private var query = ""
    @State private var selected: Int?
    @State private var editingId: String?
    @State private var editText = ""
    @State private var showAll = false
    @FocusState private var searchFocused: Bool
    @FocusState private var renameFocused: Bool

    private let recentLimit = 6

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) { content }
                        .padding(.horizontal, 5)
                        .padding(.bottom, 6)
                }
                .onChange(of: selected) { _, index in
                    if let index, index < rows.count { proxy.scrollTo(rows[index].id) }
                }
            }
            Divider()
            footer
        }
        .frame(width: 390, height: 560)
        .onChange(of: query) { _, q in
            selected = nil
            store.search(q)
        }
        .onChange(of: store.focusToken) { _, _ in
            editingId = nil
            searchFocused = true
        }
        .onAppear { searchFocused = true }
        .onExitCommand { if editingId == nil { store.closePanel?() } }
    }

    // MARK: - 数据

    private var liveRows: [LiveSession] {
        guard let matches = store.liveMatches else { return store.live }
        return store.live.filter { matches.contains($0.id) }
    }

    private var historyRows: [HistoryEntry] {
        if let results = store.results { return results }
        let liveIds = Set(store.live.map(\.id))
        let closed = store.history.filter { !liveIds.contains($0.id) }
        return showAll ? closed : Array(closed.prefix(recentLimit))
    }

    /// 键盘上下选择时用的扁平列表，顺序和界面一致。
    private var rows: [Row] {
        let live = liveRows
        return [LiveState.waiting, .busy, .idle].flatMap { state in live.filter { $0.state == state }.map(Row.live) }
            + historyRows.map(Row.history)
    }

    // MARK: - 视图

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
            TextField("搜索会话名或聊天内容", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { activate(selected ?? 0) }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
            } else {
                Text("⌥⌘K").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
        .padding(10)
    }

    /// 列表里的每一项（分组标题、会话行、分隔线、提示文字）拍平成一个数组，
    /// 用唯一 id 渲染；嵌套 ForEach 在会话跨组移动时会复用旧行，导致显示和点击错位。
    private enum Item: Identifiable {
        case header(LiveState, count: Int)
        case row(Row)
        case note(String)
        case divider
        case historyHeader

        var id: String {
            switch self {
            case .header(let state, _): return "header:\(state.rawValue)"
            case .row(let row): return row.id
            case .note(let text): return "note:" + text
            case .divider: return "divider"
            case .historyHeader: return "historyHeader"
            }
        }
    }

    private var items: [Item] {
        var items: [Item] = []
        let live = liveRows
        for state in [LiveState.waiting, .busy, .idle] {
            let group = live.filter { $0.state == state }
            guard !group.isEmpty else { continue }
            items.append(.header(state, count: group.count))
            items += group.map { .row(.live($0)) }
        }
        if live.isEmpty && store.results == nil { items.append(.note("现在没有开着的 Claude 会话")) }
        items += [.divider, .historyHeader]
        let history = historyRows
        if history.isEmpty {
            items.append(.note(store.indexing ? "正在建立历史索引…" : (store.results != nil ? "历史里没有匹配「\(query)」的会话" : "还没有历史会话")))
        }
        items += history.map { .row(.history($0)) }
        return items
    }

    @ViewBuilder
    private var content: some View {
        let flat = rows
        ForEach(items) { item in
            switch item {
            case .header(let state, let count):
                sectionHeader(title(of: state), count: count, color: color(of: state))
            case .row(let row):
                rowView(row, index: flat.firstIndex { $0.id == row.id })
            case .note(let text):
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
            case .divider:
                Divider().padding(.vertical, 6).padding(.horizontal, 6)
            case .historyHeader:
                historyHeader
            }
        }
    }

    private var historyHeader: some View {
        HStack {
            if store.results != nil {
                sectionLabel("历史中匹配", count: store.results?.count ?? 0)
            } else {
                sectionLabel("最近关闭的会话", count: store.history.filter { h in !store.live.contains { $0.id == h.id } }.count)
                Spacer()
                Button(showAll ? "收起" : "全部") { showAll.toggle() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color.accentColor)
                    .padding(.trailing, 9)
            }
        }
        .padding(.leading, 9).padding(.bottom, 2)
    }

    private func sectionHeader(_ title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            sectionLabel(title, count: count)
        }
        .padding(.leading, 9).padding(.top, 6).padding(.bottom, 2)
    }

    private func sectionLabel(_ title: String, count: Int) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.system(size: 11, weight: .semibold))
            Text("\(count)").font(.system(size: 11)).monospacedDigit()
        }
        .foregroundStyle(.secondary)
    }

    private func rowView(_ row: Row, index: Int?) -> some View {
        RowView(row: row, store: store, snippet: snippet(for: row), isSelected: index != nil && index == selected,
                isEditing: editingId == rowSessionId(row), editText: $editText, renameFocused: $renameFocused,
                onOpen: { open(row) },
                onRename: { startRename(row) },
                onCommitRename: { commitRename() },
                onCancelRename: { editingId = nil; searchFocused = true })
        }

    private var footer: some View {
        HStack(spacing: 4) {
            if let notice = store.notice {
                Text(notice).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                    .padding(.leading, 10)
                Spacer()
            } else {
                Text("\(store.live.count) 个开着 · \(store.history.count) 个历史")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.leading, 10)
                Spacer()
                Toggle("程序会话", isOn: $store.showProgrammatic)
                    .toggleStyle(.checkbox).font(.system(size: 11))
                    .help("显示 claude -p、飞书机器人等程序拉起的会话")
                Button("刷新") { store.refreshLive(); store.refreshHistory(); store.refreshBackground() }
                Button("退出") { NSApp.terminate(nil) }
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6).padding(.vertical, 8)
        .frame(minHeight: 34)
    }

    // MARK: - 行为

    private func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let next = (selected ?? -1) + delta
        selected = min(max(next, 0), rows.count - 1)
    }

    private func activate(_ index: Int) {
        guard index < rows.count else { return }
        open(rows[index])
    }

    private func open(_ row: Row) {
        switch row {
        case .live(let s): store.open(s)
        case .history(let h): store.open(h)
        }
    }

    private func rowSessionId(_ row: Row) -> String {
        switch row {
        case .live(let s): return s.id
        case .history(let h): return h.id
        }
    }

    private func startRename(_ row: Row) {
        switch row {
        case .live(let s): editText = s.name
        case .history(let h): editText = h.title
        }
        editingId = rowSessionId(row)
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename() {
        guard let id = editingId else { return }
        editingId = nil
        store.rename(id: id, to: editText)
        searchFocused = true
    }

    private func snippet(for row: Row) -> String? {
        guard case .history(let h) = row else { return nil }
        return store.snippets[h.id]
    }

    private func title(of state: LiveState) -> String {
        switch state {
        case .waiting: return "等你处理"
        case .busy: return "运行中"
        case .idle: return "空闲"
        }
    }

    private func color(of state: LiveState) -> Color {
        switch state {
        case .waiting: return .orange
        case .busy: return .blue
        case .idle: return .gray
        }
    }
}

struct RowView: View {
    let row: Row
    @ObservedObject var store: SessionStore
    let snippet: String?
    let isSelected: Bool
    let isEditing: Bool
    @Binding var editText: String
    var renameFocused: FocusState<Bool>.Binding
    let onOpen: () -> Void
    let onRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            statusDot.padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                nameLine
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(secondaryStyle).lineLimit(1).truncationMode(.middle)
                if let extra = extraLine {
                    Text(extra.text).font(.system(size: 11.5)).foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : extra.style)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if hovering && !isEditing {
                actions
            } else {
                Text(timeText).font(.system(size: 11)).foregroundStyle(secondaryStyle).padding(.top, 2)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(background))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if !isEditing { onOpen() } }
        .help(helpText)
    }

    // MARK: 内容

    @ViewBuilder
    private var nameLine: some View {
        if isEditing {
            TextField("新会话名", text: $editText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, weight: .medium))
                .focused(renameFocused)
                .onSubmit(onCommitRename)
                .onExitCommand(perform: onCancelRename)
        } else {
            HStack(spacing: 6) {
                Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if let tag = hostTag {
                    Text(tag).font(.system(size: 10)).foregroundStyle(secondaryStyle)
                        .padding(.horizontal, 4).padding(.vertical, 0.5)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.15)))
                }
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            iconButton("pencil", help: "改名", action: onRename)
            iconButton("folder", help: "在 Finder 中打开") { store.reveal(cwd) }
            iconButton("doc.on.doc", help: "复制恢复命令") {
                switch row {
                case .live(let s): store.copyResume(s)
                case .history(let h): store.copyResume(h)
                }
            }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11)).frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var statusDot: some View {
        Group {
            switch row {
            case .live(let s):
                switch s.state {
                case .waiting: Circle().fill(Color.orange)
                case .busy: Circle().fill(Color.blue)
                case .idle: Circle().strokeBorder(Color.gray, lineWidth: 1.5)
                }
            case .history:
                Circle().strokeBorder(Color.gray.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, dash: [2, 1.5]))
            }
        }
        .frame(width: 8, height: 8)
    }

    // MARK: 文案

    private var name: String {
        switch row {
        case .live(let s): return s.name
        case .history(let h): return h.title
        }
    }

    private var cwd: String {
        switch row {
        case .live(let s): return s.cwd
        case .history(let h): return h.cwd
        }
    }

    private var subtitle: String {
        let branch: String?
        switch row {
        case .live(let s): branch = s.branch
        case .history(let h): branch = h.branch.isEmpty ? nil : h.branch
        }
        var text = Format.shortDir(cwd)
        if let branch { text += " · ⎇ " + branch }
        if case .history(let h) = row, !h.cwd.isEmpty, !FileManager.default.fileExists(atPath: h.cwd) {
            text += " · 原目录已不存在"
        }
        return text
    }

    private var extraLine: (text: String, style: AnyShapeStyle)? {
        if let snippet { return (snippet, AnyShapeStyle(.secondary)) }
        guard case .live(let s) = row, let reason = s.waitingReason else { return nil }
        let reply = store.history.first(where: { $0.id == s.id })?.lastReply ?? ""
        return (reply.isEmpty ? reason : reason + " · " + reply, AnyShapeStyle(Color.orange))
    }

    private var hostTag: String? {
        guard case .live(let s) = row else { return nil }
        switch s.host {
        case .terminal(let tty): return tty == nil ? "无终端" : nil
        case .background: return "后台"
        case .desktop: return "桌面端"
        case .sdk: return "SDK"
        }
    }

    private var timeText: String {
        switch row {
        case .live(let s):
            let last = store.history.first(where: { $0.id == s.id })?.modifiedAt ?? s.updatedAt
            return Format.ago(max(last, s.updatedAt))
        case .history(let h): return Format.ago(h.modifiedAt)
        }
    }

    private var helpText: String {
        switch row {
        case .live(let s):
            var text = Format.tildePath(s.cwd)
            if case .terminal(let tty?) = s.host { text += "\n" + tty }
            return text
        case .history(let h): return Format.tildePath(h.cwd) + "\n\(h.turns) 轮对话 · " + h.id
        }
    }

    private var secondaryStyle: AnyShapeStyle {
        isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary)
    }

    private var background: Color {
        if isSelected { return .accentColor }
        return hovering ? Color.primary.opacity(0.06) : .clear
    }
}
