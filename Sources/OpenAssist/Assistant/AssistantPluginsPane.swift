import AppKit
import SwiftUI

private enum AssistantPluginIconCache {
    static let cache = NSCache<NSString, NSImage>()

    static func image(for rawPath: String?) -> NSImage? {
        guard let rawPath = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }

        let key = rawPath as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let image: NSImage?
        if rawPath.hasPrefix("/") || rawPath.hasPrefix("~") {
            image = NSImage(contentsOfFile: NSString(string: rawPath).expandingTildeInPath)
        } else if let url = URL(string: rawPath), url.isFileURL {
            image = NSImage(contentsOf: url)
        } else {
            image = nil
        }

        if let image {
            cache.setObject(image, forKey: key)
        }
        return image
    }
}

private struct AssistantPluginIconView: View {
    let iconPath: String?
    let displayName: String
    let size: CGFloat
    let cornerRadius: CGFloat

    private var image: NSImage? {
        AssistantPluginIconCache.image(for: iconPath)
    }

    private var fallbackLabel: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(1)).uppercased().nonEmpty ?? "P"
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            AppVisualTheme.surfaceFill(0.11),
                            AppVisualTheme.surfaceFill(0.04),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.16)
            } else {
                Text(fallbackLabel)
                    .font(.system(size: size * 0.40, weight: .bold, design: .rounded))
                    .foregroundStyle(AppVisualTheme.foreground(0.68))
            }
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(AppVisualTheme.surfaceStroke(0.10), lineWidth: 0.7)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
        .accessibilityLabel("\(displayName) icon")
    }
}

struct AssistantPluginsPane: View {
    @ObservedObject var assistant: AssistantStore
    let onBack: () -> Void

    @State private var query = ""
    @State private var selectedPluginID: String?
    @State private var filter: PluginFilter = .all

    private enum PluginFilter: String, CaseIterable, Identifiable {
        case all
        case installed
        case available
        case needsSetup

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All"
            case .installed: return "Installed"
            case .available: return "Available"
            case .needsSetup: return "Needs Setup"
            }
        }
    }

    private var filteredPlugins: [AssistantCodexPluginSummary] {
        assistant.codexPlugins.filter { plugin in
            let readiness = assistant.codexPluginReadiness(for: plugin)
            switch filter {
            case .all:
                break
            case .installed:
                guard plugin.isInstalled else { return false }
            case .available:
                guard !plugin.isInstalled else { return false }
            case .needsSetup:
                guard readiness.state == .needsSetup else { return false }
            }

            let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedQuery.isEmpty else { return true }
            let haystack = [
                plugin.displayName,
                plugin.summary ?? "",
                plugin.marketplaceName,
            ].joined(separator: " ").lowercased()
            return haystack.contains(normalizedQuery)
        }
    }

    private var selectedPlugin: AssistantCodexPluginSummary? {
        if let selectedPluginID {
            return assistant.codexPlugins.first {
                $0.id.caseInsensitiveCompare(selectedPluginID) == .orderedSame
            }
        }
        return filteredPlugins.first
    }

    private var pluginCatalogLoadFailed: Bool {
        assistant.codexPlugins.isEmpty
            && !assistant.isRefreshingCodexPlugins
            && assistant.codexPluginErrorMessage?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.12)

            if !assistant.canUseCodexPlugins {
                unavailableState
            } else {
                content
            }
        }
        .task {
            await assistant.refreshCodexPluginCatalogIfNeeded()
            if selectedPluginID == nil {
                selectedPluginID = filteredPlugins.first?.id
            }
        }
        .onChange(of: selectedPluginID) { pluginID in
            guard let pluginID else { return }
            Task { await assistant.loadCodexPluginDetail(pluginID: pluginID) }
        }
        .onChange(of: assistant.codexPlugins.map(\.id)) { ids in
            if ids.contains(where: { $0.caseInsensitiveCompare(selectedPluginID ?? "") == .orderedSame }) == false {
                selectedPluginID = filteredPlugins.first?.id
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button {
                onBack()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)

            VStack(alignment: .leading, spacing: 4) {
                Text("Plugins")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(AppVisualTheme.foreground(0.94))
                Text("Browse Codex plugins, install them, and check what still needs setup.")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(0.56))
            }

            Spacer()

            if assistant.isRefreshingCodexPlugins {
                ProgressView()
                    .controlSize(.small)
            }

            Button("Refresh") {
                Task { await assistant.refreshCodexPluginCatalog(forceRemoteSync: true) }
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(AppVisualTheme.surfaceFill(0.03))
    }

    private var unavailableState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Plugins are only available when Codex is the active backend.")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppVisualTheme.foreground(0.88))
            Text("Switch the assistant backend to Codex, then open this page again.")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(AppVisualTheme.foreground(0.58))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(22)
    }

    private var content: some View {
        HStack(spacing: 0) {
            libraryColumn
                .frame(width: 330)
                .background(AppVisualTheme.surfaceFill(0.03))

            Divider().opacity(0.10)

            detailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var libraryColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search plugins", text: $query)
                .textFieldStyle(.roundedBorder)

            Picker("Filter", selection: $filter) {
                ForEach(PluginFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let errorMessage = assistant.codexPluginErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                Text(errorMessage)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.orange)
            }

            if assistant.isRefreshingCodexPlugins && assistant.codexPlugins.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading plugins…")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.foreground(0.86))
                    Text("OpenAssist is still reading the Codex plugin catalog.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.56))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 8)
            } else if pluginCatalogLoadFailed {
                pluginCatalogFailureState
            } else if filteredPlugins.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No plugins match this filter.")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.foreground(0.86))
                    Text("Try a different search or filter.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.56))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(filteredPlugins) { plugin in
                            pluginRow(plugin)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(16)
    }

    private var pluginCatalogFailureState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Couldn't load plugins.")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(AppVisualTheme.foreground(0.86))
            Text("Try Refresh to load the Codex plugin catalog again.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppVisualTheme.foreground(0.56))
            Button("Retry") {
                Task { await assistant.refreshCodexPluginCatalog(forceRemoteSync: true) }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 8)
    }

    private func pluginRow(_ plugin: AssistantCodexPluginSummary) -> some View {
        let readiness = assistant.codexPluginReadiness(for: plugin)
        let isSelected = plugin.id.caseInsensitiveCompare(selectedPluginID ?? "") == .orderedSame

        return Button {
            selectedPluginID = plugin.id
            Task { await assistant.loadCodexPluginDetail(pluginID: plugin.id) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                AssistantPluginIconView(
                    iconPath: plugin.iconPath,
                    displayName: plugin.displayName,
                    size: 42,
                    cornerRadius: 13
                )

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(plugin.displayName)
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(AppVisualTheme.foreground(0.92))
                                .lineLimit(1)
                            Text(plugin.marketplaceName)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(AppVisualTheme.foreground(0.46))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        readinessPill(
                            title: plugin.isInstalled
                                ? (readiness.state == .needsSetup ? "Needs setup" : "Installed")
                                : "Available",
                            tint: readiness.state == .needsSetup
                                ? Color.orange
                                : (plugin.isInstalled ? AppVisualTheme.accentTint : AppVisualTheme.foreground(0.62))
                        )
                    }

                    if let summary = plugin.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                        Text(summary)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AppVisualTheme.foreground(0.64))
                            .lineLimit(2)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? AppVisualTheme.accentTint.opacity(0.13) : AppVisualTheme.surfaceFill(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(
                                isSelected ? AppVisualTheme.accentTint.opacity(0.35) : AppVisualTheme.surfaceStroke(0.07),
                                lineWidth: isSelected ? 1.0 : 0.6
                            )
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var detailColumn: some View {
        ScrollView {
            if assistant.isRefreshingCodexPlugins && assistant.codexPlugins.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading plugin catalog…")
                        .font(.system(size: 14, weight: .semibold))
                    Text("The Codex App Server is still sending the installed and available plugins.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(20)
            } else if pluginCatalogLoadFailed {
                pluginCatalogFailureState
                    .padding(20)
            } else if let plugin = selectedPlugin {
                pluginDetail(plugin)
                    .padding(20)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No plugins match this filter.")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Try a different search or filter.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(20)
            }
        }
    }

    @ViewBuilder
    private func pluginDetail(_ plugin: AssistantCodexPluginSummary) -> some View {
        let detail = assistant.codexPluginDetail(for: plugin.id)
        let readiness = assistant.codexPluginReadiness(for: plugin)
        let isWorking = assistant.codexPluginOperationIDs.contains(plugin.id)
        let isSelectedForMessage = assistant.visibleSelectedComposerPlugins.contains {
            $0.pluginID.caseInsensitiveCompare(plugin.id) == .orderedSame
        }
        let iconPath = detail?.iconPath ?? plugin.iconPath

        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                AssistantPluginIconView(
                    iconPath: iconPath,
                    displayName: detail?.displayName ?? plugin.displayName,
                    size: 58,
                    cornerRadius: 18
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text(detail?.displayName ?? plugin.displayName)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(AppVisualTheme.foreground(0.94))
                    if let summary = detail?.summary ?? plugin.summary {
                        Text(summary)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(AppVisualTheme.foreground(0.64))
                    }
                    Text(plugin.marketplaceName)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.foreground(0.46))
                }

                Spacer()

                HStack(spacing: 8) {
                    if plugin.isInstalled {
                        Button {
                            assistant.selectComposerPlugin(pluginID: plugin.id)
                            onBack()
                        } label: {
                            Text(isSelectedForMessage ? "Attached to chat" : "Use in Chat")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isWorking || isSelectedForMessage)

                        Button(role: .destructive) {
                            Task { await assistant.uninstallCodexPlugin(pluginID: plugin.id) }
                        } label: {
                            Text(isWorking ? "Working…" : "Uninstall")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isWorking)
                    } else {
                        Button {
                            Task { await assistant.installCodexPlugin(pluginID: plugin.id) }
                        } label: {
                            Text(isWorking ? "Installing…" : "Install")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isWorking)
                    }
                }
            }

            HStack(spacing: 8) {
                readinessPill(
                    title: plugin.isInstalled ? "Installed" : "Available",
                    tint: plugin.isInstalled ? AppVisualTheme.accentTint : AppVisualTheme.foreground(0.62)
                )
                if readiness.state == .needsSetup {
                    readinessPill(title: "Needs setup", tint: .orange)
                }
            }

            if let description = detail?.description?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                detailSection(title: "Description") {
                    Text(description)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.70))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !readiness.appStatuses.isEmpty {
                detailSection(title: "Apps") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(readiness.appStatuses) { appStatus in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(appStatus.name)
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .foregroundStyle(AppVisualTheme.foreground(0.88))
                                    Text(appStatus.needsSetup ? "Needs setup in the app connector" : "Ready")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundStyle(AppVisualTheme.foreground(0.54))
                                }
                                Spacer()
                                if appStatus.needsSetup,
                                   let rawURL = appStatus.installURL,
                                   let url = URL(string: rawURL) {
                                    Button("Finish setup") {
                                        NSWorkspace.shared.open(url)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                }
            }

            if !readiness.mcpStatuses.isEmpty {
                detailSection(title: "MCP Servers") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(readiness.mcpStatuses) { status in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(status.name)
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .foregroundStyle(AppVisualTheme.foreground(0.88))
                                    Text(status.needsSetup ? "Sign in is required" : "Ready")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundStyle(AppVisualTheme.foreground(0.54))
                                }
                                Spacer()
                                if status.needsSetup {
                                    Button("Sign in") {
                                        Task { await assistant.startCodexPluginMCPAuth(serverName: status.name) }
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                }
            }

            if let detail, !detail.skills.isEmpty {
                detailSection(title: "Skills") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(detail.skills) { skill in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(skill.displayName)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(AppVisualTheme.foreground(0.88))
                                if let summary = skill.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                                    Text(summary)
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundStyle(AppVisualTheme.foreground(0.56))
                                }
                                Text(skill.path)
                                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(AppVisualTheme.foreground(0.42))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }

            if let detail, !detail.starterPrompts.isEmpty {
                detailSection(title: "Starter Prompts") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(detail.starterPrompts.enumerated()), id: \.offset) { entry in
                            let prompt = entry.element
                            Button {
                                assistant.selectComposerPlugin(pluginID: plugin.id)
                                assistant.promptDraft = prompt
                                onBack()
                            } label: {
                                Text(prompt)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(AppVisualTheme.foreground(0.78))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(AppVisualTheme.surfaceFill(0.05))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .onAppear {
            Task { await assistant.loadCodexPluginDetail(pluginID: plugin.id) }
        }
    }

    private func detailSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(AppVisualTheme.foreground(0.90))
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppVisualTheme.surfaceFill(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(AppVisualTheme.surfaceStroke(0.08), lineWidth: 0.6)
                )
        )
    }

    private func readinessPill(title: String, tint: Color) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.12))
            )
    }
}
