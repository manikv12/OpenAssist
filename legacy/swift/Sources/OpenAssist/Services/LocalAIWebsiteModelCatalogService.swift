import Foundation

protocol LocalAIWebsiteModelCatalogFetching {
    func fetchSmallModelOptions(limit: Int) async throws -> [LocalAIModelOption]
}

enum LocalAIWebsiteModelCatalogError: LocalizedError {
    case invalidResponse
    case requestFailed(statusCode: Int, detail: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Website catalog returned an invalid response."
        case let .requestFailed(statusCode, detail):
            let normalizedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedDetail.isEmpty {
                return "Website catalog request failed (\(statusCode))."
            }
            return "Website catalog request failed (\(statusCode)): \(normalizedDetail)"
        }
    }
}

struct LocalAIWebsiteModelCatalogService: LocalAIWebsiteModelCatalogFetching {
    private static let endpoint = URL(string: "https://ollama.com/api/tags")!
    private static let libraryBaseURL = URL(string: "https://ollama.com/library")!
    private static let minSmallModelSizeBytes: Int64 = 700_000_000
    private static let maxSmallModelSizeBytes: Int64 = 12_000_000_000
    private static let excludedKeywords: [String] = [
        "embed",
        "embedding",
        "vision",
        ":vl",
        "-vl",
        "audio",
        "tts",
        "whisper"
    ]
    private static let supplementalFamilySlugs: [String] = [
        "qwen3",
        "gemma3n",
        "ministral-3"
    ]

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchSmallModelOptions(limit: Int = 12) async throws -> [LocalAIModelOption] {
        var primaryError: Error?
        var mergedCandidates: [WebsiteModelCandidate] = []

        do {
            let apiCandidates = try await fetchAPIEndpointCandidates()
            mergedCandidates.append(contentsOf: apiCandidates)
        } catch {
            primaryError = error
        }

        let familyCandidates = await fetchFamilyPageCandidates()
        mergedCandidates.append(contentsOf: familyCandidates)

        let deduped = Self.dedupeCandidates(mergedCandidates)
        guard !deduped.isEmpty else {
            if let primaryError {
                throw primaryError
            }
            throw LocalAIWebsiteModelCatalogError.invalidResponse
        }

        let sorted = deduped.sorted { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt {
                return lhs.modifiedAt > rhs.modifiedAt
            }
            if lhs.sizeBytes != rhs.sizeBytes {
                return lhs.sizeBytes < rhs.sizeBytes
            }
            return lhs.option.id.localizedCaseInsensitiveCompare(rhs.option.id) == .orderedAscending
        }

        let capped = limit > 0 ? Array(sorted.prefix(limit)) : sorted
        return capped.map(\.option)
    }

    private func fetchAPIEndpointCandidates() async throws -> [WebsiteModelCandidate] {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await performRequest(request, timeoutSeconds: 20)
        guard let http = response as? HTTPURLResponse else {
            throw LocalAIWebsiteModelCatalogError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw LocalAIWebsiteModelCatalogError.requestFailed(
                statusCode: http.statusCode,
                detail: Self.providerErrorDetail(from: data) ?? "request failed"
            )
        }

        let payload = try JSONDecoder().decode(WebsiteTagsResponse.self, from: data)
        return payload.models.compactMap(Self.smallCandidate(from:))
    }

    private func fetchFamilyPageCandidates() async -> [WebsiteModelCandidate] {
        let familySlugs = Self.targetFamilySlugs()
        guard !familySlugs.isEmpty else { return [] }

        return await withTaskGroup(of: [WebsiteModelCandidate].self, returning: [WebsiteModelCandidate].self) { group in
            for familySlug in familySlugs {
                group.addTask {
                    do {
                        let url = Self.libraryTagsURL(forFamilySlug: familySlug)
                        var request = URLRequest(url: url)
                        request.httpMethod = "GET"
                        request.timeoutInterval = 15
                        request.setValue("text/html", forHTTPHeaderField: "Accept")
                        let (data, response) = try await performRequest(request, timeoutSeconds: 15)
                        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                            return []
                        }
                        guard let html = String(data: data, encoding: .utf8), !html.isEmpty else {
                            return []
                        }
                        return Self.parseFamilyTagCandidates(from: html, familySlug: familySlug)
                    } catch {
                        return []
                    }
                }
            }

            var merged: [WebsiteModelCandidate] = []
            for await pageCandidates in group {
                merged.append(contentsOf: pageCandidates)
            }
            return merged
        }
    }

    private static func smallCandidate(from model: WebsiteTagModel) -> WebsiteModelCandidate? {
        smallCandidate(
            modelID: model.model,
            sizeBytes: model.size,
            modifiedAt: model.modifiedAt,
            summary: "Fetched from ollama.com website catalog."
        )
    }

    private static func smallCandidate(
        modelID rawModelID: String,
        sizeBytes: Int64,
        modifiedAt: String?,
        summary: String
    ) -> WebsiteModelCandidate? {
        let modelID = rawModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else { return nil }

        let normalizedID = modelID.lowercased()
        guard !normalizedID.hasSuffix(":latest") else { return nil }
        guard !normalizedID.contains("-cloud") else { return nil }
        guard !excludedKeywords.contains(where: { normalizedID.contains($0) }) else { return nil }
        guard isBeginnerFriendlyVariant(normalizedID) else { return nil }

        guard sizeBytes >= minSmallModelSizeBytes, sizeBytes <= maxSmallModelSizeBytes else { return nil }
        let sizeInGigabytes = Double(sizeBytes) / 1_000_000_000

        let option = LocalAIModelOption(
            id: modelID,
            displayName: displayName(for: modelID),
            sizeLabel: String(format: "~%.1f GB", sizeInGigabytes),
            performanceLabel: performanceLabel(forGigabytes: sizeInGigabytes),
            summary: summary,
            isRecommended: false
        )
        return WebsiteModelCandidate(
            option: option,
            modifiedAt: parseDate(modifiedAt),
            sizeBytes: sizeBytes
        )
    }

    private static func parseFamilyTagCandidates(
        from html: String,
        familySlug: String
    ) -> [WebsiteModelCandidate] {
        guard let modelAnchorRegex = try? NSRegularExpression(
            pattern: #"<a href="/library/([^"]+:[^"]+)"[^>]*>"#,
            options: [.caseInsensitive]
        ),
        let sizeRegex = try? NSRegularExpression(
            pattern: #"([0-9]+(?:\.[0-9]+)?)([MG])B"#,
            options: [.caseInsensitive]
        ) else {
            return []
        }

        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let modelMatches = modelAnchorRegex.matches(in: html, options: [], range: fullRange)
        guard !modelMatches.isEmpty else { return [] }

        var candidatesByModelID: [String: WebsiteModelCandidate] = [:]
        candidatesByModelID.reserveCapacity(modelMatches.count)

        for match in modelMatches {
            guard match.numberOfRanges >= 2 else { continue }
            guard let modelRange = Range(match.range(at: 1), in: html),
                  let endOfAnchorRange = Range(match.range, in: html) else {
                continue
            }

            let modelID = String(html[modelRange])
            let windowStart = endOfAnchorRange.upperBound
            let windowEnd = html.index(windowStart, offsetBy: 1_500, limitedBy: html.endIndex) ?? html.endIndex
            guard windowStart < windowEnd else { continue }
            let window = String(html[windowStart..<windowEnd])
            let windowRange = NSRange(window.startIndex..<window.endIndex, in: window)
            guard let sizeMatch = sizeRegex.firstMatch(in: window, options: [], range: windowRange),
                  sizeMatch.numberOfRanges >= 3,
                  let sizeRange = Range(sizeMatch.range(at: 1), in: window),
                  let unitRange = Range(sizeMatch.range(at: 2), in: window) else {
                continue
            }

            let rawSize = String(window[sizeRange])
            let unit = String(window[unitRange]).uppercased()
            guard let magnitude = Double(rawSize) else { continue }

            let multiplier: Double
            switch unit {
            case "G":
                multiplier = 1_000_000_000
            case "M":
                multiplier = 1_000_000
            default:
                continue
            }
            let bytes = Int64(magnitude * multiplier)
            let summary = "Fetched from ollama.com/\(familySlug) tags page."
            if let candidate = smallCandidate(
                modelID: modelID,
                sizeBytes: bytes,
                modifiedAt: nil,
                summary: summary
            ) {
                let dedupeKey = modelID.lowercased()
                if let existing = candidatesByModelID[dedupeKey] {
                    if isPreferred(candidate, over: existing) {
                        candidatesByModelID[dedupeKey] = candidate
                    }
                } else {
                    candidatesByModelID[dedupeKey] = candidate
                }
            }
        }
        return Array(candidatesByModelID.values)
    }

    private static func dedupeCandidates(_ candidates: [WebsiteModelCandidate]) -> [WebsiteModelCandidate] {
        var bestByID: [String: WebsiteModelCandidate] = [:]
        bestByID.reserveCapacity(candidates.count)

        for candidate in candidates {
            let key = candidate.option.id.lowercased()
            guard let existing = bestByID[key] else {
                bestByID[key] = candidate
                continue
            }
            if isPreferred(candidate, over: existing) {
                bestByID[key] = candidate
            }
        }
        return Array(bestByID.values)
    }

    private static func isPreferred(_ lhs: WebsiteModelCandidate, over rhs: WebsiteModelCandidate) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt {
            return lhs.modifiedAt > rhs.modifiedAt
        }
        return lhs.sizeBytes < rhs.sizeBytes
    }

    private static func targetFamilySlugs() -> [String] {
        var slugs = Set<String>()
        for option in LocalAIModelCatalog.curatedModels {
            if let slug = familySlug(fromModelID: option.id) {
                slugs.insert(slug)
            }
        }
        for slug in supplementalFamilySlugs {
            slugs.insert(slug)
        }
        return slugs.sorted()
    }

    private static func familySlug(fromModelID modelID: String) -> String? {
        let normalized = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        guard let family = normalized.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true).first else {
            return nil
        }
        let slug = String(family).trimmingCharacters(in: .whitespacesAndNewlines)
        return slug.isEmpty ? nil : slug
    }

    private static func libraryTagsURL(forFamilySlug familySlug: String) -> URL {
        libraryBaseURL
            .appendingPathComponent(familySlug, isDirectory: false)
            .appendingPathComponent("tags", isDirectory: false)
    }

    private static func isBeginnerFriendlyVariant(_ normalizedModelID: String) -> Bool {
        guard let separatorIndex = normalizedModelID.firstIndex(of: ":") else {
            return true
        }
        let variant = String(normalizedModelID[normalizedModelID.index(after: separatorIndex)...])
        guard !variant.isEmpty else { return true }

        let disallowedMarkers = [
            "q2",
            "q3",
            "q4",
            "q5",
            "q6",
            "q8",
            "fp16",
            "bf16",
            "_",
            "-it",
            "instruct",
            "thinking",
            "reasoning"
        ]
        return !disallowedMarkers.contains(where: { variant.contains($0) })
    }

    private static func parseDate(_ rawValue: String?) -> Date {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !rawValue.isEmpty else {
            return .distantPast
        }
        let withFractionalSeconds = ISO8601DateFormatter()
        withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractionalSeconds.date(from: rawValue) {
            return date
        }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: rawValue) ?? .distantPast
    }

    private static func performanceLabel(forGigabytes sizeInGigabytes: Double) -> String {
        switch sizeInGigabytes {
        case ..<4:
            return "Very Fast"
        case ..<9:
            return "Fast"
        default:
            return "Balanced"
        }
    }

    private static func displayName(for modelID: String) -> String {
        let cleaned = modelID
            .replacingOccurrences(of: ":", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        let tokens = cleaned.split(whereSeparator: \.isWhitespace).map { token in
            let text = String(token)
            if text.hasSuffix("b"), text.dropLast().allSatisfy(\.isNumber) {
                return "\(text.dropLast())B"
            }
            if text.hasSuffix("m"), text.dropLast().allSatisfy(\.isNumber) {
                return "\(text.dropLast())M"
            }
            if text.allSatisfy(\.isNumber) {
                return text
            }
            return text.prefix(1).uppercased() + text.dropFirst()
        }
        let prettyName = tokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return prettyName.isEmpty ? modelID : prettyName
    }

    private func performRequest(
        _ request: URLRequest,
        timeoutSeconds: Double
    ) async throws -> (Data, URLResponse) {
        try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask { [session] in
                try await session.data(for: request)
            }
            group.addTask {
                let timeoutNanoseconds = UInt64(max(1, timeoutSeconds) * 1_000_000_000)
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw URLError(.timedOut)
            }

            guard let firstResult = try await group.next() else {
                throw URLError(.unknown)
            }
            group.cancelAll()
            return firstResult
        }
    }

    private static func providerErrorDetail(from data: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data, options: []),
           let dict = object as? [String: Any] {
            if let message = dict["message"] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message
            }
            if let error = dict["error"] as? [String: Any],
               let message = error["message"] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message
            }
            if let error = dict["error"] as? String,
               !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return error
            }
        }
        if let plainText = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !plainText.isEmpty {
            return plainText
        }
        return nil
    }
}

private struct WebsiteTagsResponse: Decodable {
    let models: [WebsiteTagModel]
}

private struct WebsiteTagModel: Decodable {
    let model: String
    let size: Int64
    let modifiedAt: String?

    enum CodingKeys: String, CodingKey {
        case model
        case size
        case modifiedAt = "modified_at"
    }
}

private struct WebsiteModelCandidate {
    let option: LocalAIModelOption
    let modifiedAt: Date
    let sizeBytes: Int64
}
