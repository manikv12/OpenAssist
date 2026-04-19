import Foundation

struct TelegramUser: Decodable, Sendable {
    let id: Int64
    let isBot: Bool?
    let firstName: String
    let lastName: String?
    let username: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case isBot = "is_bot"
        case firstName = "first_name"
        case lastName = "last_name"
        case username
    }

    var displayName: String {
        let parts = [firstName, lastName].compactMap { value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        if !parts.isEmpty {
            return parts.joined(separator: " ")
        }
        if let username, !username.isEmpty {
            return "@\(username)"
        }
        return String(id)
    }
}

struct TelegramChat: Decodable, Sendable {
    let id: Int64
    let type: String
    let title: String?
    let username: String?
    let firstName: String?
    let lastName: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case title
        case username
        case firstName = "first_name"
        case lastName = "last_name"
    }
}

struct TelegramVoice: Decodable, Sendable {
    let fileID: String
    let duration: Int
    let mimeType: String?
    let fileSize: Int?

    private enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case duration
        case mimeType = "mime_type"
        case fileSize = "file_size"
    }
}

struct TelegramAudio: Decodable, Sendable {
    let fileID: String
    let duration: Int?
    let fileName: String?
    let mimeType: String?
    let fileSize: Int?
    let title: String?
    let performer: String?

    private enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case duration
        case fileName = "file_name"
        case mimeType = "mime_type"
        case fileSize = "file_size"
        case title
        case performer
    }
}

struct TelegramDocument: Decodable, Sendable {
    let fileID: String
    let fileName: String?
    let mimeType: String?
    let fileSize: Int?

    private enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case fileName = "file_name"
        case mimeType = "mime_type"
        case fileSize = "file_size"
    }
}

struct TelegramFile: Decodable, Sendable {
    let fileID: String?
    let fileUniqueID: String?
    let filePath: String?
    let fileSize: Int?

    private enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case fileUniqueID = "file_unique_id"
        case filePath = "file_path"
        case fileSize = "file_size"
    }
}

struct TelegramMessage: Decodable, Sendable {
    let messageID: Int
    let chat: TelegramChat
    let from: TelegramUser?
    let date: Int
    let text: String?
    let voice: TelegramVoice?
    let audio: TelegramAudio?
    let document: TelegramDocument?
    let caption: String?

    private enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case chat
        case from
        case date
        case text
        case voice
        case audio
        case document
        case caption
    }
}

struct TelegramCallbackQuery: Decodable, Sendable {
    let id: String
    let from: TelegramUser
    let message: TelegramMessage?
    let data: String?
}

struct TelegramUpdate: Decodable, Sendable {
    let updateID: Int
    let message: TelegramMessage?
    let callbackQuery: TelegramCallbackQuery?

    private enum CodingKeys: String, CodingKey {
        case updateID = "update_id"
        case message
        case callbackQuery = "callback_query"
    }
}

struct TelegramInlineKeyboardButton: Encodable, Sendable {
    let text: String
    let callbackData: String?

    init(text: String, callbackData: String?) {
        self.text = text
        self.callbackData = callbackData
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case callbackData = "callback_data"
    }
}

struct TelegramInlineKeyboardMarkup: Encodable, Sendable {
    let inlineKeyboard: [[TelegramInlineKeyboardButton]]

    private enum CodingKeys: String, CodingKey {
        case inlineKeyboard = "inline_keyboard"
    }
}

struct TelegramBotCommand: Encodable, Sendable {
    let command: String
    let description: String
}

enum TelegramParseMode: String, Sendable {
    case html = "HTML"
}

private struct TelegramAPIEnvelope<Result: Decodable>: Decodable {
    let ok: Bool
    let result: Result?
    let description: String?
}

enum TelegramBotClientError: LocalizedError {
    case invalidToken
    case invalidRequest
    case server(message: String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .invalidToken:
            return "Telegram bot token is missing or invalid."
        case .invalidRequest:
            return "Telegram request could not be created."
        case .server(let message):
            return message
        case .malformedResponse:
            return "Telegram returned an unexpected response."
        }
    }
}

final class TelegramBotClient {
    private let token: String
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(
        token: String,
        session: URLSession = .shared
    ) {
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    func getMe() async throws -> TelegramUser {
        try await perform(method: "getMe", payload: nil, responseType: TelegramUser.self)
    }

    func getUpdates(offset: Int, timeout: Int) async throws -> [TelegramUpdate] {
        try await perform(
            method: "getUpdates",
            payload: [
                "offset": offset,
                "timeout": timeout,
                "allowed_updates": ["message", "callback_query"]
            ],
            responseType: [TelegramUpdate].self
        )
    }

    func getFile(fileID: String) async throws -> TelegramFile {
        try await perform(
            method: "getFile",
            payload: ["file_id": fileID],
            responseType: TelegramFile.self
        )
    }

    func downloadFile(filePath: String) async throws -> Data {
        let url = try fileDownloadURL(filePath: filePath)
        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TelegramBotClientError.malformedResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let excerpt = sanitizedResponseExcerpt(from: data)
            let message = excerpt.isEmpty
                ? "Telegram file download failed with HTTP \(httpResponse.statusCode)."
                : "Telegram file download failed with HTTP \(httpResponse.statusCode): \(excerpt)"
            throw TelegramBotClientError.server(message: message)
        }
        return data
    }

    @discardableResult
    func setMyCommands(_ commands: [TelegramBotCommand]) async throws -> Bool {
        let payload = try [
            "commands": commandDictionaries(commands)
        ]
        return try await perform(method: "setMyCommands", payload: payload, responseType: Bool.self)
    }

    @discardableResult
    func sendMessage(
        chatID: Int64,
        text: String,
        parseMode: TelegramParseMode? = nil,
        replyMarkup: TelegramInlineKeyboardMarkup? = nil,
        disableNotification: Bool = false
    ) async throws -> TelegramMessage {
        var payload: [String: Any] = [
            "chat_id": chatID,
            "text": text,
            "disable_web_page_preview": true
        ]
        if disableNotification {
            payload["disable_notification"] = true
        }
        if let parseMode {
            payload["parse_mode"] = parseMode.rawValue
        }
        if let replyMarkup {
            payload["reply_markup"] = try replyMarkupDictionary(replyMarkup)
        }
        return try await perform(method: "sendMessage", payload: payload, responseType: TelegramMessage.self)
    }

    @discardableResult
    func sendPhoto(
        chatID: Int64,
        data: Data,
        filename: String,
        mimeType: String,
        caption: String? = nil,
        parseMode: TelegramParseMode? = nil
    ) async throws -> TelegramMessage {
        var fields = [
            "chat_id": String(chatID)
        ]
        if let caption = caption?.trimmingCharacters(in: .whitespacesAndNewlines),
           !caption.isEmpty {
            fields["caption"] = caption
        }
        if let parseMode {
            fields["parse_mode"] = parseMode.rawValue
        }
        return try await performMultipart(
            method: "sendPhoto",
            fields: fields,
            fileFieldName: "photo",
            filename: filename,
            mimeType: mimeType,
            fileData: data,
            responseType: TelegramMessage.self
        )
    }

    @discardableResult
    func sendDocument(
        chatID: Int64,
        data: Data,
        filename: String,
        mimeType: String,
        caption: String? = nil,
        parseMode: TelegramParseMode? = nil
    ) async throws -> TelegramMessage {
        var fields = [
            "chat_id": String(chatID)
        ]
        if let caption = caption?.trimmingCharacters(in: .whitespacesAndNewlines),
           !caption.isEmpty {
            fields["caption"] = caption
        }
        if let parseMode {
            fields["parse_mode"] = parseMode.rawValue
        }
        return try await performMultipart(
            method: "sendDocument",
            fields: fields,
            fileFieldName: "document",
            filename: filename,
            mimeType: mimeType,
            fileData: data,
            responseType: TelegramMessage.self
        )
    }

    @discardableResult
    func editMessageText(
        chatID: Int64,
        messageID: Int,
        text: String,
        parseMode: TelegramParseMode? = nil,
        replyMarkup: TelegramInlineKeyboardMarkup? = nil
    ) async throws -> TelegramMessage {
        var payload: [String: Any] = [
            "chat_id": chatID,
            "message_id": messageID,
            "text": text,
            "disable_web_page_preview": true
        ]
        if let parseMode {
            payload["parse_mode"] = parseMode.rawValue
        }
        if let replyMarkup {
            payload["reply_markup"] = try replyMarkupDictionary(replyMarkup)
        }
        return try await perform(method: "editMessageText", payload: payload, responseType: TelegramMessage.self)
    }

    @discardableResult
    func sendMessageDraft(
        chatID: Int64,
        draftID: Int,
        text: String,
        parseMode: TelegramParseMode? = nil
    ) async throws -> Bool {
        var payload: [String: Any] = [
            "chat_id": chatID,
            "draft_id": draftID,
            "text": text
        ]
        if let parseMode {
            payload["parse_mode"] = parseMode.rawValue
        }
        return try await perform(method: "sendMessageDraft", payload: payload, responseType: Bool.self)
    }

    @discardableResult
    func deleteMessage(chatID: Int64, messageID: Int) async throws -> Bool {
        try await perform(
            method: "deleteMessage",
            payload: [
                "chat_id": chatID,
                "message_id": messageID
            ],
            responseType: Bool.self
        )
    }

    @discardableResult
    func answerCallbackQuery(
        callbackQueryID: String,
        text: String? = nil,
        showAlert: Bool = false
    ) async throws -> Bool {
        var payload: [String: Any] = [
            "callback_query_id": callbackQueryID,
            "show_alert": showAlert
        ]
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["text"] = text
        }
        return try await perform(method: "answerCallbackQuery", payload: payload, responseType: Bool.self)
    }

    @discardableResult
    func sendChatAction(chatID: Int64, action: String) async throws -> Bool {
        try await perform(
            method: "sendChatAction",
            payload: [
                "chat_id": chatID,
                "action": action
            ],
            responseType: Bool.self
        )
    }

    private func perform<Result: Decodable>(
        method: String,
        payload: [String: Any]?,
        responseType: Result.Type
    ) async throws -> Result {
        guard !token.isEmpty else {
            throw TelegramBotClientError.invalidToken
        }

        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else {
            throw TelegramBotClientError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let payload {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        }

        let (data, response) = try await session.data(for: request)
        let validatedData = try validatedResponseData(
            data: data,
            response: response,
            method: method
        )
        let envelope = try decoder.decode(TelegramAPIEnvelope<Result>.self, from: validatedData)

        if envelope.ok, let result = envelope.result {
            return result
        }

        let message = envelope.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        if method == "editMessageText",
           message?.localizedCaseInsensitiveContains("message is not modified") == true {
            throw TelegramBotClientError.server(message: "message is not modified")
        }
        throw TelegramBotClientError.server(message: message ?? TelegramBotClientError.malformedResponse.localizedDescription)
    }

    private func performMultipart<Result: Decodable>(
        method: String,
        fields: [String: String],
        fileFieldName: String,
        filename: String,
        mimeType: String,
        fileData: Data,
        responseType: Result.Type
    ) async throws -> Result {
        guard !token.isEmpty else {
            throw TelegramBotClientError.invalidToken
        }

        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else {
            throw TelegramBotClientError.invalidRequest
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(
            boundary: boundary,
            fields: fields,
            fileFieldName: fileFieldName,
            filename: filename,
            mimeType: mimeType,
            fileData: fileData
        )

        let (data, response) = try await session.data(for: request)
        let validatedData = try validatedResponseData(
            data: data,
            response: response,
            method: method
        )
        let envelope = try decoder.decode(TelegramAPIEnvelope<Result>.self, from: validatedData)

        if envelope.ok, let result = envelope.result {
            return result
        }

        let message = envelope.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        throw TelegramBotClientError.server(message: message ?? TelegramBotClientError.malformedResponse.localizedDescription)
    }

    private func multipartBody(
        boundary: String,
        fields: [String: String],
        fileFieldName: String,
        filename: String,
        mimeType: String,
        fileData: Data
    ) -> Data {
        var body = Data()
        let lineBreak = "\r\n"

        for key in fields.keys.sorted() {
            guard let value = fields[key] else { continue }
            body.append("--\(boundary)\(lineBreak)")
            body.append("Content-Disposition: form-data; name=\"\(key)\"\(lineBreak)\(lineBreak)")
            body.append("\(value)\(lineBreak)")
        }

        body.append("--\(boundary)\(lineBreak)")
        body.append("Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(filename)\"\(lineBreak)")
        body.append("Content-Type: \(mimeType)\(lineBreak)\(lineBreak)")
        body.append(fileData)
        body.append(lineBreak)
        body.append("--\(boundary)--\(lineBreak)")
        return body
    }

    private func replyMarkupDictionary(_ markup: TelegramInlineKeyboardMarkup) throws -> [String: Any] {
        let data = try JSONEncoder().encode(markup)
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dictionary = object as? [String: Any] else {
            throw TelegramBotClientError.malformedResponse
        }
        return dictionary
    }

    private func commandDictionaries(_ commands: [TelegramBotCommand]) throws -> [[String: Any]] {
        let data = try JSONEncoder().encode(commands)
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dictionaries = object as? [[String: Any]] else {
            throw TelegramBotClientError.malformedResponse
        }
        return dictionaries
    }

    private func validatedResponseData(
        data: Data,
        response: URLResponse,
        method: String
    ) throws -> Data {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TelegramBotClientError.malformedResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let excerpt = sanitizedResponseExcerpt(from: data)
            let message = excerpt.isEmpty
                ? "Telegram \(method) failed with HTTP \(httpResponse.statusCode)."
                : "Telegram \(method) failed with HTTP \(httpResponse.statusCode): \(excerpt)"
            throw TelegramBotClientError.server(message: message)
        }
        return data
    }

    private func fileDownloadURL(filePath: String) throws -> URL {
        guard !token.isEmpty else {
            throw TelegramBotClientError.invalidToken
        }

        let trimmedPath = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw TelegramBotClientError.invalidRequest
        }

        let encodedPath = trimmedPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmedPath
        guard let url = URL(string: "https://api.telegram.org/file/bot\(token)/\(encodedPath)") else {
            throw TelegramBotClientError.invalidRequest
        }
        return url
    }

    private func sanitizedResponseExcerpt(from data: Data) -> String {
        guard let rawText = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawText.isEmpty else {
            return ""
        }

        let collapsed = rawText.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        return String(collapsed.prefix(240))
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
