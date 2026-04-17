import Foundation

extension CodexAssistantRuntime {
    func listPlugins(
        cwds: [String] = [],
        forceRemoteSync: Bool = false
    ) async throws -> [AssistantCodexPluginSummary] {
        try await ensureTransport()
        var params: [String: Any] = [:]
        if !cwds.isEmpty {
            params["cwds"] = cwds
        }
        if forceRemoteSync {
            params["forceRemoteSync"] = true
        }
        let response = try await sendRequest(method: "plugin/list", params: params)
        return Self.parsePluginSummaries(from: response.raw)
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
    }

    func readPlugin(
        marketplacePath: String,
        pluginName: String
    ) async throws -> AssistantCodexPluginDetail {
        try await ensureTransport()
        let response = try await sendRequest(
            method: "plugin/read",
            params: [
                "marketplacePath": marketplacePath,
                "pluginName": pluginName,
            ]
        )
        guard let detail = Self.parsePluginDetail(
            from: response.raw,
            fallbackMarketplacePath: marketplacePath,
            fallbackPluginName: pluginName
        ) else {
            throw CodexAssistantRuntimeError.invalidResponse(
                "Codex did not return readable details for \(pluginName)."
            )
        }
        return detail
    }

    func installPlugin(
        marketplacePath: String,
        pluginName: String,
        forceRemoteSync: Bool = true
    ) async throws {
        try await ensureTransport()
        var params: [String: Any] = [
            "marketplacePath": marketplacePath,
            "pluginName": pluginName,
        ]
        if forceRemoteSync {
            params["forceRemoteSync"] = true
        }
        _ = try await sendRequest(method: "plugin/install", params: params)
    }

    func uninstallPlugin(
        pluginID: String,
        forceRemoteSync: Bool = true
    ) async throws {
        try await ensureTransport()
        var params: [String: Any] = ["pluginId": pluginID]
        if forceRemoteSync {
            params["forceRemoteSync"] = true
        }
        _ = try await sendRequest(method: "plugin/uninstall", params: params)
    }

    func listPluginApps() async throws -> [AssistantCodexPluginAppStatus] {
        try await ensureTransport()
        var apps: [AssistantCodexPluginAppStatus] = []
        var seen = Set<String>()
        var cursor: String?

        while true {
            var params: [String: Any] = [:]
            if let cursor {
                params["cursor"] = cursor
            }
            let response = try await sendRequest(method: "app/list", params: params)
            let parsed = Self.parseAppStatuses(from: response.raw)
            for app in parsed.items where seen.insert(app.id.lowercased()).inserted {
                apps.append(app)
            }
            guard let nextCursor = parsed.nextCursor else { break }
            cursor = nextCursor
        }

        return apps.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func listPluginMCPServerStatuses() async throws -> [AssistantCodexPluginMCPServerStatus] {
        try await ensureTransport()
        let response = try await sendRequest(method: "mcpServerStatus/list", params: [:])
        return Self.parseMCPServerStatuses(from: response.raw)
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    func reloadMCPServerConfiguration() async throws {
        try await ensureTransport()
        _ = try await sendRequest(method: "config/mcpServer/reload", params: [:])
    }

    func beginMCPServerOAuthLogin(serverName: String) async throws -> URL? {
        try await ensureTransport()
        let response = try await sendRequest(
            method: "mcpServer/oauth/login",
            params: ["serverName": serverName]
        )
        guard let payload = response.raw as? [String: Any] else { return nil }
        let rawURL = [
            payload["url"] as? String,
            payload["loginUrl"] as? String,
            payload["installUrl"] as? String,
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }.first
        return rawURL.flatMap(URL.init(string:))
    }

    private static func parsePluginSummaries(from raw: Any) -> [AssistantCodexPluginSummary] {
        if let payload = raw as? [String: Any] {
            if let marketplaces = payload["marketplaces"] as? [[String: Any]] {
                return marketplaces.flatMap { market in
                    let marketplaceInterface = pluginDictionary(market["interface"])
                    let marketplaceName = pluginString(
                        marketplaceInterface?["displayName"],
                        market["name"],
                        market["marketplaceName"],
                        market["path"],
                        market["marketplacePath"]
                    )
                    let marketplacePath = pluginString(
                        market["path"],
                        market["marketplacePath"],
                        market["name"],
                        market["marketplaceName"]
                    )
                    let plugins = (market["plugins"] as? [[String: Any]]) ?? []
                    return plugins.compactMap {
                        parsePluginSummary(
                            from: $0,
                            fallbackMarketplaceName: marketplaceName,
                            fallbackMarketplacePath: marketplacePath
                        )
                    }
                }
            }

            for key in ["plugins", "data", "items"] {
                if let items = payload[key] as? [[String: Any]] {
                    return items.compactMap {
                        parsePluginSummary(
                            from: $0,
                            fallbackMarketplaceName: nil,
                            fallbackMarketplacePath: nil
                        )
                    }
                }
            }
        }

        if let items = raw as? [[String: Any]] {
            return items.compactMap {
                parsePluginSummary(
                    from: $0,
                    fallbackMarketplaceName: nil,
                    fallbackMarketplacePath: nil
                )
            }
        }

        return []
    }

    private static func parsePluginSummary(
        from item: [String: Any],
        fallbackMarketplaceName: String?,
        fallbackMarketplacePath: String?
    ) -> AssistantCodexPluginSummary? {
        let interface = pluginDictionary(item["interface"])
        let source = pluginDictionary(item["source"])
        let rawName = pluginString(item["name"], item["pluginName"])
        let rawID = pluginString(item["id"])
        let pluginName = rawName ?? rawID?.split(separator: "@").first.map(String.init)
        guard let pluginName, !pluginName.isEmpty else { return nil }

        let marketplacePath = pluginString(
            item["marketplacePath"],
            item["marketplace"]
        ) ?? fallbackMarketplacePath ?? rawID?.split(separator: "@").dropFirst().joined(separator: "@")
            .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "default"
        let marketplaceName = pluginString(
            item["marketplaceName"],
            interface?["marketplaceName"],
            item["marketplacePath"]
        ) ?? fallbackMarketplaceName ?? marketplacePath
        let displayName = assistantDisplayPluginName(
            pluginName: pluginName,
            fallbackDisplayName: pluginString(
                interface?["displayName"],
                item["displayName"],
                item["title"]
            )
        )
        let pluginID = rawID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "\(pluginName)@\(marketplacePath)"

        return AssistantCodexPluginSummary(
            id: pluginID,
            pluginName: pluginName,
            displayName: displayName,
            marketplaceName: marketplaceName,
            marketplacePath: marketplacePath,
            source: pluginString(source?["path"], source?["type"], item["sourcePath"]),
            summary: pluginString(
                interface?["shortDescription"],
                item["summary"],
                item["description"],
                interface?["longDescription"]
            ),
            isInstalled: pluginBool(item["installed"]),
            isEnabled: pluginBool(item["enabled"], default: true),
            installPolicy: pluginString(item["installPolicy"]),
            authPolicy: pluginString(item["authPolicy"]),
            interfaceKind: pluginString(item["interfaceKind"], source?["type"])
        )
    }

    private static func parsePluginDetail(
        from raw: Any,
        fallbackMarketplacePath: String,
        fallbackPluginName: String
    ) -> AssistantCodexPluginDetail? {
        let payload: [String: Any]
        if let rawPayload = raw as? [String: Any] {
            if let nested = rawPayload["plugin"] as? [String: Any] {
                payload = nested
            } else {
                payload = rawPayload
            }
        } else {
            return nil
        }

        let summaryPayload = pluginDictionary(payload["summary"]) ?? payload
        let interface = pluginDictionary(summaryPayload["interface"])

        let pluginName = pluginString(
            summaryPayload["name"],
            summaryPayload["pluginName"],
            payload["name"],
            payload["pluginName"]
        ) ?? fallbackPluginName
        let displayName = assistantDisplayPluginName(
            pluginName: pluginName,
            fallbackDisplayName: pluginString(
                interface?["displayName"],
                summaryPayload["displayName"],
                payload["displayName"],
                summaryPayload["title"],
                payload["title"]
            )
        )
        let marketplacePath = pluginString(
            payload["marketplacePath"],
            summaryPayload["marketplacePath"],
            payload["marketplace"],
            summaryPayload["marketplace"]
        ) ?? fallbackMarketplacePath
        let marketplaceName = pluginString(
            payload["marketplaceName"],
            summaryPayload["marketplaceName"],
            payload["marketplacePath"]
        ) ?? marketplacePath

        let skills = parsePluginSkills(from: payload["skills"])
        let apps = parsePluginApps(from: payload["apps"])
        let mcpServers = parsePluginMCPServers(from: payload["mcpServers"])
        let starterPrompts = parseStarterPrompts(
            from: interface?["defaultPrompt"]
                ?? payload["starterPrompts"]
                ?? payload["prompts"]
                ?? summaryPayload["starterPrompts"]
                ?? summaryPayload["prompts"]
        )

        return AssistantCodexPluginDetail(
            id: pluginString(summaryPayload["id"], payload["id"]) ?? "\(pluginName)@\(marketplacePath)",
            pluginName: pluginName,
            displayName: displayName,
            marketplaceName: marketplaceName,
            marketplacePath: marketplacePath,
            summary: pluginString(
                interface?["shortDescription"],
                summaryPayload["summary"],
                payload["summary"]
            ),
            description: pluginString(
                payload["description"],
                interface?["longDescription"],
                summaryPayload["description"]
            ),
            skills: skills,
            apps: apps,
            mcpServers: mcpServers,
            starterPrompts: starterPrompts
        )
    }

    private static func parsePluginSkills(from raw: Any?) -> [AssistantCodexPluginSkill] {
        if let items = raw as? [[String: Any]] {
            return items.compactMap { item in
                let interface = pluginDictionary(item["interface"])
                let name = pluginString(item["name"], item["id"], item["displayName"])
                let path = pluginString(item["path"], item["uri"])
                guard let name, let path else { return nil }
                return AssistantCodexPluginSkill(
                    name: name,
                    displayName: assistantDisplayPluginName(
                        pluginName: name,
                        fallbackDisplayName: pluginString(
                            interface?["displayName"],
                            item["displayName"],
                            item["title"]
                        )
                    ),
                    path: path,
                    summary: pluginString(
                        interface?["shortDescription"],
                        item["shortDescription"],
                        item["summary"],
                        item["description"]
                    )
                )
            }
        }
        return []
    }

    private static func parsePluginApps(from raw: Any?) -> [AssistantCodexPluginApp] {
        if let items = raw as? [[String: Any]] {
            return items.compactMap { item in
                let id = pluginString(item["id"], item["connectorId"], item["name"])
                guard let id else { return nil }
                return AssistantCodexPluginApp(
                    id: id,
                    name: assistantDisplayPluginName(
                        pluginName: id,
                        fallbackDisplayName: pluginString(item["name"], item["displayName"])
                    )
                )
            }
        }
        if let items = raw as? [String] {
            return items.map {
                AssistantCodexPluginApp(
                    id: $0,
                    name: assistantDisplayPluginName(pluginName: $0)
                )
            }
        }
        return []
    }

    private static func parsePluginMCPServers(from raw: Any?) -> [AssistantCodexPluginMCPServer] {
        if let items = raw as? [[String: Any]] {
            return items.compactMap { item in
                guard let name = pluginString(item["name"], item["id"]) else { return nil }
                return AssistantCodexPluginMCPServer(name: name)
            }
        }
        if let items = raw as? [String] {
            return items.map(AssistantCodexPluginMCPServer.init(name:))
        }
        return []
    }

    private static func parseStarterPrompts(from raw: Any?) -> [String] {
        if let values = raw as? [String] {
            return values.compactMap {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            }
        }
        if let value = raw as? String {
            return value.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty.map { [$0] } ?? []
        }
        if let items = raw as? [[String: Any]] {
            return items.compactMap {
                pluginString($0["prompt"], $0["text"], $0["title"])
            }
        }
        return []
    }

    private static func parseAppStatuses(
        from raw: Any
    ) -> (items: [AssistantCodexPluginAppStatus], nextCursor: String?) {
        let payload = raw as? [String: Any] ?? [:]
        let items = (payload["data"] as? [[String: Any]])
            ?? (payload["apps"] as? [[String: Any]])
            ?? []
        let statuses = items.compactMap { item -> AssistantCodexPluginAppStatus? in
            let id = pluginString(item["id"], item["connectorId"], item["name"])
            guard let id else { return nil }
            let name = assistantDisplayPluginName(
                pluginName: id,
                fallbackDisplayName: pluginString(item["name"], item["displayName"])
            )
            let pluginNames = (item["pluginDisplayNames"] as? [String] ?? [])
                .compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
            return AssistantCodexPluginAppStatus(
                id: id,
                name: name,
                installURL: pluginString(item["installUrl"], item["url"]),
                isAccessible: pluginBool(item["isAccessible"], default: false),
                isEnabled: pluginBool(item["isEnabled"], default: true),
                pluginDisplayNames: pluginNames
            )
        }
        let nextCursor = pluginString(payload["nextCursor"])
        return (statuses, nextCursor)
    }

    private static func parseMCPServerStatuses(from raw: Any) -> [AssistantCodexPluginMCPServerStatus] {
        let payload = raw as? [String: Any] ?? [:]
        let items = (payload["data"] as? [[String: Any]])
            ?? (payload["mcpServers"] as? [[String: Any]])
            ?? (raw as? [[String: Any]])
            ?? []
        return items.compactMap { item in
            guard let name = pluginString(item["name"], item["id"]) else { return nil }
            return AssistantCodexPluginMCPServerStatus(
                name: name,
                authStatus: pluginString(item["authStatus"]),
                toolCount: pluginCount(item["tools"]),
                resourceCount: pluginCount(item["resources"]),
                resourceTemplateCount: pluginCount(item["resourceTemplates"])
            )
        }
    }

    private static func pluginString(_ candidates: Any?...) -> String? {
        for candidate in candidates {
            if let value = candidate as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private static func pluginBool(_ candidate: Any?, default defaultValue: Bool = false) -> Bool {
        if let value = candidate as? Bool {
            return value
        }
        if let value = candidate as? NSNumber {
            return value.boolValue
        }
        if let value = candidate as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes", "enabled":
                return true
            case "false", "0", "no", "disabled":
                return false
            default:
                break
            }
        }
        return defaultValue
    }

    private static func pluginCount(_ candidate: Any?) -> Int {
        if let value = candidate as? Int {
            return value
        }
        if let value = candidate as? [String: Any] {
            return value.count
        }
        if let value = candidate as? [Any] {
            return value.count
        }
        return 0
    }

    private static func pluginDictionary(_ candidate: Any?) -> [String: Any]? {
        candidate as? [String: Any]
    }
}
