import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ThirdPartySourceManagerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = UnblockSourceStore.shared

    @State private var importMode: ThirdPartySourceImportMode = .paste
    @State private var importText = ""
    @State private var importURL = ""
    @State private var importStatus: String?
    @State private var showImportErrorAlert = false
    @State private var importErrorMessage = ""
    @State private var showFilePicker = false
    @State private var editingDraft: ThirdPartySourceDraft?

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack(spacing: 14) {
                    headerCard
                    importCard
                    sourceListCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .background(GlassBackdrop())
            .navigationTitle(atmusicLocalized("自定义音源", "Custom Sources"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(atmusicLocalized("完成", "Done")) { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        editingDraft = ThirdPartySourceDraft()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .sheet(item: $editingDraft) { draft in
            SourceEditorSheet(draft: draft) { updated in
                store.upsert(updated.toSource())
            }
        }
        .fullScreenCover(isPresented: $showFilePicker) {
            SourceDocumentPicker(
                onPick: { url in
                    showFilePicker = false
                    Task { await importFile(url) }
                },
                onCancel: {
                    showFilePicker = false
                }
            )
            .ignoresSafeArea()
        }
        .alert(atmusicLocalized("导入失败", "Import Failed"), isPresented: $showImportErrorAlert) {
            Button(atmusicLocalized("知道了", "OK"), role: .cancel) {}
        } message: {
            Text(importErrorMessage)
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(atmusicLocalized("导入与管理", "Import & Manage"))
                        .font(ATMusicFont.appFont(18, .bold))
                        .foregroundStyle(Color.atmusicLabel)
                    Text(atmusicLocalized("支持本地文件、远程 URL 和粘贴文本。", "Supports local files, remote URLs, and pasted text."))
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                    Text(atmusicLocalized("也支持 LX Music / BakaMusic 风格的 JS 音源脚本。", "Also supports LX Music / BakaMusic style JS source scripts."))
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                }
                Spacer()
                Button {
                    editingDraft = ThirdPartySourceDraft()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(width: 34, height: 34)
                        .background(Color.black, in: Circle())
                }
                .buttonStyle(GlassPressButtonStyle(scale: 0.95))
            }

            if let importStatus {
                Text(importStatus)
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicAmber)
                    .lineLimit(2)
            }
        }
        .padding(16)
        .background {
            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .atmusicCardShadow(radius: 8, y: 3)
    }

    private var importCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(atmusicLocalized("导入音源", "Import Sources"))
                    .font(ATMusicFont.appFont(15, .semibold))
                    .foregroundStyle(Color.atmusicLabel)
                Spacer()
                Picker("", selection: $importMode) {
                    ForEach(ThirdPartySourceImportMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }

            Group {
                switch importMode {
                case .paste:
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $importText)
                            .frame(minHeight: 150)
                            .padding(8)
                            .background(Color.clear)
                            .modifier(ScrollContentBackgroundHidden())
                        if importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(atmusicLocalized("粘贴 JSON / 配置 / 脚本内容", "Paste JSON / config / script text"))
                                .font(ATMusicFont.appFont(13))
                                .foregroundStyle(Color.atmusicComment.opacity(0.8))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 16)
                        }
                    }
                case .url:
                    VStack(alignment: .leading, spacing: 10) {
                        TextField(atmusicLocalized("输入远程音源地址", "Enter remote source URL"), text: $importURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .font(ATMusicFont.appFont(14))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous)) }
                        Button {
                            Task { await importRemoteURL() }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.down.circle.fill")
                                Text(atmusicLocalized("识别并导入", "Recognize & Import"))
                            }
                            .font(ATMusicFont.appFont(13, .semibold))
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.black, in: Capsule())
                        }
                        .buttonStyle(GlassPressButtonStyle(scale: 0.97))
                    }
                case .file:
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            showFilePicker = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.badge.plus")
                                Text(atmusicLocalized("选择本地文件", "Choose Local File"))
                            }
                            .font(ATMusicFont.appFont(13, .semibold))
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.black, in: Capsule())
                        }
                        .buttonStyle(GlassPressButtonStyle(scale: 0.97))
                        Text(atmusicLocalized("支持 JSON、JS、TXT 等文本文件。", "Supports JSON, JS, TXT and other text files."))
                            .font(ATMusicFont.appFont(12))
                            .foregroundStyle(Color.atmusicComment)
                    }
                }
            }

            if importMode != .url {
                Button {
                    Task { await importCurrentInput() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                        Text(atmusicLocalized("识别并导入", "Recognize & Import"))
                    }
                    .font(ATMusicFont.appFont(13, .semibold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.black, in: Capsule())
                }
                .buttonStyle(GlassPressButtonStyle(scale: 0.97))
            }

            Text(atmusicLocalized("支持 JSON 数组、单个配置、`SERVER_SCRIPT_CONFIG` 片段，以及 `@name` / `@template` 头部格式。", "Supports JSON arrays, single configs, `SERVER_SCRIPT_CONFIG` fragments, and `@name` / `@template` header-style blocks."))
                .font(ATMusicFont.appFont(11))
                .foregroundStyle(Color.atmusicComment)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background {
            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .atmusicCardShadow(radius: 8, y: 3)
    }

    private var sourceListCard: some View {
        let visibleSources = store.managementVisibleSources
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(atmusicLocalized("音源列表", "Source List"))
                    .font(ATMusicFont.appFont(15, .semibold))
                    .foregroundStyle(Color.atmusicLabel)
                Spacer()
                Text("\(visibleSources.count)")
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicComment)
            }

            if visibleSources.isEmpty {
                EmptyStateView(icon: "shippingbox.fill", text: atmusicLocalized("还没有音源，先导入一个吧。", "No sources yet. Import one first."))
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(visibleSources.enumerated()), id: \.element.id) { index, source in
                        SourceRow(
                            source: source,
                            canMoveUp: index > 0,
                            canMoveDown: index < visibleSources.count - 1,
                            onEdit: {
                                editingDraft = ThirdPartySourceDraft(source: source)
                            },
                            onRemove: {
                                if store.removeSource(id: source.id) {
                                    importStatus = atmusicLocalized("已删除音源：\(source.name)", "Deleted source: \(source.name)")
                                }
                            },
                            onMoveUp: {
                                store.moveManagementSource(id: source.id, by: -1)
                            },
                            onMoveDown: {
                                store.moveManagementSource(id: source.id, by: 1)
                            },
                            onToggle: { enabled in
                                store.updateEnabled(id: source.id, enabled: enabled)
                            }
                        )
                    }
                }
            }
        }
        .padding(16)
        .background {
            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .atmusicCardShadow(radius: 8, y: 3)
    }

    private func importCurrentInput() async {
        do {
            let sources = try ThirdPartySourceImportParser.parse(
                text: importText,
                fallbackName: atmusicLocalized("粘贴导入", "Pasted Import")
            )
            try await finishImport(sources)
        } catch {
            await showImportError(message: error.localizedDescription)
        }
    }

    private func importRemoteURL() async {
        let trimmed = importURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            await showImportError(message: ThirdPartySourceImportError.invalidURL.localizedDescription)
            return
        }
        do {
            let sources = try await ThirdPartySourceImportParser.fetch(url: url)
            try await finishImport(sources)
        } catch {
            await showImportError(message: error.localizedDescription)
        }
    }

    private func importFile(_ url: URL) async {
        do {
            let sources = try ThirdPartySourceImportParser.parse(fileURL: url)
            try await finishImport(sources)
        } catch {
            await showImportError(message: error.localizedDescription)
        }
    }

    private func finishImport(_ sources: [ThirdPartySource]) async throws {
        let normalized = sources.map { source in
            var updated = source
            updated.id = UUID().uuidString
            return updated
        }
        guard !normalized.isEmpty else {
            throw ThirdPartySourceImportError.noValidSource
        }
        await MainActor.run {
            store.addSources(normalized)
            importStatus = atmusicLocalized("已导入 \(normalized.count) 个音源", "Imported \(normalized.count) sources")
            importText = ""
            if importMode == .url { importURL = "" }
            ATMusicHaptics.success()
        }
    }

    @MainActor
    private func showImportError(message: String) {
        importErrorMessage = message
        showImportErrorAlert = true
    }
}

private enum ThirdPartySourceImportMode: String, CaseIterable, Identifiable {
    case paste
    case url
    case file

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paste: return atmusicLocalized("文本", "Text")
        case .url: return atmusicLocalized("链接", "URL")
        case .file: return atmusicLocalized("文件", "File")
        }
    }
}

private struct SourceRow: View {
    let source: ThirdPartySource
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onEdit: () -> Void
    let onRemove: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onToggle: (Bool) -> Void

    private var subtitle: String {
        let platform = source.headers["source"].map { ThirdPartySourcePlatform(code: $0).title } ?? ""
        let kind = source.script?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? atmusicLocalized("脚本", "Script")
            : source.kind.uppercased()
        let path = source.script?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? "" : source.urlPath
        let parts = [
            kind,
            source.quality,
            platform,
            path
        ].filter { !$0.isEmpty }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(source.name)
                            .font(ATMusicFont.appFont(14, .semibold))
                            .foregroundStyle(Color.atmusicLabel)
                            .lineLimit(1)
                    }
                    Text(subtitle)
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { source.enabled }, set: onToggle))
                    .labelsHidden()
                    .tint(Color.atmusicAmber)
            }

            HStack(spacing: 8) {
                Button {
                    onEdit()
                } label: {
                    Label(atmusicLocalized("编辑", "Edit"), systemImage: "slider.horizontal.3")
                        .foregroundStyle(Color.atmusicAmber)
                }
                .buttonStyle(GlassPressButtonStyle(scale: 0.96))

                Button {
                    onMoveUp()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)
                .disabled(!canMoveUp)
                .foregroundStyle(canMoveUp ? Color.atmusicAmber : Color.atmusicComment.opacity(0.35))

                Button {
                    onMoveDown()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain)
                .disabled(!canMoveDown)
                .foregroundStyle(canMoveDown ? Color.atmusicAmber : Color.atmusicComment.opacity(0.35))

                Spacer()

                Button {
                    onRemove()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(Color.red.opacity(0.9))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background {
            ATMusicSurface(shape: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

private struct ThirdPartySourceDraft: Identifiable {
    var id: String = UUID().uuidString
    var name: String = ""
    var kind: String = "keyword"
    var template: String = ""
    var urlPath: String = "url"
    var headersText: String = ""
    var quality: String = "320k"
    var scriptText: String = ""
    var enabled: Bool = true
    var platform: ThirdPartySourcePlatform = .all

    init() {}

    init(source: ThirdPartySource) {
        id = source.id
        name = source.name
        kind = source.kind
        template = source.template
        urlPath = source.urlPath
        quality = source.quality.isEmpty ? "320k" : source.quality
        scriptText = source.script ?? ""
        enabled = source.enabled
        if let code = source.headers["source"] {
            platform = ThirdPartySourcePlatform(code: code)
        }
        headersText = source.headers
            .filter { $0.key != "source" && $0.key != "quality" && $0.key != "br" }
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
    }

    func toSource() -> ThirdPartySource {
        var headers = Self.parseHeaders(headersText)
        if let code = platform.code {
            headers["source"] = code
        }
        headers["quality"] = quality.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "320k" : quality
        return ThirdPartySource(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? atmusicLocalized("未命名音源", "Untitled source") : name,
            kind: kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "keyword" : kind,
            template: template.trimmingCharacters(in: .whitespacesAndNewlines),
            urlPath: urlPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "url" : urlPath,
            headers: headers,
            quality: quality.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "320k" : quality,
            script: scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : scriptText,
            enabled: enabled
        )
    }

    private static func parseHeaders(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let separators: [Character] = [":", "="]
            if let separator = separators.first(where: { line.contains($0) }) {
                let pieces = line.split(separator: separator, maxSplits: 1, omittingEmptySubsequences: false)
                if pieces.count == 2 {
                    let key = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    let value = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !key.isEmpty, !value.isEmpty {
                        result[key] = value
                    }
                }
            }
        }
        return result
    }
}

private enum ThirdPartySourcePlatform: String, CaseIterable, Identifiable {
    case all
    case netease
    case qq
    case kugou

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return atmusicLocalized("全部平台", "All Platforms")
        case .netease: return atmusicLocalized("网易云音乐", "NetEase Cloud Music")
        case .qq: return atmusicLocalized("QQ音乐", "QQ Music")
        case .kugou: return atmusicLocalized("酷狗音乐", "Kugou Music")
        }
    }

    var code: String? {
        switch self {
        case .all: return nil
        case .netease: return "wy"
        case .qq: return "tx"
        case .kugou: return "kg"
        }
    }

    init(code: String) {
        switch code.lowercased() {
        case "wy", "netease", "cloud":
            self = .netease
        case "tx", "qq", "qqmusic":
            self = .qq
        case "kg", "kugou":
            self = .kugou
        default:
            self = .all
        }
    }
}

private struct SourceEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ThirdPartySourceDraft
    let onSave: (ThirdPartySourceDraft) -> Void

    init(draft: ThirdPartySourceDraft, onSave: @escaping (ThirdPartySourceDraft) -> Void) {
        _draft = State(initialValue: draft)
        self.onSave = onSave
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 14) {
                    editorCard
                }
                .padding(16)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .background(GlassBackdrop())
            .navigationTitle(atmusicLocalized("编辑音源", "Edit Source"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(atmusicLocalized("保存", "Save")) {
                        onSave(draft)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(atmusicLocalized("取消", "Cancel")) { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var editorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(atmusicLocalized("音源名称", "Source Name"), text: $draft.name)
                .font(ATMusicFont.appFont(14))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous)) }

            TextField(atmusicLocalized("类型", "Type"), text: $draft.kind)
                .font(ATMusicFont.appFont(14))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous)) }

            Picker(atmusicLocalized("适用平台", "Platform"), selection: $draft.platform) {
                ForEach(ThirdPartySourcePlatform.allCases) { platform in
                    Text(platform.title).tag(platform)
                }
            }
            .pickerStyle(.segmented)

            Picker(atmusicLocalized("音质", "Quality"), selection: $draft.quality) {
                Text("128k").tag("128k")
                Text("192k").tag("192k")
                Text("320k").tag("320k")
                Text("FLAC").tag("flac")
                Text("FLAC 24-bit").tag("flac24bit")
                Text("Hi-Res").tag("hires")
                Text("Master").tag("master")
            }
            .pickerStyle(.menu)
            .tint(Color.atmusicAmber)

            if !draft.kind.lowercased().contains("script") {
                TextField(atmusicLocalized("URL 模板", "URL Template"), text: $draft.template)
                    .font(ATMusicFont.appFont(14))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous)) }
            }

            if draft.kind.lowercased().contains("script") || !draft.scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(atmusicLocalized("脚本内容", "Script Content"))
                        .font(ATMusicFont.appFont(13, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $draft.scriptText)
                            .frame(minHeight: 180)
                            .padding(8)
                            .background(Color.clear)
                            .modifier(ScrollContentBackgroundHidden())
                        if draft.scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(atmusicLocalized("粘贴 LX / Baka 风格 JS 音源脚本", "Paste LX / Baka style JS source script"))
                                .font(ATMusicFont.appFont(12))
                                .foregroundStyle(Color.atmusicComment.opacity(0.85))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 16)
                        }
                    }
                    .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous)) }
                }
            }

            if !draft.kind.lowercased().contains("script") {
                TextField(atmusicLocalized("字段路径", "Value Path"), text: $draft.urlPath)
                    .font(ATMusicFont.appFont(14))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous)) }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(atmusicLocalized("请求头", "Headers"))
                    .font(ATMusicFont.appFont(13, .semibold))
                    .foregroundStyle(Color.atmusicLabel)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $draft.headersText)
                        .frame(minHeight: 140)
                        .padding(8)
                        .background(Color.clear)
                        .modifier(ScrollContentBackgroundHidden())
                    if draft.headersText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(atmusicLocalized("每行一个 key: value", "One key: value per line"))
                            .font(ATMusicFont.appFont(12))
                            .foregroundStyle(Color.atmusicComment.opacity(0.85))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 16)
                    }
                }
                .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous)) }
            }

            Toggle(isOn: $draft.enabled) {
                Text(atmusicLocalized("启用", "Enabled"))
                    .font(ATMusicFont.appFont(14))
                    .foregroundStyle(Color.atmusicLabel)
            }
            .tint(Color.atmusicAmber)

        }
        .padding(16)
        .background {
            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .atmusicCardShadow(radius: 8, y: 3)
    }
}

private struct ScrollContentBackgroundHidden: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.scrollContentBackground(.hidden)
        } else {
            content
        }
    }
}

private struct SourceDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.json, .plainText, .item],
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: SourceDocumentPicker
        init(_ parent: SourceDocumentPicker) { self.parent = parent }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            parent.onPick(url)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}
