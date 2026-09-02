import SwiftUI
import UniformTypeIdentifiers

/// 第三方音源管理页：添加、编辑、启停、导入导出与连接状态检测。
struct UnblockSourceManagerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = UnblockSourceStore.shared

    /// 同一视图上叠多个 .sheet 在 iOS 15/16 上只有最后一个生效，统一用枚举驱动
    private enum ActiveSheet: Identifiable {
        case editor(ThirdPartySource)
        case remoteImport

        var id: String {
            switch self {
            case .editor(let source): return "editor-\(source.id)"
            case .remoteImport: return "remote"
            }
        }
    }

    @State private var activeSheet: ActiveSheet?
    @State private var showImportPicker = false
    @State private var remoteURLText = ""
    @State private var exportDoc: SourceExportDocument?
    @State private var showExport = false
    @State private var pendingDeleteID: String?
    @State private var isChecking = false

    var body: some View {
        BeansNavigationStack {
            ZStack {
                GlassBackdrop()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        introCard
                        if store.sources.isEmpty {
                            emptyCard
                        } else {
                            ForEach(store.sources) { source in
                                sourceCard(source)
                            }
                        }
                        actionCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
                .beansScrollIndicatorsHidden()
            }
            .navigationTitle("音源管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                        .font(BeansFont.appFont(15))
                        .foregroundStyle(Color.beansAmber)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        BeansHaptics.tap()
                        activeSheet = .editor(ThirdPartySource(name: "", template: ""))
                    } label: {
                        Image(systemName: "plus")
                            .foregroundStyle(Color.beansAmber)
                    }
                }
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .editor(let source):
                UnblockSourceEditorSheet(source: source)
            case .remoteImport:
                remoteImportSheet
            }
        }
        .fullScreenCover(isPresented: $showImportPicker) {
            BackupDocumentPicker { url in
                handleLocalImport(url)
            }
            .ignoresSafeArea()
        }
        .fileExporter(
            isPresented: $showExport,
            document: exportDoc,
            contentType: .json,
            defaultFilename: "Beans音源配置"
        ) { result in
            if case .failure(let error) = result {
                ToastCenter.shared.show("导出失败：\(error.localizedDescription)")
            } else {
                ToastCenter.shared.show("音源配置已导出")
            }
        }
        .confirmationDialog("删除该音源？", isPresented: deleteConfirmBinding, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let id = pendingDeleteID { store.remove(id: id) }
                pendingDeleteID = nil
            }
            Button("取消", role: .cancel) { pendingDeleteID = nil }
        }
    }

    /// 链接导入：iOS 15 的 alert 不支持内嵌输入框，改用独立表单页
    private var remoteImportSheet: some View {
        BeansNavigationStack {
            Form {
                Section {
                    TextField("https://example.com/sources.json", text: $remoteURLText)
                        .font(BeansFont.appFont(13))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("导入地址").font(BeansFont.appFont(12))
                } footer: {
                    Text("支持音源配置 JSON 和 LX Music .js 脚本，会自动识别内容类型")
                        .font(BeansFont.appFont(11))
                }
            }
            .navigationTitle("从链接导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { activeSheet = nil }
                        .font(BeansFont.appFont(15))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") {
                        activeSheet = nil
                        handleRemoteImport()
                    }
                    .font(BeansFont.appFont(15, .semibold))
                    .disabled(remoteURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var deleteConfirmBinding: Binding<Bool> {
        Binding(
            get: { pendingDeleteID != nil },
            set: { if !$0 { pendingDeleteID = nil } }
        )
    }

    // MARK: - 卡片

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.beansAmber)
                Text("关于第三方音源")
                    .font(BeansFont.appFont(14, .semibold))
                    .foregroundStyle(Color.beansLabel)
            }
            Text("官方地址不可用或只有试听片段时，会依次尝试这里启用的音源。音源需自行准备，App 不再内置任何可用音源。")
                .font(BeansFont.appFont(12))
                .foregroundStyle(Color.beansComment)
            Text("支持两种格式：JSON 模板音源（占位符 {id}/{source}/{quality} 等）和 LX Music JS 脚本音源（.js 文件，通过 globalThis.lx API 运行）。")
                .font(BeansFont.appFont(11))
                .foregroundStyle(Color.beansComment)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            BeansGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .beansCardShadow(radius: 9, y: 3)
    }

    private var emptyCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "shippingbox")
                .font(.system(size: 30))
                .foregroundStyle(Color.beansComment)
            Text("还没有配置音源")
                .font(BeansFont.appFont(14, .medium))
                .foregroundStyle(Color.beansLabel)
            Text("点击右上角 + 手动添加，或从文件/链接导入")
                .font(BeansFont.appFont(12))
                .foregroundStyle(Color.beansComment)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background {
            BeansGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .beansCardShadow(radius: 9, y: 3)
    }

    private func sourceCard(_ source: ThirdPartySource) -> some View {
        let state = store.healthState(for: source.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.name.isEmpty ? "未命名音源" : source.name)
                        .font(BeansFont.appFont(15, .semibold))
                        .foregroundStyle(Color.beansLabel)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(healthColor(state))
                            .frame(width: 7, height: 7)
                        Text(state.label)
                            .font(BeansFont.appFont(11))
                            .foregroundStyle(Color.beansComment)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Toggle("", isOn: enabledBinding(source.id))
                    .labelsHidden()
                    .tint(Color.beansAmber)
            }

            Text(source.template)
                .font(BeansFont.appFont(10))
                .foregroundStyle(Color.beansComment)
                .lineLimit(2)
                .truncationMode(.middle)

            if source.isLXScript {
                Text("LX Music JS 脚本音源")
                    .font(BeansFont.appFont(10))
                    .foregroundStyle(Color.beansAmber)
            }

            if !source.isLXScript && !source.isValid {
                Text("模板缺少 {id} / {keyword} / {name} 占位符，无法参与播放")
                    .font(BeansFont.appFont(10))
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 14) {
                Button {
                    BeansHaptics.tap()
                    Task { await store.checkHealth(for: source) }
                } label: {
                    Label("检测", systemImage: "antenna.radiowaves.left.and.right")
                        .font(BeansFont.appFont(12))
                        .foregroundStyle(Color.beansAmber)
                }
                .buttonStyle(.plain)

                Button {
                    BeansHaptics.tap()
                    activeSheet = .editor(source)
                } label: {
                    Label("编辑", systemImage: "slider.horizontal.3")
                        .font(BeansFont.appFont(12))
                        .foregroundStyle(Color.beansAmber)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    BeansHaptics.tap()
                    pendingDeleteID = source.id
                } label: {
                    Label("删除", systemImage: "trash")
                        .font(BeansFont.appFont(12))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            BeansGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .beansCardShadow(radius: 9, y: 3)
    }

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                BeansHaptics.tap()
                showImportPicker = true
            } label: {
                actionRow(icon: "folder.badge.plus", title: "从文件导入", detail: "音源配置 JSON 或 LX Music .js 脚本，自动识别")
            }
            .buttonStyle(.plain)

            Divider().overlay(Color.beansComment.opacity(0.15))

            Button {
                BeansHaptics.tap()
                remoteURLText = ""
                activeSheet = .remoteImport
            } label: {
                actionRow(icon: "link", title: "从链接导入", detail: "导入 JSON 配置或 LX Music .js 脚本")
            }
            .buttonStyle(.plain)

            if !store.sources.isEmpty {
                Divider().overlay(Color.beansComment.opacity(0.15))

                Button {
                    BeansHaptics.tap()
                    handleExport()
                } label: {
                    actionRow(icon: "square.and.arrow.up", title: "导出配置", detail: "备份当前 \(store.sources.count) 个音源")
                }
                .buttonStyle(.plain)

                Divider().overlay(Color.beansComment.opacity(0.15))

                Button {
                    BeansHaptics.tap()
                    isChecking = true
                    Task {
                        await store.checkHealthForActiveSources()
                        isChecking = false
                    }
                } label: {
                    actionRow(
                        icon: "checkmark.seal",
                        title: isChecking ? "检测中…" : "检测全部启用音源",
                        detail: "逐个请求确认连接状态"
                    )
                }
                .buttonStyle(.plain)
                .disabled(isChecking)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            BeansGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .beansCardShadow(radius: 9, y: 3)
    }

    private func actionRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Color.beansAmber)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(BeansFont.appFont(15))
                    .foregroundStyle(Color.beansLabel)
                Text(detail)
                    .font(BeansFont.appFont(11))
                    .foregroundStyle(Color.beansComment)
            }
            Spacer()
        }
    }

    private func healthColor(_ state: UnblockSourceHealth) -> Color {
        switch state {
        case .healthy: return .green
        case .failed: return .red
        case .checking: return Color.beansAmber
        case .unknown: return Color.beansComment.opacity(0.5)
        }
    }

    private func enabledBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { store.sources.first(where: { $0.id == id })?.enabled ?? false },
            set: { store.setEnabled($0, for: id) }
        )
    }

    // MARK: - 导入导出

    private func handleLocalImport(_ url: URL) {
        showImportPicker = false
        do {
            let data = try Data(contentsOf: url)
            let result = try store.importFromFile(data: data)
            ToastCenter.shared.show(result.summary)
        } catch {
            ToastCenter.shared.show(error.localizedDescription)
        }
    }

    private func handleRemoteImport() {
        let text = remoteURLText
        Task {
            do {
                let result = try await store.importFromRemote(urlString: text)
                ToastCenter.shared.show(result.summary)
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    private func handleExport() {
        do {
            let data = try store.exportData()
            exportDoc = SourceExportDocument(data: data)
            showExport = true
        } catch {
            ToastCenter.shared.show("导出失败：\(error.localizedDescription)")
        }
    }
}

// MARK: - 音源编辑

/// 单个音源的新增 / 编辑表单
struct UnblockSourceEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = UnblockSourceStore.shared

    @State private var draft: ThirdPartySource
    @State private var apiKey: String
    @State private var quality: String
    @State private var providerLock: String
    @State private var providerParam: String
    @State private var extraHeaderText: String
    private let isNew: Bool

    init(source: ThirdPartySource) {
        _draft = State(initialValue: source)
        _apiKey = State(initialValue: source.headers["apiKey"] ?? "")
        _quality = State(initialValue: source.headers["quality"] ?? "320k")
        let lock = source.providerMap.keys.first ?? ""
        _providerLock = State(initialValue: lock)
        _providerParam = State(initialValue: source.providerMap[lock] ?? "")
        let extras = source.headers
            .filter { !ThirdPartySource.metadataKeys.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
        _extraHeaderText = State(initialValue: extras)
        isNew = source.name.isEmpty && source.template.isEmpty
    }

    var body: some View {
        BeansNavigationStack {
            Form {
                Section {
                    TextField("音源名称", text: $draft.name)
                        .font(BeansFont.appFont(15))
                } header: {
                    Text("名称").font(BeansFont.appFont(12))
                }

                if draft.isLXScript {
                    // LX 脚本音源：只显示脚本信息，不编辑脚本内容（通过导入 .js 文件添加）
                    Section {
                        Text("此音源为 LX Music JS 脚本，脚本内容通过导入 .js 文件添加，不支持在编辑器中修改。")
                            .font(BeansFont.appFont(12))
                            .foregroundStyle(Color.beansComment)
                    } header: {
                        Text("LX 脚本音源").font(BeansFont.appFont(12))
                    }
                } else {
                    Section {
                        TextField("https://host/url?source={source}&id={id}", text: $draft.template)
                            .font(BeansFont.appFont(13))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("请求模板").font(BeansFont.appFont(12))
                    } footer: {
                        Text("占位符：{id} {source} {quality} {name} {artist} {keyword}，至少包含 {id} / {keyword} / {name} 之一")
                            .font(BeansFont.appFont(11))
                    }

                    Section {
                        TextField("url 或 data.url|url", text: $draft.urlPath)
                            .font(BeansFont.appFont(13))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("播放地址取值路径").font(BeansFont.appFont(12))
                    } footer: {
                        Text("响应 JSON 中播放地址的位置，多个候选用 | 分隔")
                            .font(BeansFont.appFont(11))
                    }

                    Section {
                        TextField("留空表示不需要", text: $apiKey)
                            .font(BeansFont.appFont(13))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("320k", text: $quality)
                            .font(BeansFont.appFont(13))
                            .textInputAutocapitalization(.never)
                        Picker("限定平台", selection: $providerLock) {
                            Text("不限").tag("")
                            Text("网易云").tag("wy")
                            Text("QQ 音乐").tag("tx")
                            Text("酷狗").tag("kg")
                        }
                        .font(BeansFont.appFont(13))
                        .onChange(of: providerLock) { newValue in
                            // 切换平台时给出常见接口的默认参数名，用户可改
                            switch newValue {
                            case "wy": providerParam = "netease"
                            case "tx": providerParam = "tencent"
                            case "kg": providerParam = "kugou"
                            default: providerParam = ""
                            }
                        }
                        if !providerLock.isEmpty {
                            TextField("{source} 实际值，如 netease", text: $providerParam)
                                .font(BeansFont.appFont(13))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    } header: {
                        Text("密钥与参数").font(BeansFont.appFont(12))
                    } footer: {
                        Text("密钥以 X-API-Key 请求头发送；限定平台后该音源只用于对应平台的歌曲。各家接口对平台的叫法不同，{source} 会替换成下方填的值")
                            .font(BeansFont.appFont(11))
                    }

                    Section {
                        TextEditor(text: $extraHeaderText)
                            .font(BeansFont.appFont(12))
                            .frame(minHeight: 72)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("附加请求头").font(BeansFont.appFont(12))
                    } footer: {
                        Text("每行一个，格式 名称: 值")
                            .font(BeansFont.appFont(11))
                    }
                }
            }
            .navigationTitle(isNew ? "添加音源" : "编辑音源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .font(BeansFont.appFont(15))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .font(BeansFont.appFont(15, .semibold))
                        .disabled(!canSave)
                }
            }
        }
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.isValid
    }

    private func save() {
        var source = draft
        source.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)

        if !source.isLXScript {
            // JSON 模板音源：保存模板/路径/headers/平台映射
            source.template = draft.template.trimmingCharacters(in: .whitespacesAndNewlines)
            source.urlPath = draft.urlPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "url"
                : draft.urlPath.trimmingCharacters(in: .whitespacesAndNewlines)

            var headers: [String: String] = [:]
            // 附加请求头按行解析，忽略空行与缺少冒号的行
            for line in extraHeaderText.split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { continue }
                headers[parts[0]] = parts[1]
            }
            let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedKey.isEmpty { headers["apiKey"] = trimmedKey }
            let trimmedQuality = quality.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedQuality.isEmpty { headers["quality"] = trimmedQuality }
            source.headers = headers

            // 锁定平台与接口参数名分开：前者决定该音源侍候哪个平台，后者是 {source} 的实际取值
            var providerMap: [String: String] = [:]
            if !providerLock.isEmpty {
                let param = providerParam.trimmingCharacters(in: .whitespacesAndNewlines)
                providerMap[providerLock] = param.isEmpty ? providerLock : param
            }
            source.providerMap = providerMap
        }

        if store.sources.contains(where: { $0.id == source.id }) {
            store.update(source)
        } else {
            store.add(source)
        }
        dismiss()
        Task { await store.checkHealth(for: source) }
    }
}

// MARK: - 导出文档

struct SourceExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
