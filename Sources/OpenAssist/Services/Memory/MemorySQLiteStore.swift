import Foundation
import SQLite3

private let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum MemorySQLiteStoreError: LocalizedError {
    case failedToCreateDirectory(path: String)
    case failedToOpenDatabase(path: String, code: Int32, message: String)
    case failedToPrepareStatement(sql: String, code: Int32, message: String)
    case failedToExecuteStatement(sql: String, code: Int32, message: String)
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case invalidDatabaseState

    var errorDescription: String? {
        switch self {
        case let .failedToCreateDirectory(path):
            return "Unable to create memory database directory: \(path)"
        case let .failedToOpenDatabase(path, code, message):
            return "Unable to open memory database at \(path) (code: \(code)): \(message)"
        case let .failedToPrepareStatement(sql, code, message):
            return "Unable to prepare SQL statement (code: \(code)): \(message)\nSQL: \(sql)"
        case let .failedToExecuteStatement(sql, code, message):
            return "Unable to execute SQL statement (code: \(code)): \(message)\nSQL: \(sql)"
        case let .unsupportedSchemaVersion(found, supported):
            return "Memory database schema version \(found) is newer than this app supports (\(supported))."
        case .invalidDatabaseState:
            return "Memory database is not available."
        }
    }
}

final class MemorySQLiteStore {
    private static let schemaVersion = 8
    private static let cleanupUnknownIssueKey = "issue-unassigned"
    private static let cleanupNoiseIssueKey = "issue-noise"
    private static let expiredContextDefaultRetentionDays = 30
    private static let expiredContextDefaultMaxRows = 500
    private static let expiredContextDefaultMaxRawBytes = 100 * 1024 * 1024

    struct MetadataCleanupReport: Hashable {
        let scannedCards: Int
        let metadataUpdatedCards: Int
        let lowValueInvalidatedCards: Int
        let removableMarkedCards: Int
        let removedCards: Int
    }

    let databaseURL: URL
    private var database: OpaquePointer?
    private let lock = NSLock()

    init(databaseURL: URL? = nil, fileManager: FileManager = .default) throws {
        if let databaseURL {
            self.databaseURL = databaseURL
        } else {
            self.databaseURL = try Self.defaultDatabaseURL(fileManager: fileManager)
        }

        try Self.ensureParentDirectory(for: self.databaseURL, fileManager: fileManager)
        try open()
        try ensureSchema()
    }

    deinit {
        close()
    }

    /// Creates a best-effort in-memory store for degraded operation when the
    /// primary database cannot be opened (disk full, permissions, corruption).
    static func fallback() -> MemorySQLiteStore {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenAssist-memory-fallback-\(UUID().uuidString).sqlite3")
        // swiftlint:disable:next force_try
        return try! MemorySQLiteStore(databaseURL: tempURL)
    }

    static func defaultDatabaseURL(fileManager: FileManager = .default) throws -> URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw MemorySQLiteStoreError.failedToCreateDirectory(path: "\(NSHomeDirectory())/Library/Application Support")
        }

        return appSupport
            .appendingPathComponent("OpenAssist", isDirectory: true)
            .appendingPathComponent("Memory", isDirectory: true)
            .appendingPathComponent("memory.sqlite3")
    }

    func ensureSchema() throws {
        try execute(sql: "PRAGMA journal_mode=WAL;")
        try execute(sql: "PRAGMA foreign_keys=ON;")

        try execute(sql: """
        CREATE TABLE IF NOT EXISTS memory_schema_meta (
            id INTEGER PRIMARY KEY CHECK(id = 1),
            schema_version INTEGER NOT NULL,
            updated_at REAL NOT NULL
        );
        """)

        if let existingSchemaVersion = try fetchSchemaVersion(),
           existingSchemaVersion > Self.schemaVersion {
            throw MemorySQLiteStoreError.unsupportedSchemaVersion(
                found: existingSchemaVersion,
                supported: Self.schemaVersion
            )
        }

        try execute(sql: """
        INSERT INTO memory_schema_meta (id, schema_version, updated_at)
        VALUES (1, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            schema_version = excluded.schema_version,
            updated_at = excluded.updated_at;
        """, bind: { statement in
            self.bind(Int64(Self.schemaVersion), at: 1, in: statement)
            self.bind(Date().timeIntervalSince1970, at: 2, in: statement)
        })

        try execute(sql: """
        CREATE TABLE IF NOT EXISTS memory_sources (
            id TEXT PRIMARY KEY NOT NULL,
            provider TEXT NOT NULL,
            root_path TEXT NOT NULL,
            display_name TEXT NOT NULL,
            discovered_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            metadata_json TEXT NOT NULL DEFAULT '{}'
        );
        """)

        try execute(sql: """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_memory_sources_provider_root
            ON memory_sources(provider, root_path);
        """)

        try execute(sql: """
        CREATE TABLE IF NOT EXISTS memory_files (
            id TEXT PRIMARY KEY NOT NULL,
            source_id TEXT NOT NULL REFERENCES memory_sources(id) ON DELETE CASCADE,
            absolute_path TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            file_hash TEXT NOT NULL,
            file_size_bytes INTEGER NOT NULL DEFAULT 0,
            modified_at REAL NOT NULL,
            indexed_at REAL NOT NULL,
            parse_error TEXT,
            UNIQUE(source_id, relative_path)
        );
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_memory_files_source
            ON memory_files(source_id, modified_at DESC);
        """)

        try execute(sql: """
        CREATE TABLE IF NOT EXISTS memory_events (
            id TEXT PRIMARY KEY NOT NULL,
            source_id TEXT NOT NULL REFERENCES memory_sources(id) ON DELETE CASCADE,
            source_file_id TEXT NOT NULL REFERENCES memory_files(id) ON DELETE CASCADE,
            provider TEXT NOT NULL,
            kind TEXT NOT NULL,
            title TEXT NOT NULL,
            body TEXT NOT NULL,
            event_timestamp REAL NOT NULL,
            native_summary TEXT,
            keywords_json TEXT NOT NULL DEFAULT '[]',
            is_plan_content INTEGER NOT NULL DEFAULT 0,
            metadata_json TEXT NOT NULL DEFAULT '{}',
            raw_payload TEXT,
            updated_at REAL NOT NULL
        );
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_memory_events_source_file
            ON memory_events(source_file_id, event_timestamp DESC);
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_memory_events_plan
            ON memory_events(is_plan_content, event_timestamp DESC);
        """)

        try execute(sql: """
        CREATE TABLE IF NOT EXISTS memory_cards (
            id TEXT PRIMARY KEY NOT NULL,
            source_id TEXT NOT NULL REFERENCES memory_sources(id) ON DELETE CASCADE,
            source_file_id TEXT NOT NULL REFERENCES memory_files(id) ON DELETE CASCADE,
            event_id TEXT NOT NULL REFERENCES memory_events(id) ON DELETE CASCADE,
            provider TEXT NOT NULL,
            title TEXT NOT NULL,
            summary TEXT NOT NULL,
            detail TEXT NOT NULL,
            keywords_json TEXT NOT NULL DEFAULT '[]',
            score REAL NOT NULL DEFAULT 0,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            is_plan_content INTEGER NOT NULL DEFAULT 0,
            metadata_json TEXT NOT NULL DEFAULT '{}'
        );
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_memory_cards_rewrite
            ON memory_cards(provider, is_plan_content, score DESC, updated_at DESC);
        """)

        try execute(sql: """
        CREATE TABLE IF NOT EXISTS memory_links (
            id TEXT PRIMARY KEY NOT NULL,
            from_card_id TEXT NOT NULL REFERENCES memory_cards(id) ON DELETE CASCADE,
            to_card_id TEXT NOT NULL REFERENCES memory_cards(id) ON DELETE CASCADE,
            link_type TEXT NOT NULL,
            confidence REAL NOT NULL DEFAULT 0,
            metadata_json TEXT NOT NULL DEFAULT '{}',
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            UNIQUE(from_card_id, to_card_id)
        );
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_memory_links_from_confidence
            ON memory_links(from_card_id, confidence DESC, updated_at DESC);
        """)

        try execute(sql: """
        CREATE TABLE IF NOT EXISTS memory_lessons (
            id TEXT PRIMARY KEY NOT NULL,
            source_id TEXT NOT NULL REFERENCES memory_sources(id) ON DELETE CASCADE,
            source_file_id TEXT NOT NULL REFERENCES memory_files(id) ON DELETE CASCADE,
            event_id TEXT NOT NULL REFERENCES memory_events(id) ON DELETE CASCADE,
            card_id TEXT NOT NULL REFERENCES memory_cards(id) ON DELETE CASCADE,
            provider TEXT NOT NULL,
            mistake_pattern TEXT NOT NULL,
            improved_prompt TEXT NOT NULL,
            rationale TEXT NOT NULL,
            validation_confidence REAL NOT NULL DEFAULT 0,
            source_metadata_json TEXT NOT NULL DEFAULT '{}',
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            UNIQUE(card_id)
        );
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_memory_lessons_lookup
            ON memory_lessons(provider, validation_confidence DESC, updated_at DESC);
        """)

        try execute(sql: """
        CREATE TABLE IF NOT EXISTS rewrite_suggestions (
            id TEXT PRIMARY KEY NOT NULL,
            card_id TEXT NOT NULL REFERENCES memory_cards(id) ON DELETE CASCADE,
            provider TEXT NOT NULL,
            original_text TEXT NOT NULL,
            suggested_text TEXT NOT NULL,
            rationale TEXT NOT NULL,
            confidence REAL NOT NULL,
            created_at REAL NOT NULL
        );
        """)

        try execute(sql: """
        CREATE TABLE IF NOT EXISTS memory_pattern_stats (
            pattern_key TEXT PRIMARY KEY NOT NULL,
            scope_key TEXT NOT NULL,
            app_name TEXT NOT NULL,
            bundle_id TEXT NOT NULL,
            surface_label TEXT NOT NULL,
            project_name TEXT,
            repository_name TEXT,
            occurrence_count INTEGER NOT NULL DEFAULT 0,
            good_repeat_count INTEGER NOT NULL DEFAULT 0,
            bad_repeat_count INTEGER NOT NULL DEFAULT 0,
            first_seen_at REAL NOT NULL,
            last_seen_at REAL NOT NULL,
            last_outcome TEXT NOT NULL DEFAULT 'neutral',
            confidence REAL NOT NULL DEFAULT 0,
            metadata_json TEXT NOT NULL DEFAULT '{}'
        );
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_pattern_scope_last_seen
            ON memory_pattern_stats(scope_key, last_seen_at DESC);
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_pattern_bundle_project
            ON memory_pattern_stats(bundle_id, project_name, last_seen_at DESC);
        """)

        try execute(sql: """
        CREATE TABLE IF NOT EXISTS memory_pattern_occurrences (
            id TEXT PRIMARY KEY NOT NULL,
            pattern_key TEXT NOT NULL REFERENCES memory_pattern_stats(pattern_key) ON DELETE CASCADE,
            card_id TEXT,
            lesson_id TEXT,
            event_timestamp REAL NOT NULL,
            outcome TEXT NOT NULL DEFAULT 'neutral',
            trigger TEXT NOT NULL,
            metadata_json TEXT NOT NULL DEFAULT '{}'
        );
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_occurrence_pattern_time
            ON memory_pattern_occurrences(pattern_key, event_timestamp DESC);
        """)

        try execute(sql: """
        CREATE TABLE IF NOT EXISTS conversation_threads (
            id TEXT PRIMARY KEY NOT NULL,
            app_name TEXT NOT NULL,
            bundle_id TEXT NOT NULL,
            logical_surface_key TEXT NOT NULL,
            screen_label TEXT NOT NULL,
            field_label TEXT NOT NULL,
            project_key TEXT NOT NULL,
            project_label TEXT NOT NULL,
            identity_key TEXT NOT NULL,
            identity_type TEXT NOT NULL,
            identity_label TEXT NOT NULL,
            native_thread_key TEXT NOT NULL DEFAULT '',
            people_json TEXT NOT NULL DEFAULT '[]',
            running_summary TEXT NOT NULL DEFAULT '',
            total_exchange_turns INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL,
            last_activity_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """)

        try execute(sql: """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_conversation_threads_tuple
            ON conversation_threads(bundle_id, logical_surface_key, project_key, identity_key, native_thread_key);
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_conversation_threads_last_activity
            ON conversation_threads(last_activity_at DESC);
        """)

        try execute(sql: """
        CREATE TABLE IF NOT EXISTS conversation_turns (
            id TEXT PRIMARY KEY NOT NULL,
            thread_id TEXT NOT NULL REFERENCES conversation_threads(id) ON DELETE CASCADE,
            role TEXT NOT NULL,
            user_text TEXT NOT NULL DEFAULT '',
            assistant_text TEXT NOT NULL DEFAULT '',
            normalized_text TEXT NOT NULL,
            is_summary INTEGER NOT NULL DEFAULT 0,
            source_turn_count INTEGER NOT NULL DEFAULT 1,
            compaction_version INTEGER,
            metadata_json TEXT NOT NULL DEFAULT '{}',
            created_at REAL NOT NULL,
            turn_dedupe_key TEXT NOT NULL
        );
        """)

        try execute(sql: """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_conversation_turns_dedupe
            ON conversation_turns(turn_dedupe_key);
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_conversation_turns_thread_created
            ON conversation_turns(thread_id, created_at DESC);
        """)

        try execute(sql: """
        CREATE TABLE IF NOT EXISTS conversation_thread_redirects (
            old_thread_id TEXT PRIMARY KEY NOT NULL,
            new_thread_id TEXT NOT NULL,
            reason TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        """)

        try execute(sql: """
        CREATE TABLE IF NOT EXISTS conversation_tag_aliases (
            alias_type TEXT NOT NULL,
            alias_key TEXT NOT NULL,
            canonical_key TEXT NOT NULL,
            updated_at REAL NOT NULL,
            PRIMARY KEY(alias_type, alias_key)
        );
        """)

        try execute(sql: """
        CREATE TABLE IF NOT EXISTS conversation_disambiguation_rules (
            id TEXT PRIMARY KEY NOT NULL,
            rule_type TEXT NOT NULL,
            app_pair_key TEXT NOT NULL,
            subject_key TEXT NOT NULL,
            context_scope_key TEXT,
            decision TEXT NOT NULL,
            canonical_key TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """)

        try execute(sql: """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_conversation_disambiguation_scope
            ON conversation_disambiguation_rules(
                rule_type,
                app_pair_key,
                subject_key,
                ifnull(context_scope_key, '')
            );
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_conversation_disambiguation_subject
            ON conversation_disambiguation_rules(rule_type, app_pair_key, subject_key, updated_at DESC);
        """)

        try execute(sql: """
        CREATE TABLE IF NOT EXISTS conversation_agent_profiles (
            thread_id TEXT PRIMARY KEY NOT NULL REFERENCES conversation_threads(id) ON DELETE CASCADE,
            profile_json TEXT NOT NULL DEFAULT '{}',
            created_at REAL NOT NULL DEFAULT (strftime('%s', 'now')),
            updated_at REAL NOT NULL DEFAULT (strftime('%s', 'now')),
            expires_at REAL NOT NULL DEFAULT 253402300799
        );
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_conversation_agent_profiles_thread_expires
            ON conversation_agent_profiles(thread_id, expires_at DESC);
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_conversation_agent_profiles_expires
            ON conversation_agent_profiles(expires_at);
        """)

        try execute(sql: """
        CREATE TABLE IF NOT EXISTS conversation_agent_entities (
            thread_id TEXT PRIMARY KEY NOT NULL REFERENCES conversation_threads(id) ON DELETE CASCADE,
            entities_json TEXT NOT NULL DEFAULT '[]',
            created_at REAL NOT NULL DEFAULT (strftime('%s', 'now')),
            updated_at REAL NOT NULL DEFAULT (strftime('%s', 'now')),
            expires_at REAL NOT NULL DEFAULT 253402300799
        );
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_conversation_agent_entities_thread_expires
            ON conversation_agent_entities(thread_id, expires_at DESC);
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_conversation_agent_entities_expires
            ON conversation_agent_entities(expires_at);
        """)

        try execute(sql: """
        CREATE TABLE IF NOT EXISTS conversation_agent_preferences (
            thread_id TEXT PRIMARY KEY NOT NULL REFERENCES conversation_threads(id) ON DELETE CASCADE,
            preferences_json TEXT NOT NULL DEFAULT '{}',
            created_at REAL NOT NULL DEFAULT (strftime('%s', 'now')),
            updated_at REAL NOT NULL DEFAULT (strftime('%s', 'now')),
            expires_at REAL NOT NULL DEFAULT 253402300799
        );
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_conversation_agent_preferences_thread_expires
            ON conversation_agent_preferences(thread_id, expires_at DESC);
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_conversation_agent_preferences_expires
            ON conversation_agent_preferences(expires_at);
        """)

        try execute(sql: """
        CREATE TABLE IF NOT EXISTS assistant_memory_entries (
            id TEXT PRIMARY KEY NOT NULL,
            provider TEXT NOT NULL,
            scope_key TEXT NOT NULL,
            bundle_id TEXT NOT NULL,
            project_key TEXT,
            identity_key TEXT,
            thread_id TEXT,
            memory_type TEXT NOT NULL,
            title TEXT NOT NULL,
            summary TEXT NOT NULL,
            detail TEXT NOT NULL,
            keywords_json TEXT NOT NULL DEFAULT '[]',
            confidence REAL NOT NULL DEFAULT 0,
            state TEXT NOT NULL DEFAULT 'active',
            metadata_json TEXT NOT NULL DEFAULT '{}',
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_assistant_memory_provider_scope
            ON assistant_memory_entries(provider, scope_key, state, updated_at DESC);
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_assistant_memory_provider_project
            ON assistant_memory_entries(provider, project_key, state, updated_at DESC);
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_assistant_memory_provider_thread
            ON assistant_memory_entries(provider, thread_id, state, updated_at DESC);
        """)

        try execute(sql: """
        CREATE TABLE IF NOT EXISTS conversation_expired_contexts (
            id TEXT PRIMARY KEY,
            scope_key TEXT NOT NULL,
            thread_id TEXT NOT NULL,
            bundle_id TEXT NOT NULL,
            project_key TEXT,
            identity_key TEXT,
            summary_text TEXT NOT NULL,
            summary_method TEXT NOT NULL,
            summary_confidence REAL,
            source_turn_count INTEGER NOT NULL,
            recent_turns_json TEXT NOT NULL,
            raw_turns_json TEXT NOT NULL,
            trigger TEXT NOT NULL,
            expired_at REAL NOT NULL,
            delete_after_at REAL NOT NULL,
            consumed_at REAL,
            consumed_by_thread_id TEXT,
            metadata_json TEXT NOT NULL DEFAULT '{}'
        );
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_expired_context_scope_recent
            ON conversation_expired_contexts(scope_key, expired_at DESC);
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_expired_context_delete_after
            ON conversation_expired_contexts(delete_after_at);
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_expired_context_unconsumed
            ON conversation_expired_contexts(scope_key, consumed_at);
        """)
    }

    func hasTable(named tableName: String) throws -> Bool {
        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name = ? LIMIT 1;"
        let results: [String] = try self.query(sql: sql, bind: { statement in
            self.bind(tableName, at: 1, in: statement)
        }, mapRow: { statement in
            self.readString(at: 0, in: statement) ?? ""
        })
        return !results.isEmpty
    }

    func upsertConversationThread(_ thread: ConversationThreadRecord) throws {
        let sql = """
        INSERT INTO conversation_threads (
            id, app_name, bundle_id, logical_surface_key, screen_label, field_label,
            project_key, project_label, identity_key, identity_type, identity_label,
            native_thread_key, people_json, running_summary, total_exchange_turns,
            created_at, last_activity_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            app_name = excluded.app_name,
            bundle_id = excluded.bundle_id,
            logical_surface_key = excluded.logical_surface_key,
            screen_label = excluded.screen_label,
            field_label = excluded.field_label,
            project_key = excluded.project_key,
            project_label = excluded.project_label,
            identity_key = excluded.identity_key,
            identity_type = excluded.identity_type,
            identity_label = excluded.identity_label,
            native_thread_key = excluded.native_thread_key,
            people_json = excluded.people_json,
            running_summary = excluded.running_summary,
            total_exchange_turns = excluded.total_exchange_turns,
            last_activity_at = excluded.last_activity_at,
            updated_at = excluded.updated_at;
        """

        try execute(sql: sql, bind: { statement in
            self.bind(thread.id, at: 1, in: statement)
            self.bind(thread.appName, at: 2, in: statement)
            self.bind(thread.bundleID, at: 3, in: statement)
            self.bind(thread.logicalSurfaceKey, at: 4, in: statement)
            self.bind(thread.screenLabel, at: 5, in: statement)
            self.bind(thread.fieldLabel, at: 6, in: statement)
            self.bind(thread.projectKey, at: 7, in: statement)
            self.bind(thread.projectLabel, at: 8, in: statement)
            self.bind(thread.identityKey, at: 9, in: statement)
            self.bind(thread.identityType, at: 10, in: statement)
            self.bind(thread.identityLabel, at: 11, in: statement)
            self.bind(thread.nativeThreadKey, at: 12, in: statement)
            self.bind(self.encodeJSON(thread.people, fallback: "[]"), at: 13, in: statement)
            self.bind(thread.runningSummary, at: 14, in: statement)
            self.bind(Int64(max(0, thread.totalExchangeTurns)), at: 15, in: statement)
            self.bind(thread.createdAt.timeIntervalSince1970, at: 16, in: statement)
            self.bind(thread.lastActivityAt.timeIntervalSince1970, at: 17, in: statement)
            self.bind(thread.updatedAt.timeIntervalSince1970, at: 18, in: statement)
        })
    }

    func fetchConversationThread(
        bundleID: String,
        logicalSurfaceKey: String,
        projectKey: String,
        identityKey: String,
        nativeThreadKey: String
    ) throws -> ConversationThreadRecord? {
        let sql = """
        SELECT
            id, app_name, bundle_id, logical_surface_key, screen_label, field_label,
            project_key, project_label, identity_key, identity_type, identity_label,
            native_thread_key, people_json, running_summary, total_exchange_turns,
            created_at, last_activity_at, updated_at
        FROM conversation_threads
        WHERE bundle_id = ?
            AND logical_surface_key = ?
            AND project_key = ?
            AND identity_key = ?
            AND native_thread_key = ?
        LIMIT 1;
        """

        let rows: [ConversationThreadRecord] = try query(sql: sql, bind: { statement in
            self.bind(bundleID, at: 1, in: statement)
            self.bind(logicalSurfaceKey, at: 2, in: statement)
            self.bind(projectKey, at: 3, in: statement)
            self.bind(identityKey, at: 4, in: statement)
            self.bind(nativeThreadKey, at: 5, in: statement)
        }, mapRow: { statement in
            ConversationThreadRecord(
                id: self.readString(at: 0, in: statement) ?? "",
                appName: self.readString(at: 1, in: statement) ?? "Unknown App",
                bundleID: self.readString(at: 2, in: statement) ?? "unknown.bundle",
                logicalSurfaceKey: self.readString(at: 3, in: statement) ?? "",
                screenLabel: self.readString(at: 4, in: statement) ?? "Current Surface",
                fieldLabel: self.readString(at: 5, in: statement) ?? "Focused Input",
                projectKey: self.readString(at: 6, in: statement) ?? "project:unknown",
                projectLabel: self.readString(at: 7, in: statement) ?? "Unknown Project",
                identityKey: self.readString(at: 8, in: statement) ?? "identity:unknown",
                identityType: self.readString(at: 9, in: statement) ?? "unknown",
                identityLabel: self.readString(at: 10, in: statement) ?? "Unknown Identity",
                nativeThreadKey: self.readString(at: 11, in: statement) ?? "",
                people: self.decodeStringArray(from: self.readString(at: 12, in: statement) ?? "[]"),
                runningSummary: self.readString(at: 13, in: statement) ?? "",
                totalExchangeTurns: Int(sqlite3_column_int64(statement, 14)),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 15)),
                lastActivityAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 16)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 17))
            )
        })
        return rows.first
    }

    func fetchConversationThread(id: String) throws -> ConversationThreadRecord? {
        let sql = """
        SELECT
            id, app_name, bundle_id, logical_surface_key, screen_label, field_label,
            project_key, project_label, identity_key, identity_type, identity_label,
            native_thread_key, people_json, running_summary, total_exchange_turns,
            created_at, last_activity_at, updated_at
        FROM conversation_threads
        WHERE id = ?
        LIMIT 1;
        """

        let rows: [ConversationThreadRecord] = try query(sql: sql, bind: { statement in
            self.bind(id, at: 1, in: statement)
        }, mapRow: { statement in
            ConversationThreadRecord(
                id: self.readString(at: 0, in: statement) ?? "",
                appName: self.readString(at: 1, in: statement) ?? "Unknown App",
                bundleID: self.readString(at: 2, in: statement) ?? "unknown.bundle",
                logicalSurfaceKey: self.readString(at: 3, in: statement) ?? "",
                screenLabel: self.readString(at: 4, in: statement) ?? "Current Surface",
                fieldLabel: self.readString(at: 5, in: statement) ?? "Focused Input",
                projectKey: self.readString(at: 6, in: statement) ?? "project:unknown",
                projectLabel: self.readString(at: 7, in: statement) ?? "Unknown Project",
                identityKey: self.readString(at: 8, in: statement) ?? "identity:unknown",
                identityType: self.readString(at: 9, in: statement) ?? "unknown",
                identityLabel: self.readString(at: 10, in: statement) ?? "Unknown Identity",
                nativeThreadKey: self.readString(at: 11, in: statement) ?? "",
                people: self.decodeStringArray(from: self.readString(at: 12, in: statement) ?? "[]"),
                runningSummary: self.readString(at: 13, in: statement) ?? "",
                totalExchangeTurns: Int(sqlite3_column_int64(statement, 14)),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 15)),
                lastActivityAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 16)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 17))
            )
        })
        return rows.first
    }

    func fetchConversationThreads(limit: Int = 200) throws -> [ConversationThreadRecord] {
        let normalizedLimit = max(1, min(limit, 1_000))
        let sql = """
        SELECT
            id, app_name, bundle_id, logical_surface_key, screen_label, field_label,
            project_key, project_label, identity_key, identity_type, identity_label,
            native_thread_key, people_json, running_summary, total_exchange_turns,
            created_at, last_activity_at, updated_at
        FROM conversation_threads
        ORDER BY last_activity_at DESC
        LIMIT ?;
        """
        return try query(sql: sql, bind: { statement in
            self.bind(Int64(normalizedLimit), at: 1, in: statement)
        }, mapRow: { statement in
            ConversationThreadRecord(
                id: self.readString(at: 0, in: statement) ?? "",
                appName: self.readString(at: 1, in: statement) ?? "Unknown App",
                bundleID: self.readString(at: 2, in: statement) ?? "unknown.bundle",
                logicalSurfaceKey: self.readString(at: 3, in: statement) ?? "",
                screenLabel: self.readString(at: 4, in: statement) ?? "Current Surface",
                fieldLabel: self.readString(at: 5, in: statement) ?? "Focused Input",
                projectKey: self.readString(at: 6, in: statement) ?? "project:unknown",
                projectLabel: self.readString(at: 7, in: statement) ?? "Unknown Project",
                identityKey: self.readString(at: 8, in: statement) ?? "identity:unknown",
                identityType: self.readString(at: 9, in: statement) ?? "unknown",
                identityLabel: self.readString(at: 10, in: statement) ?? "Unknown Identity",
                nativeThreadKey: self.readString(at: 11, in: statement) ?? "",
                people: self.decodeStringArray(from: self.readString(at: 12, in: statement) ?? "[]"),
                runningSummary: self.readString(at: 13, in: statement) ?? "",
                totalExchangeTurns: Int(sqlite3_column_int64(statement, 14)),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 15)),
                lastActivityAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 16)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 17))
            )
        })
    }

    func fetchAllConversationThreads() throws -> [ConversationThreadRecord] {
        let sql = """
        SELECT
            id, app_name, bundle_id, logical_surface_key, screen_label, field_label,
            project_key, project_label, identity_key, identity_type, identity_label,
            native_thread_key, people_json, running_summary, total_exchange_turns,
            created_at, last_activity_at, updated_at
        FROM conversation_threads
        ORDER BY last_activity_at DESC;
        """
        return try query(sql: sql, mapRow: { statement in
            ConversationThreadRecord(
                id: self.readString(at: 0, in: statement) ?? "",
                appName: self.readString(at: 1, in: statement) ?? "Unknown App",
                bundleID: self.readString(at: 2, in: statement) ?? "unknown.bundle",
                logicalSurfaceKey: self.readString(at: 3, in: statement) ?? "",
                screenLabel: self.readString(at: 4, in: statement) ?? "Current Surface",
                fieldLabel: self.readString(at: 5, in: statement) ?? "Focused Input",
                projectKey: self.readString(at: 6, in: statement) ?? "project:unknown",
                projectLabel: self.readString(at: 7, in: statement) ?? "Unknown Project",
                identityKey: self.readString(at: 8, in: statement) ?? "identity:unknown",
                identityType: self.readString(at: 9, in: statement) ?? "unknown",
                identityLabel: self.readString(at: 10, in: statement) ?? "Unknown Identity",
                nativeThreadKey: self.readString(at: 11, in: statement) ?? "",
                people: self.decodeStringArray(from: self.readString(at: 12, in: statement) ?? "[]"),
                runningSummary: self.readString(at: 13, in: statement) ?? "",
                totalExchangeTurns: Int(sqlite3_column_int64(statement, 14)),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 15)),
                lastActivityAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 16)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 17))
            )
        })
    }

    func insertConversationTurn(_ turn: ConversationTurnRecord) throws -> Bool {
        let sql = """
        INSERT OR IGNORE INTO conversation_turns (
            id, thread_id, role, user_text, assistant_text, normalized_text, is_summary,
            source_turn_count, compaction_version, metadata_json, created_at, turn_dedupe_key
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        let changed = try executeReturningChanges(sql: sql, bind: { statement in
            self.bind(turn.id, at: 1, in: statement)
            self.bind(turn.threadID, at: 2, in: statement)
            self.bind(turn.role, at: 3, in: statement)
            self.bind(turn.userText, at: 4, in: statement)
            self.bind(turn.assistantText, at: 5, in: statement)
            self.bind(turn.normalizedText, at: 6, in: statement)
            self.bind(turn.isSummary ? 1 : 0, at: 7, in: statement)
            self.bind(Int64(max(1, turn.sourceTurnCount)), at: 8, in: statement)
            if let compactionVersion = turn.compactionVersion {
                self.bind(Int64(compactionVersion), at: 9, in: statement)
            } else {
                sqlite3_bind_null(statement, 9)
            }
            self.bind(self.encodeJSON(turn.metadata, fallback: "{}"), at: 10, in: statement)
            self.bind(turn.createdAt.timeIntervalSince1970, at: 11, in: statement)
            self.bind(turn.turnDedupeKey, at: 12, in: statement)
        })
        return changed > 0
    }

    func fetchConversationTurns(threadID: String, limit: Int = 200) throws -> [ConversationTurnRecord] {
        let normalizedLimit = max(1, min(limit, 1_000))
        let sql = """
        SELECT
            id, thread_id, role, user_text, assistant_text, normalized_text, is_summary,
            source_turn_count, compaction_version, metadata_json, created_at, turn_dedupe_key
        FROM conversation_turns
        WHERE thread_id = ?
        ORDER BY created_at ASC
        LIMIT ?;
        """

        return try query(sql: sql, bind: { statement in
            self.bind(threadID, at: 1, in: statement)
            self.bind(Int64(normalizedLimit), at: 2, in: statement)
        }, mapRow: { statement in
            let compactionVersion: Int?
            if sqlite3_column_type(statement, 8) == SQLITE_NULL {
                compactionVersion = nil
            } else {
                compactionVersion = Int(sqlite3_column_int64(statement, 8))
            }
            return ConversationTurnRecord(
                id: self.readString(at: 0, in: statement) ?? "",
                threadID: self.readString(at: 1, in: statement) ?? threadID,
                role: self.readString(at: 2, in: statement) ?? "assistant",
                userText: self.readString(at: 3, in: statement) ?? "",
                assistantText: self.readString(at: 4, in: statement) ?? "",
                normalizedText: self.readString(at: 5, in: statement) ?? "",
                isSummary: sqlite3_column_int(statement, 6) == 1,
                sourceTurnCount: Int(sqlite3_column_int64(statement, 7)),
                compactionVersion: compactionVersion,
                metadata: self.decodeStringDictionary(from: self.readString(at: 9, in: statement) ?? "{}"),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
                turnDedupeKey: self.readString(at: 11, in: statement) ?? ""
            )
        })
    }

    func replaceConversationTurns(
        threadID: String,
        turns: [ConversationTurnRecord],
        runningSummary: String,
        totalExchangeTurns: Int,
        lastActivityAt: Date,
        updatedAt: Date = Date()
    ) throws {
        try execute(sql: "DELETE FROM conversation_turns WHERE thread_id = ?;", bind: { statement in
            self.bind(threadID, at: 1, in: statement)
        })

        for turn in turns {
            let sql = """
            INSERT INTO conversation_turns (
                id, thread_id, role, user_text, assistant_text, normalized_text, is_summary,
                source_turn_count, compaction_version, metadata_json, created_at, turn_dedupe_key
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                role = excluded.role,
                user_text = excluded.user_text,
                assistant_text = excluded.assistant_text,
                normalized_text = excluded.normalized_text,
                is_summary = excluded.is_summary,
                source_turn_count = excluded.source_turn_count,
                compaction_version = excluded.compaction_version,
                metadata_json = excluded.metadata_json,
                created_at = excluded.created_at,
                turn_dedupe_key = excluded.turn_dedupe_key;
            """
            try execute(sql: sql, bind: { statement in
                self.bind(turn.id, at: 1, in: statement)
                self.bind(turn.threadID, at: 2, in: statement)
                self.bind(turn.role, at: 3, in: statement)
                self.bind(turn.userText, at: 4, in: statement)
                self.bind(turn.assistantText, at: 5, in: statement)
                self.bind(turn.normalizedText, at: 6, in: statement)
                self.bind(turn.isSummary ? 1 : 0, at: 7, in: statement)
                self.bind(Int64(max(1, turn.sourceTurnCount)), at: 8, in: statement)
                if let compactionVersion = turn.compactionVersion {
                    self.bind(Int64(compactionVersion), at: 9, in: statement)
                } else {
                    sqlite3_bind_null(statement, 9)
                }
                self.bind(self.encodeJSON(turn.metadata, fallback: "{}"), at: 10, in: statement)
                self.bind(turn.createdAt.timeIntervalSince1970, at: 11, in: statement)
                self.bind(turn.turnDedupeKey, at: 12, in: statement)
            })
        }

        try execute(sql: """
        UPDATE conversation_threads
        SET running_summary = ?,
            total_exchange_turns = ?,
            last_activity_at = ?,
            updated_at = ?
        WHERE id = ?;
        """, bind: { statement in
            self.bind(runningSummary, at: 1, in: statement)
            self.bind(Int64(max(0, totalExchangeTurns)), at: 2, in: statement)
            self.bind(lastActivityAt.timeIntervalSince1970, at: 3, in: statement)
            self.bind(updatedAt.timeIntervalSince1970, at: 4, in: statement)
            self.bind(threadID, at: 5, in: statement)
        })
    }

    func deleteConversationThread(
        id: String,
        preserveRedirects: Bool = false
    ) throws {
        try execute(sql: "DELETE FROM conversation_turns WHERE thread_id = ?;", bind: { statement in
            self.bind(id, at: 1, in: statement)
        })
        try execute(sql: "DELETE FROM conversation_threads WHERE id = ?;", bind: { statement in
            self.bind(id, at: 1, in: statement)
        })
        if preserveRedirects {
            try execute(sql: "DELETE FROM conversation_thread_redirects WHERE new_thread_id = ?;", bind: { statement in
                self.bind(id, at: 1, in: statement)
            })
        } else {
            try execute(sql: "DELETE FROM conversation_thread_redirects WHERE old_thread_id = ? OR new_thread_id = ?;", bind: { statement in
                self.bind(id, at: 1, in: statement)
                self.bind(id, at: 2, in: statement)
            })
        }
    }

    func clearAllConversationThreads() throws {
        try execute(sql: "DELETE FROM conversation_turns;")
        try execute(sql: "DELETE FROM conversation_threads;")
        try execute(sql: "DELETE FROM conversation_thread_redirects;")
    }

    func upsertExpiredConversationContext(_ context: ExpiredConversationContextRecord) throws {
        let normalizedID = context.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedScopeKey = normalizeLookupKey(context.scopeKey)
        let normalizedThreadID = context.threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBundleID = normalizeLookupKey(context.bundleID)
        guard !normalizedID.isEmpty,
              !normalizedScopeKey.isEmpty,
              !normalizedThreadID.isEmpty,
              !normalizedBundleID.isEmpty else {
            return
        }

        let normalizedSummaryText = MemoryTextNormalizer.normalizedBody(context.summaryText)
        let normalizedRecentTurnsJSON = context.recentTurnsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "[]"
            : context.recentTurnsJSON
        let normalizedRawTurnsJSON = context.rawTurnsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "[]"
            : context.rawTurnsJSON
        let normalizedTrigger = context.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let consumedByThreadID = context.consumedByThreadID?.trimmingCharacters(in: .whitespacesAndNewlines)

        let sql = """
        INSERT INTO conversation_expired_contexts (
            id, scope_key, thread_id, bundle_id, project_key, identity_key,
            summary_text, summary_method, summary_confidence, source_turn_count,
            recent_turns_json, raw_turns_json, trigger, expired_at, delete_after_at,
            consumed_at, consumed_by_thread_id, metadata_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            scope_key = excluded.scope_key,
            thread_id = excluded.thread_id,
            bundle_id = excluded.bundle_id,
            project_key = excluded.project_key,
            identity_key = excluded.identity_key,
            summary_text = excluded.summary_text,
            summary_method = excluded.summary_method,
            summary_confidence = excluded.summary_confidence,
            source_turn_count = excluded.source_turn_count,
            recent_turns_json = excluded.recent_turns_json,
            raw_turns_json = excluded.raw_turns_json,
            trigger = excluded.trigger,
            expired_at = excluded.expired_at,
            delete_after_at = excluded.delete_after_at,
            consumed_at = excluded.consumed_at,
            consumed_by_thread_id = excluded.consumed_by_thread_id,
            metadata_json = excluded.metadata_json;
        """

        try execute(sql: sql, bind: { statement in
            self.bind(normalizedID, at: 1, in: statement)
            self.bind(normalizedScopeKey, at: 2, in: statement)
            self.bind(normalizedThreadID, at: 3, in: statement)
            self.bind(normalizedBundleID, at: 4, in: statement)
            self.bind(self.normalizeLookupOptional(context.projectKey), at: 5, in: statement)
            self.bind(self.normalizeLookupOptional(context.identityKey), at: 6, in: statement)
            self.bind(
                normalizedSummaryText.isEmpty ? "Context expired without summary." : normalizedSummaryText,
                at: 7,
                in: statement
            )
            self.bind(context.summaryMethod.rawValue, at: 8, in: statement)
            if let summaryConfidence = context.summaryConfidence {
                self.bind(summaryConfidence, at: 9, in: statement)
            } else {
                sqlite3_bind_null(statement, 9)
            }
            self.bind(Int64(max(0, context.sourceTurnCount)), at: 10, in: statement)
            self.bind(normalizedRecentTurnsJSON, at: 11, in: statement)
            self.bind(normalizedRawTurnsJSON, at: 12, in: statement)
            self.bind(normalizedTrigger.isEmpty ? "unknown" : normalizedTrigger, at: 13, in: statement)
            self.bind(context.expiredAt.timeIntervalSince1970, at: 14, in: statement)
            self.bind(context.deleteAfterAt.timeIntervalSince1970, at: 15, in: statement)
            if let consumedAt = context.consumedAt {
                self.bind(consumedAt.timeIntervalSince1970, at: 16, in: statement)
            } else {
                sqlite3_bind_null(statement, 16)
            }
            self.bind(consumedByThreadID, at: 17, in: statement)
            self.bind(self.encodeJSON(context.metadata, fallback: "{}"), at: 18, in: statement)
        })
    }

    func fetchLatestExpiredConversationContext(
        scopeKey: String,
        bundleIDConstraint: String?,
        includeConsumed: Bool = false
    ) throws -> ExpiredConversationContextRecord? {
        let normalizedScopeKey = normalizeLookupKey(scopeKey)
        guard !normalizedScopeKey.isEmpty else { return nil }
        let normalizedBundleConstraint = normalizeLookupOptional(bundleIDConstraint)

        let sql = """
        SELECT
            id, scope_key, thread_id, bundle_id, project_key, identity_key,
            summary_text, summary_method, summary_confidence, source_turn_count,
            recent_turns_json, raw_turns_json, trigger, expired_at, delete_after_at,
            consumed_at, consumed_by_thread_id, metadata_json
        FROM conversation_expired_contexts
        WHERE scope_key = ?
            AND (? = 1 OR consumed_at IS NULL)
            AND delete_after_at > ?
            AND (? IS NULL OR bundle_id = ?)
        ORDER BY expired_at DESC
        LIMIT 1;
        """

        let rows: [ExpiredConversationContextRecord] = try query(sql: sql, bind: { statement in
            self.bind(normalizedScopeKey, at: 1, in: statement)
            self.bind(includeConsumed ? 1 : 0, at: 2, in: statement)
            self.bind(Date().timeIntervalSince1970, at: 3, in: statement)
            self.bind(normalizedBundleConstraint, at: 4, in: statement)
            self.bind(normalizedBundleConstraint, at: 5, in: statement)
        }, mapRow: { statement in
            self.expiredConversationContext(from: statement)
        })
        return rows.first
    }

    @discardableResult
    func markExpiredConversationContextConsumed(
        id: String,
        consumedByThreadID: String,
        at: Date = Date()
    ) throws -> Bool {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedConsumedByThreadID = consumedByThreadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty, !normalizedConsumedByThreadID.isEmpty else { return false }

        let changed = try executeReturningChanges(sql: """
        UPDATE conversation_expired_contexts
        SET consumed_at = ?,
            consumed_by_thread_id = ?
        WHERE id = ?
            AND consumed_at IS NULL;
        """, bind: { statement in
            self.bind(at.timeIntervalSince1970, at: 1, in: statement)
            self.bind(normalizedConsumedByThreadID, at: 2, in: statement)
            self.bind(normalizedID, at: 3, in: statement)
        })
        return changed > 0
    }

    @discardableResult
    func updateExpiredConversationContextSummary(
        id: String,
        summaryText: String,
        method: ExpiredSummaryMethod,
        confidence: Double?,
        metadata: [String: String]
    ) throws -> Bool {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSummaryText = MemoryTextNormalizer.normalizedBody(summaryText)
        guard !normalizedID.isEmpty, !normalizedSummaryText.isEmpty else { return false }

        let changed = try executeReturningChanges(sql: """
        UPDATE conversation_expired_contexts
        SET summary_text = ?,
            summary_method = ?,
            summary_confidence = ?,
            metadata_json = ?
        WHERE id = ?;
        """, bind: { statement in
            self.bind(normalizedSummaryText, at: 1, in: statement)
            self.bind(method.rawValue, at: 2, in: statement)
            if let confidence {
                self.bind(confidence, at: 3, in: statement)
            } else {
                sqlite3_bind_null(statement, 3)
            }
            self.bind(self.encodeJSON(metadata, fallback: "{}"), at: 4, in: statement)
            self.bind(normalizedID, at: 5, in: statement)
        })

        return changed > 0
    }

    @discardableResult
    func purgeExpiredConversationContextArchive(
        now: Date = Date(),
        retentionDays: Int = MemorySQLiteStore.expiredContextDefaultRetentionDays,
        maxRows: Int = MemorySQLiteStore.expiredContextDefaultMaxRows,
        maxRawBytes: Int = MemorySQLiteStore.expiredContextDefaultMaxRawBytes
    ) throws -> (expiredDeleted: Int, retentionDeleted: Int, rowLimitDeleted: Int, rawSizeDeleted: Int) {
        let normalizedRetentionDays = max(1, retentionDays)
        let normalizedMaxRows = max(1, maxRows)
        let normalizedMaxRawBytes = max(0, maxRawBytes)
        let nowEpoch = now.timeIntervalSince1970
        let retentionCutoff = now
            .addingTimeInterval(-Double(normalizedRetentionDays) * 86_400)
            .timeIntervalSince1970

        let expiredDeleted = try executeReturningChanges(sql: """
        DELETE FROM conversation_expired_contexts
        WHERE delete_after_at <= ?;
        """, bind: { statement in
            self.bind(nowEpoch, at: 1, in: statement)
        })

        let retentionDeleted = try executeReturningChanges(sql: """
        DELETE FROM conversation_expired_contexts
        WHERE expired_at <= ?;
        """, bind: { statement in
            self.bind(retentionCutoff, at: 1, in: statement)
        })

        let totalRows = try scalarInt(sql: "SELECT COUNT(*) FROM conversation_expired_contexts;")
        let overflowRows = max(0, totalRows - normalizedMaxRows)
        let rowLimitDeleted: Int
        if overflowRows > 0 {
            rowLimitDeleted = try executeReturningChanges(sql: """
            DELETE FROM conversation_expired_contexts
            WHERE id IN (
                SELECT id
                FROM conversation_expired_contexts
                ORDER BY expired_at ASC, id ASC
                LIMIT ?
            );
            """, bind: { statement in
                self.bind(Int64(overflowRows), at: 1, in: statement)
            })
        } else {
            rowLimitDeleted = 0
        }

        let maxRawBytes64 = Int64(normalizedMaxRawBytes)
        var rawSizeDeleted = 0
        let totalRawBytes = try scalarInt64(sql: """
        SELECT coalesce(sum(length(CAST(raw_turns_json AS BLOB))), 0)
        FROM conversation_expired_contexts;
        """)
        if totalRawBytes > maxRawBytes64 {
            let bytesToTrim = totalRawBytes - maxRawBytes64
            let candidates: [(id: String, rawBytes: Int64)] = try query(sql: """
            SELECT id, length(CAST(raw_turns_json AS BLOB))
            FROM conversation_expired_contexts
            ORDER BY expired_at ASC, id ASC;
            """, mapRow: { statement in
                let id = self.readString(at: 0, in: statement) ?? ""
                let rawBytes = sqlite3_column_int64(statement, 1)
                return (id: id, rawBytes: rawBytes)
            })

            var selectedIDs: [String] = []
            var reclaimedBytes: Int64 = 0
            for candidate in candidates {
                guard !candidate.id.isEmpty else { continue }
                selectedIDs.append(candidate.id)
                reclaimedBytes += max(0, candidate.rawBytes)
                if reclaimedBytes >= bytesToTrim {
                    break
                }
            }

            if !selectedIDs.isEmpty {
                let placeholders = Array(repeating: "?", count: selectedIDs.count).joined(separator: ", ")
                rawSizeDeleted = try executeReturningChanges(
                    sql: "DELETE FROM conversation_expired_contexts WHERE id IN (\(placeholders));",
                    bind: { statement in
                        for (index, id) in selectedIDs.enumerated() {
                            self.bind(id, at: Int32(index + 1), in: statement)
                        }
                    }
                )
            }
        }

        return (
            expiredDeleted: expiredDeleted,
            retentionDeleted: retentionDeleted,
            rowLimitDeleted: rowLimitDeleted,
            rawSizeDeleted: rawSizeDeleted
        )
    }

    func fetchExpiredConversationContextDiagnostics() throws -> ExpiredConversationContextDiagnostics {
        let count = try scalarInt(sql: "SELECT COUNT(*) FROM conversation_expired_contexts;")
        guard count > 0 else {
            return ExpiredConversationContextDiagnostics(
                totalCount: 0,
                lastSummaryMethod: .fallback,
                lastPromotionDecisionSummary: "No promotion decision yet."
            )
        }

        let latestRows: [(method: ExpiredSummaryMethod, trigger: String, metadata: [String: String])] = try query(sql: """
        SELECT summary_method, trigger, metadata_json
        FROM conversation_expired_contexts
        ORDER BY expired_at DESC, id DESC
        LIMIT 1;
        """, mapRow: { statement in
            let rawMethod = self.readString(at: 0, in: statement) ?? ""
            let method = ExpiredSummaryMethod(rawValue: rawMethod) ?? .fallback
            let trigger = self.readString(at: 1, in: statement) ?? ""
            let metadata = self.decodeStringDictionary(from: self.readString(at: 2, in: statement) ?? "{}")
            return (method: method, trigger: trigger, metadata: metadata)
        })

        guard let latest = latestRows.first else {
            return ExpiredConversationContextDiagnostics(
                totalCount: count,
                lastSummaryMethod: .fallback,
                lastPromotionDecisionSummary: "No promotion decision yet."
            )
        }

        return ExpiredConversationContextDiagnostics(
            totalCount: count,
            lastSummaryMethod: latest.method,
            lastPromotionDecisionSummary: promotionDecisionSummary(
                metadata: latest.metadata,
                trigger: latest.trigger
            )
        )
    }

    func upsertConversationAgentProfile(_ profile: ConversationAgentProfileRecord) throws {
        let threadID = profile.threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !threadID.isEmpty else { return }

        let sql = """
        INSERT INTO conversation_agent_profiles (
            thread_id, profile_json, created_at, updated_at, expires_at
        ) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(thread_id) DO UPDATE SET
            profile_json = excluded.profile_json,
            updated_at = excluded.updated_at,
            expires_at = excluded.expires_at;
        """

        try execute(sql: sql, bind: { statement in
            self.bind(threadID, at: 1, in: statement)
            self.bind(profile.profileJSON, at: 2, in: statement)
            self.bind(profile.createdAt.timeIntervalSince1970, at: 3, in: statement)
            self.bind(profile.updatedAt.timeIntervalSince1970, at: 4, in: statement)
            self.bind(profile.expiresAt.timeIntervalSince1970, at: 5, in: statement)
        })
    }

    func fetchConversationAgentProfile(threadID: String) throws -> ConversationAgentProfileRecord? {
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadID.isEmpty else { return nil }

        let sql = """
        SELECT thread_id, profile_json, created_at, updated_at, expires_at
        FROM conversation_agent_profiles
        WHERE thread_id = ?
        LIMIT 1;
        """

        let rows: [ConversationAgentProfileRecord] = try query(sql: sql, bind: { statement in
            self.bind(normalizedThreadID, at: 1, in: statement)
        }, mapRow: { statement in
            ConversationAgentProfileRecord(
                threadID: self.readString(at: 0, in: statement) ?? normalizedThreadID,
                profileJSON: self.readString(at: 1, in: statement) ?? "{}",
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                expiresAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            )
        })
        return rows.first
    }

    func clearConversationAgentProfile(threadID: String) throws {
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadID.isEmpty else { return }
        try execute(sql: "DELETE FROM conversation_agent_profiles WHERE thread_id = ?;", bind: { statement in
            self.bind(normalizedThreadID, at: 1, in: statement)
        })
    }

    func upsertConversationAgentEntities(_ entities: ConversationAgentEntitiesRecord) throws {
        let threadID = entities.threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !threadID.isEmpty else { return }

        let sql = """
        INSERT INTO conversation_agent_entities (
            thread_id, entities_json, created_at, updated_at, expires_at
        ) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(thread_id) DO UPDATE SET
            entities_json = excluded.entities_json,
            updated_at = excluded.updated_at,
            expires_at = excluded.expires_at;
        """

        try execute(sql: sql, bind: { statement in
            self.bind(threadID, at: 1, in: statement)
            self.bind(entities.entitiesJSON, at: 2, in: statement)
            self.bind(entities.createdAt.timeIntervalSince1970, at: 3, in: statement)
            self.bind(entities.updatedAt.timeIntervalSince1970, at: 4, in: statement)
            self.bind(entities.expiresAt.timeIntervalSince1970, at: 5, in: statement)
        })
    }

    func fetchConversationAgentEntities(threadID: String) throws -> ConversationAgentEntitiesRecord? {
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadID.isEmpty else { return nil }

        let sql = """
        SELECT thread_id, entities_json, created_at, updated_at, expires_at
        FROM conversation_agent_entities
        WHERE thread_id = ?
        LIMIT 1;
        """

        let rows: [ConversationAgentEntitiesRecord] = try query(sql: sql, bind: { statement in
            self.bind(normalizedThreadID, at: 1, in: statement)
        }, mapRow: { statement in
            ConversationAgentEntitiesRecord(
                threadID: self.readString(at: 0, in: statement) ?? normalizedThreadID,
                entitiesJSON: self.readString(at: 1, in: statement) ?? "[]",
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                expiresAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            )
        })
        return rows.first
    }

    func clearConversationAgentEntities(threadID: String) throws {
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadID.isEmpty else { return }
        try execute(sql: "DELETE FROM conversation_agent_entities WHERE thread_id = ?;", bind: { statement in
            self.bind(normalizedThreadID, at: 1, in: statement)
        })
    }

    func upsertConversationAgentPreferences(_ preferences: ConversationAgentPreferencesRecord) throws {
        let threadID = preferences.threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !threadID.isEmpty else { return }

        let sql = """
        INSERT INTO conversation_agent_preferences (
            thread_id, preferences_json, created_at, updated_at, expires_at
        ) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(thread_id) DO UPDATE SET
            preferences_json = excluded.preferences_json,
            updated_at = excluded.updated_at,
            expires_at = excluded.expires_at;
        """

        try execute(sql: sql, bind: { statement in
            self.bind(threadID, at: 1, in: statement)
            self.bind(preferences.preferencesJSON, at: 2, in: statement)
            self.bind(preferences.createdAt.timeIntervalSince1970, at: 3, in: statement)
            self.bind(preferences.updatedAt.timeIntervalSince1970, at: 4, in: statement)
            self.bind(preferences.expiresAt.timeIntervalSince1970, at: 5, in: statement)
        })
    }

    func fetchConversationAgentPreferences(threadID: String) throws -> ConversationAgentPreferencesRecord? {
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadID.isEmpty else { return nil }

        let sql = """
        SELECT thread_id, preferences_json, created_at, updated_at, expires_at
        FROM conversation_agent_preferences
        WHERE thread_id = ?
        LIMIT 1;
        """

        let rows: [ConversationAgentPreferencesRecord] = try query(sql: sql, bind: { statement in
            self.bind(normalizedThreadID, at: 1, in: statement)
        }, mapRow: { statement in
            ConversationAgentPreferencesRecord(
                threadID: self.readString(at: 0, in: statement) ?? normalizedThreadID,
                preferencesJSON: self.readString(at: 1, in: statement) ?? "{}",
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                expiresAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            )
        })
        return rows.first
    }

    func clearConversationAgentPreferences(threadID: String) throws {
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadID.isEmpty else { return }
        try execute(sql: "DELETE FROM conversation_agent_preferences WHERE thread_id = ?;", bind: { statement in
            self.bind(normalizedThreadID, at: 1, in: statement)
        })
    }

    func upsertAssistantMemoryEntry(_ entry: AssistantMemoryEntry) throws {
        let sql = """
        INSERT INTO assistant_memory_entries (
            id, provider, scope_key, bundle_id, project_key, identity_key, thread_id, memory_type,
            title, summary, detail, keywords_json, confidence, state, metadata_json, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            provider = excluded.provider,
            scope_key = excluded.scope_key,
            bundle_id = excluded.bundle_id,
            project_key = excluded.project_key,
            identity_key = excluded.identity_key,
            thread_id = excluded.thread_id,
            memory_type = excluded.memory_type,
            title = excluded.title,
            summary = excluded.summary,
            detail = excluded.detail,
            keywords_json = excluded.keywords_json,
            confidence = excluded.confidence,
            state = excluded.state,
            metadata_json = excluded.metadata_json,
            updated_at = excluded.updated_at;
        """

        try execute(sql: sql, bind: { statement in
            self.bind(entry.id.uuidString, at: 1, in: statement)
            self.bind(entry.provider.rawValue, at: 2, in: statement)
            self.bind(entry.scopeKey, at: 3, in: statement)
            self.bind(entry.bundleID, at: 4, in: statement)
            self.bind(entry.projectKey, at: 5, in: statement)
            self.bind(entry.identityKey, at: 6, in: statement)
            self.bind(entry.threadID, at: 7, in: statement)
            self.bind(entry.memoryType.rawValue, at: 8, in: statement)
            self.bind(entry.title, at: 9, in: statement)
            self.bind(entry.summary, at: 10, in: statement)
            self.bind(entry.detail, at: 11, in: statement)
            self.bind(self.encodeJSON(entry.keywords, fallback: "[]"), at: 12, in: statement)
            self.bind(entry.confidence, at: 13, in: statement)
            self.bind(entry.state.rawValue, at: 14, in: statement)
            self.bind(self.encodeJSON(entry.metadata, fallback: "{}"), at: 15, in: statement)
            self.bind(entry.createdAt.timeIntervalSince1970, at: 16, in: statement)
            self.bind(entry.updatedAt.timeIntervalSince1970, at: 17, in: statement)
        })
    }

    func fetchAssistantMemoryEntries(
        query searchQuery: String = "",
        provider: MemoryProviderKind = .codex,
        scopeKey: String? = nil,
        projectKey: String? = nil,
        identityKey: String? = nil,
        threadID: String? = nil,
        state: AssistantMemoryEntryState = .active,
        limit: Int = 24
    ) throws -> [AssistantMemoryEntry] {
        let normalizedQuery = MemoryTextNormalizer.collapsedWhitespace(searchQuery)
        let hasSearchTerm = !normalizedQuery.isEmpty
        let likeValue = "%\(escapedLike(normalizedQuery))%"
        let normalizedLimit = max(1, min(limit, 200))

        let sql = """
        SELECT
            id, provider, scope_key, bundle_id, project_key, identity_key, thread_id, memory_type,
            title, summary, detail, keywords_json, confidence, state, metadata_json, created_at, updated_at
        FROM assistant_memory_entries
        WHERE provider = ?
            AND state = ?
            AND (? IS NULL OR scope_key = ?)
            AND (? IS NULL OR project_key = ?)
            AND (? IS NULL OR identity_key = ?)
            AND (? IS NULL OR thread_id = ?)
            AND (
                ? = 0
                OR title LIKE ? ESCAPE '\\'
                OR summary LIKE ? ESCAPE '\\'
                OR detail LIKE ? ESCAPE '\\'
            )
        ORDER BY confidence DESC, updated_at DESC
        LIMIT ?;
        """

        return try query(sql: sql, bind: { statement in
            self.bind(provider.rawValue, at: 1, in: statement)
            self.bind(state.rawValue, at: 2, in: statement)
            self.bind(scopeKey, at: 3, in: statement)
            self.bind(scopeKey, at: 4, in: statement)
            self.bind(projectKey, at: 5, in: statement)
            self.bind(projectKey, at: 6, in: statement)
            self.bind(identityKey, at: 7, in: statement)
            self.bind(identityKey, at: 8, in: statement)
            self.bind(threadID, at: 9, in: statement)
            self.bind(threadID, at: 10, in: statement)
            self.bind(hasSearchTerm ? 1 : 0, at: 11, in: statement)
            self.bind(likeValue, at: 12, in: statement)
            self.bind(likeValue, at: 13, in: statement)
            self.bind(likeValue, at: 14, in: statement)
            self.bind(Int64(normalizedLimit), at: 15, in: statement)
        }, mapRow: { statement in
            AssistantMemoryEntry(
                id: UUID(uuidString: self.readString(at: 0, in: statement) ?? "") ?? UUID(),
                provider: MemoryProviderKind(rawValue: self.readString(at: 1, in: statement) ?? "") ?? .unknown,
                scopeKey: self.readString(at: 2, in: statement) ?? "",
                bundleID: self.readString(at: 3, in: statement) ?? "",
                projectKey: self.readString(at: 4, in: statement),
                identityKey: self.readString(at: 5, in: statement),
                threadID: self.readString(at: 6, in: statement),
                memoryType: AssistantMemoryEntryType(rawValue: self.readString(at: 7, in: statement) ?? "") ?? .lesson,
                title: self.readString(at: 8, in: statement) ?? "",
                summary: self.readString(at: 9, in: statement) ?? "",
                detail: self.readString(at: 10, in: statement) ?? "",
                keywords: self.decodeStringArray(from: self.readString(at: 11, in: statement) ?? "[]"),
                confidence: sqlite3_column_double(statement, 12),
                state: AssistantMemoryEntryState(rawValue: self.readString(at: 13, in: statement) ?? "") ?? .active,
                metadata: self.decodeStringDictionary(from: self.readString(at: 14, in: statement) ?? "{}"),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 15)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 16))
            )
        })
    }

    func invalidateAssistantMemoryEntry(
        id: UUID,
        reason: String,
        updatedAt: Date = Date()
    ) throws {
        let existing = try fetchAssistantMemoryEntries(query: "", state: .active, limit: 500)
            .first(where: { $0.id == id })
        guard let existing else { return }

        var metadata = existing.metadata
        metadata["memory_domain"] = "assistant"
        metadata["invalidation_reason"] = MemoryTextNormalizer.normalizedSummary(reason, limit: 240)
        metadata["invalidated_at"] = iso8601Timestamp(updatedAt)

        let invalidated = AssistantMemoryEntry(
            id: existing.id,
            provider: existing.provider,
            scopeKey: existing.scopeKey,
            bundleID: existing.bundleID,
            projectKey: existing.projectKey,
            identityKey: existing.identityKey,
            threadID: existing.threadID,
            memoryType: existing.memoryType,
            title: existing.title,
            summary: existing.summary,
            detail: existing.detail,
            keywords: existing.keywords,
            confidence: existing.confidence,
            state: .invalidated,
            metadata: metadata,
            createdAt: existing.createdAt,
            updatedAt: updatedAt
        )
        try upsertAssistantMemoryEntry(invalidated)
    }

    func deleteAssistantMemoryEntries(threadID: String) throws {
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadID.isEmpty else { return }
        try execute(sql: "DELETE FROM assistant_memory_entries WHERE thread_id = ?;", bind: { statement in
            self.bind(normalizedThreadID, at: 1, in: statement)
        })
    }

    func clearAllConversationAgentState() throws {
        try execute(sql: "DELETE FROM conversation_agent_profiles;")
        try execute(sql: "DELETE FROM conversation_agent_entities;")
        try execute(sql: "DELETE FROM conversation_agent_preferences;")
    }

    func purgeExpiredAgentState(
        now: Date = Date()
    ) throws -> (profilesDeleted: Int, entitiesDeleted: Int, preferencesDeleted: Int) {
        let cutoff = now.timeIntervalSince1970

        let profilesDeleted = try scalarInt(sql: """
        SELECT COUNT(*)
        FROM conversation_agent_profiles
        WHERE expires_at <= ?;
        """, bind: { statement in
            self.bind(cutoff, at: 1, in: statement)
        })
        try execute(sql: """
        DELETE FROM conversation_agent_profiles
        WHERE expires_at <= ?;
        """, bind: { statement in
            self.bind(cutoff, at: 1, in: statement)
        })

        let entitiesDeleted = try scalarInt(sql: """
        SELECT COUNT(*)
        FROM conversation_agent_entities
        WHERE expires_at <= ?;
        """, bind: { statement in
            self.bind(cutoff, at: 1, in: statement)
        })
        try execute(sql: """
        DELETE FROM conversation_agent_entities
        WHERE expires_at <= ?;
        """, bind: { statement in
            self.bind(cutoff, at: 1, in: statement)
        })

        let preferencesDeleted = try scalarInt(sql: """
        SELECT COUNT(*)
        FROM conversation_agent_preferences
        WHERE expires_at <= ?;
        """, bind: { statement in
            self.bind(cutoff, at: 1, in: statement)
        })
        try execute(sql: """
        DELETE FROM conversation_agent_preferences
        WHERE expires_at <= ?;
        """, bind: { statement in
            self.bind(cutoff, at: 1, in: statement)
        })

        return (
            profilesDeleted: profilesDeleted,
            entitiesDeleted: entitiesDeleted,
            preferencesDeleted: preferencesDeleted
        )
    }

    func upsertConversationThreadRedirect(
        oldThreadID: String,
        newThreadID: String,
        reason: String,
        createdAt: Date = Date()
    ) throws {
        try execute(sql: """
        INSERT INTO conversation_thread_redirects (old_thread_id, new_thread_id, reason, created_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(old_thread_id) DO UPDATE SET
            new_thread_id = excluded.new_thread_id,
            reason = excluded.reason,
            created_at = excluded.created_at;
        """, bind: { statement in
            self.bind(oldThreadID, at: 1, in: statement)
            self.bind(newThreadID, at: 2, in: statement)
            self.bind(reason, at: 3, in: statement)
            self.bind(createdAt.timeIntervalSince1970, at: 4, in: statement)
        })
    }

    func resolveConversationThreadRedirect(_ threadID: String) throws -> String? {
        let sql = """
        SELECT new_thread_id
        FROM conversation_thread_redirects
        WHERE old_thread_id = ?
        LIMIT 1;
        """
        let rows: [String] = try query(sql: sql, bind: { statement in
            self.bind(threadID, at: 1, in: statement)
        }, mapRow: { statement in
            self.readString(at: 0, in: statement) ?? ""
        })
        return rows.first
    }

    func upsertConversationTagAlias(
        aliasType: String,
        aliasKey: String,
        canonicalKey: String,
        updatedAt: Date = Date()
    ) throws {
        let sql = """
        INSERT INTO conversation_tag_aliases (alias_type, alias_key, canonical_key, updated_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(alias_type, alias_key) DO UPDATE SET
            canonical_key = excluded.canonical_key,
            updated_at = excluded.updated_at;
        """
        try execute(sql: sql, bind: { statement in
            self.bind(aliasType, at: 1, in: statement)
            self.bind(aliasKey, at: 2, in: statement)
            self.bind(canonicalKey, at: 3, in: statement)
            self.bind(updatedAt.timeIntervalSince1970, at: 4, in: statement)
        })
    }

    func resolveConversationTagAlias(
        aliasType: String,
        aliasKey: String
    ) throws -> String? {
        let sql = """
        SELECT canonical_key
        FROM conversation_tag_aliases
        WHERE alias_type = ?
            AND alias_key = ?
        LIMIT 1;
        """
        let rows: [String] = try query(sql: sql, bind: { statement in
            self.bind(aliasType, at: 1, in: statement)
            self.bind(aliasKey, at: 2, in: statement)
        }, mapRow: { statement in
            self.readString(at: 0, in: statement) ?? ""
        })
        return rows.first
    }

    func fetchConversationTagAliases(
        aliasType: String? = nil,
        limit: Int = 500
    ) throws -> [ConversationTagAliasRecord] {
        let normalizedLimit = max(1, min(limit, 5_000))
        let normalizedAliasType = normalizeLookupOptional(aliasType)

        let sql: String
        if normalizedAliasType == nil {
            sql = """
            SELECT alias_type, alias_key, canonical_key, updated_at
            FROM conversation_tag_aliases
            ORDER BY updated_at DESC
            LIMIT ?;
            """
            return try query(sql: sql, bind: { statement in
                self.bind(Int64(normalizedLimit), at: 1, in: statement)
            }, mapRow: { statement in
                ConversationTagAliasRecord(
                    aliasType: self.readString(at: 0, in: statement) ?? "",
                    aliasKey: self.readString(at: 1, in: statement) ?? "",
                    canonicalKey: self.readString(at: 2, in: statement) ?? "",
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
                )
            })
        }

        sql = """
        SELECT alias_type, alias_key, canonical_key, updated_at
        FROM conversation_tag_aliases
        WHERE alias_type = ?
        ORDER BY updated_at DESC
        LIMIT ?;
        """

        return try query(sql: sql, bind: { statement in
            self.bind(normalizedAliasType, at: 1, in: statement)
            self.bind(Int64(normalizedLimit), at: 2, in: statement)
        }, mapRow: { statement in
            ConversationTagAliasRecord(
                aliasType: self.readString(at: 0, in: statement) ?? "",
                aliasKey: self.readString(at: 1, in: statement) ?? "",
                canonicalKey: self.readString(at: 2, in: statement) ?? "",
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            )
        })
    }

    func deleteConversationTagAlias(aliasType: String, aliasKey: String) throws {
        let normalizedAliasType = normalizeLookupKey(aliasType)
        let normalizedAliasKey = normalizeLookupKey(aliasKey)
        guard !normalizedAliasType.isEmpty, !normalizedAliasKey.isEmpty else { return }

        try execute(sql: """
        DELETE FROM conversation_tag_aliases
        WHERE alias_type = ?
            AND alias_key = ?;
        """, bind: { statement in
            self.bind(normalizedAliasType, at: 1, in: statement)
            self.bind(normalizedAliasKey, at: 2, in: statement)
        })
    }

    func conversationDisambiguationAppPairKey(
        _ firstAppKey: String,
        _ secondAppKey: String
    ) -> String {
        let normalizedPair = [
            normalizeLookupKey(firstAppKey),
            normalizeLookupKey(secondAppKey)
        ]
        .filter { !$0.isEmpty }
        .sorted()
        return normalizedPair.joined(separator: "|")
    }

    func upsertConversationDisambiguationRule(_ rule: ConversationDisambiguationRuleRecord) throws {
        let normalizedID = normalizeLookupKey(rule.id)
        guard !normalizedID.isEmpty else { return }

        let normalizedAppPairKey = normalizeAppPairKey(rule.appPairKey)
        let normalizedSubjectKey = normalizeLookupKey(rule.subjectKey)
        guard !normalizedAppPairKey.isEmpty, !normalizedSubjectKey.isEmpty else { return }

        let sql = """
        INSERT INTO conversation_disambiguation_rules (
            id, rule_type, app_pair_key, subject_key, context_scope_key, decision, canonical_key, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT DO UPDATE SET
            rule_type = excluded.rule_type,
            app_pair_key = excluded.app_pair_key,
            subject_key = excluded.subject_key,
            context_scope_key = excluded.context_scope_key,
            decision = excluded.decision,
            canonical_key = excluded.canonical_key,
            created_at = excluded.created_at,
            updated_at = excluded.updated_at;
        """

        try execute(sql: sql, bind: { statement in
            self.bind(normalizedID, at: 1, in: statement)
            self.bind(rule.ruleType.rawValue, at: 2, in: statement)
            self.bind(normalizedAppPairKey, at: 3, in: statement)
            self.bind(normalizedSubjectKey, at: 4, in: statement)
            self.bind(self.normalizeLookupOptional(rule.contextScopeKey), at: 5, in: statement)
            self.bind(rule.decision.rawValue, at: 6, in: statement)
            self.bind(self.normalizeLookupOptional(rule.canonicalKey), at: 7, in: statement)
            self.bind(rule.createdAt.timeIntervalSince1970, at: 8, in: statement)
            self.bind(rule.updatedAt.timeIntervalSince1970, at: 9, in: statement)
        })
    }

    func fetchConversationDisambiguationRule(
        ruleType: ConversationDisambiguationRuleType,
        appPairKey: String,
        subjectKey: String,
        contextScopeKey: String?
    ) throws -> ConversationDisambiguationRuleRecord? {
        let normalizedAppPairKey = normalizeAppPairKey(appPairKey)
        let normalizedSubjectKey = normalizeLookupKey(subjectKey)
        guard !normalizedAppPairKey.isEmpty, !normalizedSubjectKey.isEmpty else { return nil }
        let normalizedContextScopeKey = normalizeLookupOptional(contextScopeKey)

        let sql = """
        SELECT
            id, rule_type, app_pair_key, subject_key, context_scope_key, decision, canonical_key, created_at, updated_at
        FROM conversation_disambiguation_rules
        WHERE rule_type = ?
            AND app_pair_key = ?
            AND subject_key = ?
            AND (
                (? IS NULL AND context_scope_key IS NULL)
                OR context_scope_key = ?
            )
        ORDER BY updated_at DESC
        LIMIT 1;
        """

        let rows: [ConversationDisambiguationRuleRecord] = try query(sql: sql, bind: { statement in
            self.bind(ruleType.rawValue, at: 1, in: statement)
            self.bind(normalizedAppPairKey, at: 2, in: statement)
            self.bind(normalizedSubjectKey, at: 3, in: statement)
            self.bind(normalizedContextScopeKey, at: 4, in: statement)
            self.bind(normalizedContextScopeKey, at: 5, in: statement)
        }, mapRow: { statement in
            self.conversationDisambiguationRule(from: statement)
        })

        return rows.first
    }

    func fetchConversationDisambiguationRules(
        ruleType: ConversationDisambiguationRuleType,
        appPairKey: String,
        subjectKey: String
    ) throws -> [ConversationDisambiguationRuleRecord] {
        let normalizedAppPairKey = normalizeAppPairKey(appPairKey)
        let normalizedSubjectKey = normalizeLookupKey(subjectKey)
        guard !normalizedAppPairKey.isEmpty, !normalizedSubjectKey.isEmpty else { return [] }

        let sql = """
        SELECT
            id, rule_type, app_pair_key, subject_key, context_scope_key, decision, canonical_key, created_at, updated_at
        FROM conversation_disambiguation_rules
        WHERE rule_type = ?
            AND app_pair_key = ?
            AND subject_key = ?
        ORDER BY updated_at DESC;
        """

        return try query(sql: sql, bind: { statement in
            self.bind(ruleType.rawValue, at: 1, in: statement)
            self.bind(normalizedAppPairKey, at: 2, in: statement)
            self.bind(normalizedSubjectKey, at: 3, in: statement)
        }, mapRow: { statement in
            self.conversationDisambiguationRule(from: statement)
        })
    }

    func fetchConversationDisambiguationRules(limit: Int = 500) throws -> [ConversationDisambiguationRuleRecord] {
        let normalizedLimit = max(1, min(limit, 5_000))
        let sql = """
        SELECT
            id, rule_type, app_pair_key, subject_key, context_scope_key, decision, canonical_key, created_at, updated_at
        FROM conversation_disambiguation_rules
        ORDER BY updated_at DESC
        LIMIT ?;
        """

        return try query(sql: sql, bind: { statement in
            self.bind(Int64(normalizedLimit), at: 1, in: statement)
        }, mapRow: { statement in
            self.conversationDisambiguationRule(from: statement)
        })
    }

    func deleteConversationDisambiguationRule(id: String) throws {
        let normalizedID = normalizeLookupKey(id)
        guard !normalizedID.isEmpty else { return }
        try execute(sql: "DELETE FROM conversation_disambiguation_rules WHERE id = ?;", bind: { statement in
            self.bind(normalizedID, at: 1, in: statement)
        })
    }

    func upsertSource(_ source: MemorySource) throws {
        let sql = """
        INSERT INTO memory_sources (
            id, provider, root_path, display_name, discovered_at, updated_at, metadata_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            provider = excluded.provider,
            root_path = excluded.root_path,
            display_name = excluded.display_name,
            updated_at = excluded.updated_at,
            metadata_json = excluded.metadata_json;
        """

        try execute(sql: sql, bind: { statement in
            self.bind(source.id.uuidString, at: 1, in: statement)
            self.bind(source.provider.rawValue, at: 2, in: statement)
            self.bind(source.rootPath, at: 3, in: statement)
            self.bind(source.displayName, at: 4, in: statement)
            self.bind(source.discoveredAt.timeIntervalSince1970, at: 5, in: statement)
            self.bind(Date().timeIntervalSince1970, at: 6, in: statement)
            self.bind(self.encodeJSON(source.metadata, fallback: "{}"), at: 7, in: statement)
        })
    }

    func upsertSourceFile(_ sourceFile: MemorySourceFile) throws {
        let sql = """
        INSERT INTO memory_files (
            id, source_id, absolute_path, relative_path, file_hash, file_size_bytes, modified_at, indexed_at, parse_error
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            source_id = excluded.source_id,
            absolute_path = excluded.absolute_path,
            relative_path = excluded.relative_path,
            file_hash = excluded.file_hash,
            file_size_bytes = excluded.file_size_bytes,
            modified_at = excluded.modified_at,
            indexed_at = excluded.indexed_at,
            parse_error = excluded.parse_error;
        """

        try execute(sql: sql, bind: { statement in
            self.bind(sourceFile.id.uuidString, at: 1, in: statement)
            self.bind(sourceFile.sourceID.uuidString, at: 2, in: statement)
            self.bind(sourceFile.absolutePath, at: 3, in: statement)
            self.bind(sourceFile.relativePath, at: 4, in: statement)
            self.bind(sourceFile.fileHash, at: 5, in: statement)
            self.bind(sourceFile.fileSizeBytes, at: 6, in: statement)
            self.bind(sourceFile.modifiedAt.timeIntervalSince1970, at: 7, in: statement)
            self.bind(sourceFile.indexedAt.timeIntervalSince1970, at: 8, in: statement)
            self.bind(sourceFile.parseError, at: 9, in: statement)
        })
    }

    func upsertEvent(_ event: MemoryEvent) throws {
        let sql = """
        INSERT INTO memory_events (
            id, source_id, source_file_id, provider, kind, title, body, event_timestamp, native_summary,
            keywords_json, is_plan_content, metadata_json, raw_payload, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            source_id = excluded.source_id,
            source_file_id = excluded.source_file_id,
            provider = excluded.provider,
            kind = excluded.kind,
            title = excluded.title,
            body = excluded.body,
            event_timestamp = excluded.event_timestamp,
            native_summary = excluded.native_summary,
            keywords_json = excluded.keywords_json,
            is_plan_content = excluded.is_plan_content,
            metadata_json = excluded.metadata_json,
            raw_payload = excluded.raw_payload,
            updated_at = excluded.updated_at;
        """

        try execute(sql: sql, bind: { statement in
            self.bind(event.id.uuidString, at: 1, in: statement)
            self.bind(event.sourceID.uuidString, at: 2, in: statement)
            self.bind(event.sourceFileID.uuidString, at: 3, in: statement)
            self.bind(event.provider.rawValue, at: 4, in: statement)
            self.bind(event.kind.rawValue, at: 5, in: statement)
            self.bind(event.title, at: 6, in: statement)
            self.bind(event.body, at: 7, in: statement)
            self.bind(event.timestamp.timeIntervalSince1970, at: 8, in: statement)
            self.bind(event.nativeSummary, at: 9, in: statement)
            self.bind(self.encodeJSON(event.keywords, fallback: "[]"), at: 10, in: statement)
            self.bind(event.isPlanContent ? 1 : 0, at: 11, in: statement)
            self.bind(self.encodeJSON(event.metadata, fallback: "{}"), at: 12, in: statement)
            self.bind(event.rawPayload, at: 13, in: statement)
            self.bind(Date().timeIntervalSince1970, at: 14, in: statement)
        })
    }

    func upsertCard(_ card: MemoryCard) throws {
        let sql = """
        INSERT INTO memory_cards (
            id, source_id, source_file_id, event_id, provider, title, summary, detail, keywords_json, score,
            created_at, updated_at, is_plan_content, metadata_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            source_id = excluded.source_id,
            source_file_id = excluded.source_file_id,
            event_id = excluded.event_id,
            provider = excluded.provider,
            title = excluded.title,
            summary = excluded.summary,
            detail = excluded.detail,
            keywords_json = excluded.keywords_json,
            score = excluded.score,
            updated_at = excluded.updated_at,
            is_plan_content = excluded.is_plan_content,
            metadata_json = excluded.metadata_json;
        """

        try execute(sql: sql, bind: { statement in
            self.bind(card.id.uuidString, at: 1, in: statement)
            self.bind(card.sourceID.uuidString, at: 2, in: statement)
            self.bind(card.sourceFileID.uuidString, at: 3, in: statement)
            self.bind(card.eventID.uuidString, at: 4, in: statement)
            self.bind(card.provider.rawValue, at: 5, in: statement)
            self.bind(card.title, at: 6, in: statement)
            self.bind(card.summary, at: 7, in: statement)
            self.bind(card.detail, at: 8, in: statement)
            self.bind(self.encodeJSON(card.keywords, fallback: "[]"), at: 9, in: statement)
            self.bind(card.score, at: 10, in: statement)
            self.bind(card.createdAt.timeIntervalSince1970, at: 11, in: statement)
            self.bind(card.updatedAt.timeIntervalSince1970, at: 12, in: statement)
            self.bind(card.isPlanContent ? 1 : 0, at: 13, in: statement)
            self.bind(self.encodeJSON(card.metadata, fallback: "{}"), at: 14, in: statement)
        })

        try refreshMemoryLinks(for: card)
    }

    func refreshMemoryLinks(for card: MemoryCard, topLimit: Int = 12) throws {
        try ensureLinkSchema()
        let normalizedLimit = max(1, min(topLimit, 24))
        try execute(sql: "DELETE FROM memory_links WHERE from_card_id = ?;", bind: { statement in
            self.bind(card.id.uuidString, at: 1, in: statement)
        })

        let candidatesSQL = """
        SELECT
            id, source_id, source_file_id, event_id, provider, title, summary, detail, keywords_json,
            score, created_at, updated_at, is_plan_content, metadata_json
        FROM memory_cards
        WHERE id != ?
            AND provider = ?
            AND is_plan_content = 0
        ORDER BY updated_at DESC
        LIMIT 240;
        """

        let candidates: [MemoryCard] = try query(sql: candidatesSQL, bind: { statement in
            self.bind(card.id.uuidString, at: 1, in: statement)
            self.bind(card.provider.rawValue, at: 2, in: statement)
        }, mapRow: { statement in
            self.memoryCard(from: statement)
        })

        if candidates.isEmpty { return }

        let sorted = candidates.compactMap { candidate -> (MemoryCard, String, Double, [String: String])? in
            let scored = self.scoreLink(from: card, to: candidate)
            guard scored.confidence >= 0.35 else { return nil }
            return (candidate, scored.linkType, scored.confidence, scored.metadata)
        }.sorted { lhs, rhs in
            if lhs.2 == rhs.2 {
                return lhs.0.updatedAt > rhs.0.updatedAt
            }
            return lhs.2 > rhs.2
        }

        if sorted.isEmpty { return }
        let now = Date().timeIntervalSince1970
        for (candidate, linkType, confidence, metadata) in sorted.prefix(normalizedLimit) {
            let linkID = MemoryIdentifier.stableUUID(
                for: "link|\(card.id.uuidString)|\(candidate.id.uuidString)|\(linkType)"
            )
            let insertSQL = """
            INSERT INTO memory_links (
                id, from_card_id, to_card_id, link_type, confidence, metadata_json, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(from_card_id, to_card_id) DO UPDATE SET
                link_type = excluded.link_type,
                confidence = excluded.confidence,
                metadata_json = excluded.metadata_json,
                updated_at = excluded.updated_at;
            """
            try execute(sql: insertSQL, bind: { statement in
                self.bind(linkID.uuidString, at: 1, in: statement)
                self.bind(card.id.uuidString, at: 2, in: statement)
                self.bind(candidate.id.uuidString, at: 3, in: statement)
                self.bind(linkType, at: 4, in: statement)
                self.bind(confidence, at: 5, in: statement)
                self.bind(self.encodeJSON(metadata, fallback: "{}"), at: 6, in: statement)
                self.bind(now, at: 7, in: statement)
                self.bind(now, at: 8, in: statement)
            })
        }
    }

    func fetchRelatedCards(
        forCardID cardID: UUID,
        minConfidence: Double = 0.35,
        limit: Int = 8
    ) throws -> [MemoryCard] {
        try ensureLinkSchema()
        let normalizedLimit = max(1, min(limit, 24))
        let sql = """
        SELECT
            c.id, c.source_id, c.source_file_id, c.event_id, c.provider, c.title, c.summary, c.detail,
            c.keywords_json, c.score, c.created_at, c.updated_at, c.is_plan_content, c.metadata_json
        FROM memory_links l
        JOIN memory_cards c ON c.id = l.to_card_id
        WHERE l.from_card_id = ?
            AND l.confidence >= ?
        ORDER BY l.confidence DESC, c.updated_at DESC
        LIMIT ?;
        """

        return try query(sql: sql, bind: { statement in
            self.bind(cardID.uuidString, at: 1, in: statement)
            self.bind(minConfidence, at: 2, in: statement)
            self.bind(Int64(normalizedLimit), at: 3, in: statement)
        }, mapRow: { statement in
            self.memoryCard(from: statement)
        })
    }

    func upsertLesson(_ lesson: MemoryLesson) throws {
        let sql = """
        INSERT INTO memory_lessons (
            id, source_id, source_file_id, event_id, card_id, provider, mistake_pattern, improved_prompt,
            rationale, validation_confidence, source_metadata_json, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(card_id) DO UPDATE SET
            id = excluded.id,
            source_id = excluded.source_id,
            source_file_id = excluded.source_file_id,
            event_id = excluded.event_id,
            provider = excluded.provider,
            mistake_pattern = excluded.mistake_pattern,
            improved_prompt = excluded.improved_prompt,
            rationale = excluded.rationale,
            validation_confidence = excluded.validation_confidence,
            source_metadata_json = excluded.source_metadata_json,
            updated_at = excluded.updated_at;
        """

        try execute(sql: sql, bind: { statement in
            self.bind(lesson.id.uuidString, at: 1, in: statement)
            self.bind(lesson.sourceID.uuidString, at: 2, in: statement)
            self.bind(lesson.sourceFileID.uuidString, at: 3, in: statement)
            self.bind(lesson.eventID.uuidString, at: 4, in: statement)
            self.bind(lesson.cardID.uuidString, at: 5, in: statement)
            self.bind(lesson.provider.rawValue, at: 6, in: statement)
            self.bind(lesson.mistakePattern, at: 7, in: statement)
            self.bind(lesson.improvedPrompt, at: 8, in: statement)
            self.bind(lesson.rationale, at: 9, in: statement)
            self.bind(lesson.validationConfidence, at: 10, in: statement)
            self.bind(self.encodeJSON(lesson.sourceMetadata, fallback: "{}"), at: 11, in: statement)
            self.bind(lesson.createdAt.timeIntervalSince1970, at: 12, in: statement)
            self.bind(lesson.updatedAt.timeIntervalSince1970, at: 13, in: statement)
        })
    }

    func insertRewriteSuggestion(_ suggestion: RewriteSuggestion) throws {
        let sql = """
        INSERT INTO rewrite_suggestions (
            id, card_id, provider, original_text, suggested_text, rationale, confidence, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            card_id = excluded.card_id,
            provider = excluded.provider,
            original_text = excluded.original_text,
            suggested_text = excluded.suggested_text,
            rationale = excluded.rationale,
            confidence = excluded.confidence,
            created_at = excluded.created_at;
        """

        try execute(sql: sql, bind: { statement in
            self.bind(suggestion.id.uuidString, at: 1, in: statement)
            self.bind(suggestion.cardID.uuidString, at: 2, in: statement)
            self.bind(suggestion.provider.rawValue, at: 3, in: statement)
            self.bind(suggestion.originalText, at: 4, in: statement)
            self.bind(suggestion.suggestedText, at: 5, in: statement)
            self.bind(suggestion.rationale, at: 6, in: statement)
            self.bind(suggestion.confidence, at: 7, in: statement)
            self.bind(suggestion.createdAt.timeIntervalSince1970, at: 8, in: statement)
        })
    }

    func upsertPatternStats(_ stats: MemoryPatternStats) throws {
        let sql = """
        INSERT INTO memory_pattern_stats (
            pattern_key, scope_key, app_name, bundle_id, surface_label,
            project_name, repository_name, occurrence_count, good_repeat_count, bad_repeat_count,
            first_seen_at, last_seen_at, last_outcome, confidence, metadata_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(pattern_key) DO UPDATE SET
            scope_key = excluded.scope_key,
            app_name = excluded.app_name,
            bundle_id = excluded.bundle_id,
            surface_label = excluded.surface_label,
            project_name = excluded.project_name,
            repository_name = excluded.repository_name,
            occurrence_count = excluded.occurrence_count,
            good_repeat_count = excluded.good_repeat_count,
            bad_repeat_count = excluded.bad_repeat_count,
            first_seen_at = excluded.first_seen_at,
            last_seen_at = excluded.last_seen_at,
            last_outcome = excluded.last_outcome,
            confidence = excluded.confidence,
            metadata_json = excluded.metadata_json;
        """

        try execute(sql: sql, bind: { statement in
            self.bind(stats.patternKey, at: 1, in: statement)
            self.bind(stats.scopeKey, at: 2, in: statement)
            self.bind(stats.appName, at: 3, in: statement)
            self.bind(stats.bundleID, at: 4, in: statement)
            self.bind(stats.surfaceLabel, at: 5, in: statement)
            self.bind(stats.projectName, at: 6, in: statement)
            self.bind(stats.repositoryName, at: 7, in: statement)
            self.bind(Int64(stats.occurrenceCount), at: 8, in: statement)
            self.bind(Int64(stats.goodRepeatCount), at: 9, in: statement)
            self.bind(Int64(stats.badRepeatCount), at: 10, in: statement)
            self.bind(stats.firstSeenAt.timeIntervalSince1970, at: 11, in: statement)
            self.bind(stats.lastSeenAt.timeIntervalSince1970, at: 12, in: statement)
            self.bind(stats.lastOutcome.rawValue, at: 13, in: statement)
            self.bind(stats.confidence, at: 14, in: statement)
            self.bind(self.encodeJSON(stats.metadata, fallback: "{}"), at: 15, in: statement)
        })
    }

    func fetchPatternStats(
        scopeKey: String? = nil,
        limit: Int = 120
    ) throws -> [MemoryPatternStats] {
        let normalizedScopeKey = scopeKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLimit = max(1, min(limit, 2000))
        let sql = """
        SELECT
            pattern_key, scope_key, app_name, bundle_id, surface_label, project_name, repository_name,
            occurrence_count, good_repeat_count, bad_repeat_count, first_seen_at, last_seen_at,
            last_outcome, confidence, metadata_json
        FROM memory_pattern_stats
        WHERE (? IS NULL OR scope_key = ?)
        ORDER BY last_seen_at DESC
        LIMIT ?;
        """

        return try query(sql: sql, bind: { statement in
            self.bind(normalizedScopeKey, at: 1, in: statement)
            self.bind(normalizedScopeKey, at: 2, in: statement)
            self.bind(Int64(normalizedLimit), at: 3, in: statement)
        }, mapRow: { statement in
            let rawOutcome = self.readString(at: 12, in: statement) ?? MemoryPatternOutcome.neutral.rawValue
            return MemoryPatternStats(
                patternKey: self.readString(at: 0, in: statement) ?? "",
                scopeKey: self.readString(at: 1, in: statement) ?? "",
                appName: self.readString(at: 2, in: statement) ?? "Unknown App",
                bundleID: self.readString(at: 3, in: statement) ?? "unknown.bundle",
                surfaceLabel: self.readString(at: 4, in: statement) ?? "Unknown Surface",
                projectName: self.readString(at: 5, in: statement),
                repositoryName: self.readString(at: 6, in: statement),
                occurrenceCount: Int(sqlite3_column_int64(statement, 7)),
                goodRepeatCount: Int(sqlite3_column_int64(statement, 8)),
                badRepeatCount: Int(sqlite3_column_int64(statement, 9)),
                firstSeenAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
                lastSeenAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 11)),
                lastOutcome: self.patternOutcome(from: rawOutcome),
                confidence: sqlite3_column_double(statement, 13),
                metadata: self.decodeStringDictionary(from: self.readString(at: 14, in: statement) ?? "{}")
            )
        })
    }

    func fetchPatternStats(patternKey: String) throws -> MemoryPatternStats? {
        let normalizedPatternKey = patternKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPatternKey.isEmpty else { return nil }
        return try fetchPatternStatsByKeys(patternKeys: [normalizedPatternKey]).first
    }

    func fetchPatternStatsByKeys(patternKeys: [String]) throws -> [MemoryPatternStats] {
        let normalizedKeys = patternKeys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalizedKeys.isEmpty else { return [] }

        let placeholders = Array(repeating: "?", count: normalizedKeys.count).joined(separator: ", ")
        let sql = """
        SELECT
            pattern_key, scope_key, app_name, bundle_id, surface_label, project_name, repository_name,
            occurrence_count, good_repeat_count, bad_repeat_count, first_seen_at, last_seen_at,
            last_outcome, confidence, metadata_json
        FROM memory_pattern_stats
        WHERE pattern_key IN (\(placeholders))
        ORDER BY last_seen_at DESC;
        """

        return try query(sql: sql, bind: { statement in
            for (index, value) in normalizedKeys.enumerated() {
                self.bind(value, at: Int32(index + 1), in: statement)
            }
        }, mapRow: { statement in
            let rawOutcome = self.readString(at: 12, in: statement) ?? MemoryPatternOutcome.neutral.rawValue
            return MemoryPatternStats(
                patternKey: self.readString(at: 0, in: statement) ?? "",
                scopeKey: self.readString(at: 1, in: statement) ?? "",
                appName: self.readString(at: 2, in: statement) ?? "Unknown App",
                bundleID: self.readString(at: 3, in: statement) ?? "unknown.bundle",
                surfaceLabel: self.readString(at: 4, in: statement) ?? "Unknown Surface",
                projectName: self.readString(at: 5, in: statement),
                repositoryName: self.readString(at: 6, in: statement),
                occurrenceCount: Int(sqlite3_column_int64(statement, 7)),
                goodRepeatCount: Int(sqlite3_column_int64(statement, 8)),
                badRepeatCount: Int(sqlite3_column_int64(statement, 9)),
                firstSeenAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
                lastSeenAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 11)),
                lastOutcome: self.patternOutcome(from: rawOutcome),
                confidence: sqlite3_column_double(statement, 13),
                metadata: self.decodeStringDictionary(from: self.readString(at: 14, in: statement) ?? "{}")
            )
        })
    }

    func insertPatternOccurrence(_ occurrence: MemoryPatternOccurrence) throws {
        let sql = """
        INSERT INTO memory_pattern_occurrences (
            id, pattern_key, card_id, lesson_id, event_timestamp, outcome, trigger, metadata_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            pattern_key = excluded.pattern_key,
            card_id = excluded.card_id,
            lesson_id = excluded.lesson_id,
            event_timestamp = excluded.event_timestamp,
            outcome = excluded.outcome,
            trigger = excluded.trigger,
            metadata_json = excluded.metadata_json;
        """

        try execute(sql: sql, bind: { statement in
            self.bind(occurrence.id.uuidString, at: 1, in: statement)
            self.bind(occurrence.patternKey, at: 2, in: statement)
            self.bind(occurrence.cardID?.uuidString, at: 3, in: statement)
            self.bind(occurrence.lessonID?.uuidString, at: 4, in: statement)
            self.bind(occurrence.eventTimestamp.timeIntervalSince1970, at: 5, in: statement)
            self.bind(occurrence.outcome.rawValue, at: 6, in: statement)
            self.bind(occurrence.trigger.rawValue, at: 7, in: statement)
            self.bind(self.encodeJSON(occurrence.metadata, fallback: "{}"), at: 8, in: statement)
        })
    }

    func recordPatternOccurrence(
        patternKey: String,
        scope: MemoryScopeContext,
        cardID: UUID? = nil,
        lessonID: UUID? = nil,
        trigger: MemoryPromotionTrigger,
        outcome: MemoryPatternOutcome,
        confidence: Double,
        metadata: [String: String] = [:],
        timestamp: Date = Date()
    ) throws {
        let normalizedPatternKey = patternKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPatternKey.isEmpty else { return }

        let existing = try fetchPatternStats(patternKey: normalizedPatternKey)
        let occurrenceCount = (existing?.occurrenceCount ?? 0) + 1
        let goodRepeatCount = (existing?.goodRepeatCount ?? 0) + (outcome == .good ? 1 : 0)
        let badRepeatCount = (existing?.badRepeatCount ?? 0) + (outcome == .bad ? 1 : 0)
        let firstSeenAt = existing?.firstSeenAt ?? timestamp
        let lastSeenAt = timestamp
        let mergedConfidence = min(
            1.0,
            max(
                0.0,
                existing == nil
                    ? confidence
                    : ((existing!.confidence * Double(max(1, existing!.occurrenceCount))) + confidence) / Double(occurrenceCount)
            )
        )
        var mergedMetadata = existing?.metadata ?? [:]
        for (key, value) in metadata {
            let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedKey.isEmpty, !normalizedValue.isEmpty else { continue }
            mergedMetadata[normalizedKey] = normalizedValue
        }

        let updatedStats = MemoryPatternStats(
            patternKey: normalizedPatternKey,
            scopeKey: scope.scopeKey,
            appName: scope.appName,
            bundleID: scope.bundleID,
            surfaceLabel: scope.surfaceLabel,
            projectName: scope.projectName,
            repositoryName: scope.repositoryName,
            occurrenceCount: occurrenceCount,
            goodRepeatCount: goodRepeatCount,
            badRepeatCount: badRepeatCount,
            firstSeenAt: firstSeenAt,
            lastSeenAt: lastSeenAt,
            lastOutcome: outcome,
            confidence: mergedConfidence,
            metadata: mergedMetadata
        )
        try upsertPatternStats(updatedStats)

        let occurrence = MemoryPatternOccurrence(
            id: MemoryIdentifier.stableUUID(
                for: "pattern-occurrence|\(normalizedPatternKey)|\(cardID?.uuidString ?? "-")|\(lessonID?.uuidString ?? "-")|\(trigger.rawValue)|\(iso8601Timestamp(timestamp))"
            ),
            patternKey: normalizedPatternKey,
            cardID: cardID,
            lessonID: lessonID,
            eventTimestamp: timestamp,
            outcome: outcome,
            trigger: trigger,
            metadata: mergedMetadata
        )
        try insertPatternOccurrence(occurrence)
    }

    func fetchPatternOccurrences(
        patternKey: String,
        limit: Int = 80
    ) throws -> [MemoryPatternOccurrence] {
        let normalizedPatternKey = patternKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPatternKey.isEmpty else { return [] }
        let normalizedLimit = max(1, min(limit, 2000))
        let sql = """
        SELECT
            id, pattern_key, card_id, lesson_id, event_timestamp, outcome, trigger, metadata_json
        FROM memory_pattern_occurrences
        WHERE pattern_key = ?
        ORDER BY event_timestamp DESC
        LIMIT ?;
        """

        return try query(sql: sql, bind: { statement in
            self.bind(normalizedPatternKey, at: 1, in: statement)
            self.bind(Int64(normalizedLimit), at: 2, in: statement)
        }, mapRow: { statement in
            let id = UUID(uuidString: self.readString(at: 0, in: statement) ?? "") ?? UUID()
            let cardID = UUID(uuidString: self.readString(at: 2, in: statement) ?? "")
            let lessonID = UUID(uuidString: self.readString(at: 3, in: statement) ?? "")
            let outcome = self.patternOutcome(from: self.readString(at: 5, in: statement) ?? "")
            let trigger = MemoryPromotionTrigger(rawValue: self.readString(at: 6, in: statement) ?? "")
                ?? .manualCompaction
            let metadata = self.decodeStringDictionary(from: self.readString(at: 7, in: statement) ?? "{}")

            return MemoryPatternOccurrence(
                id: id,
                patternKey: self.readString(at: 1, in: statement) ?? normalizedPatternKey,
                cardID: cardID,
                lessonID: lessonID,
                eventTimestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                outcome: outcome,
                trigger: trigger,
                metadata: metadata
            )
        })
    }

    func deletePattern(patternKey: String) throws {
        let normalizedPatternKey = patternKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPatternKey.isEmpty else { return }
        try execute(sql: "DELETE FROM memory_pattern_stats WHERE pattern_key = ?;", bind: { statement in
            self.bind(normalizedPatternKey, at: 1, in: statement)
        })
    }

    func purgeByTieredRetention(
        rawEvidenceDays: Int = 30,
        unvalidatedLessonDays: Int = 60,
        validatedDays: Int = 365,
        now: Date = Date()
    ) throws -> (cardsDeleted: Int, lessonsDeleted: Int, patternsDeleted: Int, occurrencesDeleted: Int) {
        let rawCutoff = now.addingTimeInterval(-Double(max(1, rawEvidenceDays)) * 86_400).timeIntervalSince1970
        let unvalidatedCutoff = now.addingTimeInterval(-Double(max(1, unvalidatedLessonDays)) * 86_400).timeIntervalSince1970
        let validatedCutoff = now.addingTimeInterval(-Double(max(1, validatedDays)) * 86_400).timeIntervalSince1970

        let staleRawCardsSQL = """
        SELECT COUNT(*)
        FROM memory_cards
        WHERE is_plan_content = 0
            AND updated_at < ?
            AND (
                score < 0.60
                OR lower(coalesce(json_extract(metadata_json, '$.origin'), '')) = 'conversation-history'
            );
        """
        let staleRawCardsCount = try scalarInt(sql: staleRawCardsSQL, bind: { statement in
            self.bind(rawCutoff, at: 1, in: statement)
        })

        try execute(sql: """
        DELETE FROM memory_cards
        WHERE is_plan_content = 0
            AND updated_at < ?
            AND (
                score < 0.60
                OR lower(coalesce(json_extract(metadata_json, '$.origin'), '')) = 'conversation-history'
            );
        """, bind: { statement in
            self.bind(rawCutoff, at: 1, in: statement)
        })

        let staleUnvalidatedLessonsSQL = """
        SELECT COUNT(*)
        FROM memory_lessons
        WHERE updated_at < ?
            AND lower(coalesce(json_extract(source_metadata_json, '$.validation_state'), 'unvalidated')) = 'unvalidated';
        """
        let staleUnvalidatedLessonsCount = try scalarInt(sql: staleUnvalidatedLessonsSQL, bind: { statement in
            self.bind(unvalidatedCutoff, at: 1, in: statement)
        })

        try execute(sql: """
        DELETE FROM memory_lessons
        WHERE updated_at < ?
            AND lower(coalesce(json_extract(source_metadata_json, '$.validation_state'), 'unvalidated')) = 'unvalidated';
        """, bind: { statement in
            self.bind(unvalidatedCutoff, at: 1, in: statement)
        })

        let stalePatternsCount = try scalarInt(sql: """
        SELECT COUNT(*)
        FROM memory_pattern_stats
        WHERE last_seen_at < ?;
        """, bind: { statement in
            self.bind(validatedCutoff, at: 1, in: statement)
        })

        try execute(sql: "DELETE FROM memory_pattern_stats WHERE last_seen_at < ?;", bind: { statement in
            self.bind(validatedCutoff, at: 1, in: statement)
        })

        let staleOccurrencesCount = try scalarInt(sql: """
        SELECT COUNT(*)
        FROM memory_pattern_occurrences
        WHERE event_timestamp < ?;
        """, bind: { statement in
            self.bind(validatedCutoff, at: 1, in: statement)
        })

        try execute(sql: "DELETE FROM memory_pattern_occurrences WHERE event_timestamp < ?;", bind: { statement in
            self.bind(validatedCutoff, at: 1, in: statement)
        })

        return (
            cardsDeleted: staleRawCardsCount,
            lessonsDeleted: staleUnvalidatedLessonsCount,
            patternsDeleted: stalePatternsCount,
            occurrencesDeleted: staleOccurrencesCount
        )
    }

    func upsertFeedbackRewriteMemory(
        originalText: String,
        rewrittenText: String,
        rationale: String,
        confidence: Double,
        timestamp: Date = Date()
    ) throws {
        let normalizedOriginal = MemoryTextNormalizer.collapsedWhitespace(originalText)
        let normalizedRewritten = MemoryTextNormalizer.collapsedWhitespace(rewrittenText)
        guard !normalizedOriginal.isEmpty, !normalizedRewritten.isEmpty else {
            return
        }

        let sourceID = MemoryIdentifier.stableUUID(for: "source|feedback-rewrites")
        let sourceFileID = MemoryIdentifier.stableUUID(for: "file|\(sourceID.uuidString)|feedback-rewrites")
        let eventID = MemoryIdentifier.stableUUID(
            for: "event|\(sourceFileID.uuidString)|\(normalizedOriginal)|\(normalizedRewritten)"
        )
        let cardID = MemoryIdentifier.stableUUID(
            for: "card|\(eventID.uuidString)|\(normalizedOriginal)|\(normalizedRewritten)"
        )
        let suggestionID = MemoryIdentifier.stableUUID(
            for: "rewrite|\(cardID.uuidString)|\(normalizedOriginal)|\(normalizedRewritten)"
        )

        let source = MemorySource(
            id: sourceID,
            provider: .unknown,
            rootPath: "internal://prompt-rewrite-feedback",
            displayName: "Open Assist Learned Rewrites",
            discoveredAt: timestamp,
            metadata: [
                "origin": "user-feedback"
            ]
        )
        try upsertSource(source)

        let pseudoPath = "feedback/rewrite-feedback.jsonl"
        let sourceFile = MemorySourceFile(
            id: sourceFileID,
            sourceID: sourceID,
            absolutePath: pseudoPath,
            relativePath: pseudoPath,
            fileHash: MemoryIdentifier.stableHexDigest(for: "\(normalizedOriginal)|\(normalizedRewritten)"),
            fileSizeBytes: Int64((normalizedOriginal + normalizedRewritten).utf8.count),
            modifiedAt: timestamp,
            indexedAt: timestamp,
            parseError: nil
        )
        try upsertSourceFile(sourceFile)

        let summary = MemoryTextNormalizer.normalizedSummary("User-confirmed prompt fix: \(normalizedOriginal) -> \(normalizedRewritten)")
        let event = MemoryEvent(
            id: eventID,
            sourceID: sourceID,
            sourceFileID: sourceFileID,
            provider: .unknown,
            kind: .rewrite,
            title: "User Confirmed Prompt Fix",
            body: "\(normalizedOriginal) -> \(normalizedRewritten)",
            timestamp: timestamp,
            nativeSummary: summary,
            keywords: MemoryTextNormalizer.keywords(from: "\(normalizedOriginal) \(normalizedRewritten)", limit: 16),
            isPlanContent: false,
            metadata: [
                "original_text": normalizedOriginal,
                "suggested_text": normalizedRewritten,
                "rationale": rationale,
                "origin": "prompt-rewrite-feedback"
            ],
            rawPayload: nil
        )
        try upsertEvent(event)

        let card = MemoryCard(
            id: cardID,
            sourceID: sourceID,
            sourceFileID: sourceFileID,
            eventID: eventID,
            provider: .unknown,
            title: MemoryTextNormalizer.normalizedTitle(normalizedOriginal, fallback: "Prompt rewrite"),
            summary: summary,
            detail: "\(normalizedOriginal)\n->\n\(normalizedRewritten)",
            keywords: MemoryTextNormalizer.keywords(from: "\(normalizedOriginal) \(normalizedRewritten)", limit: 16),
            score: 0.96,
            createdAt: timestamp,
            updatedAt: timestamp,
            isPlanContent: false,
            metadata: [
                "origin": "prompt-rewrite-feedback",
                "rationale": rationale
            ]
        )
        try upsertCard(card)

        let normalizedConfidence = min(1.0, max(0.05, confidence))
        let suggestion = RewriteSuggestion(
            id: suggestionID,
            cardID: cardID,
            provider: .unknown,
            originalText: normalizedOriginal,
            suggestedText: normalizedRewritten,
            rationale: rationale,
            confidence: normalizedConfidence,
            createdAt: timestamp
        )
        try insertRewriteSuggestion(suggestion)

        let lesson = MemoryLesson(
            id: MemoryIdentifier.stableUUID(
                for: "lesson|\(cardID.uuidString)|\(normalizedOriginal)|\(normalizedRewritten)"
            ),
            sourceID: sourceID,
            sourceFileID: sourceFileID,
            eventID: eventID,
            cardID: cardID,
            provider: .unknown,
            mistakePattern: normalizedOriginal,
            improvedPrompt: normalizedRewritten,
            rationale: rationale,
            validationConfidence: max(0.95, normalizedConfidence),
            sourceMetadata: [
                "origin": "prompt-rewrite-feedback",
                "validation_state": "user-confirmed",
                "extraction_method": "user-feedback"
            ],
            createdAt: timestamp,
            updatedAt: timestamp
        )
        try upsertLesson(lesson)
        try supersedeCompetingLessons(
            with: lesson,
            reason: "Superseded by a newer user-confirmed correction.",
            timestamp: timestamp
        )

        let scope = MemoryScopeContext(
            appName: "Open Assist",
            bundleID: "com.openassist.feedback",
            surfaceLabel: "Prompt Rewrite Feedback",
            projectName: nil,
            repositoryName: nil,
            isCodingContext: false
        )
        let patternKey = MemoryIdentifier.stableHexDigest(
            for: "pattern|\(scope.scopeKey)|\(normalizedOriginal.lowercased())|\(normalizedRewritten.lowercased())"
        )
        try recordPatternOccurrence(
            patternKey: patternKey,
            scope: scope,
            cardID: cardID,
            lessonID: lesson.id,
            trigger: .manualPin,
            outcome: .good,
            confidence: max(0.80, normalizedConfidence),
            metadata: [
                "origin": "prompt-rewrite-feedback",
                "validation_state": MemoryRewriteLessonValidationState.userConfirmed.rawValue
            ],
            timestamp: timestamp
        )
    }

    func fetchRewriteSuggestions(
        query searchQuery: String,
        provider: MemoryProviderKind? = nil,
        limit: Int = 10
    ) throws -> [RewriteSuggestion] {
        let normalizedQuery = MemoryTextNormalizer.collapsedWhitespace(searchQuery)
        let hasSearchTerm = !normalizedQuery.isEmpty
        let likeValue = "%\(escapedLike(normalizedQuery))%"
        let providerRawValue = provider?.rawValue
        let normalizedLimit = max(1, min(limit, 200))

        let sql = """
        SELECT
            id, card_id, provider, original_text, suggested_text, rationale, confidence, created_at
        FROM rewrite_suggestions
        WHERE (? IS NULL OR provider = ?)
            AND (? = 0 OR original_text LIKE ? ESCAPE '\\')
        ORDER BY confidence DESC, created_at DESC
        LIMIT ?;
        """

        return try self.query(sql: sql, bind: { statement in
            self.bind(providerRawValue, at: 1, in: statement)
            self.bind(providerRawValue, at: 2, in: statement)
            self.bind(hasSearchTerm ? 1 : 0, at: 3, in: statement)
            self.bind(likeValue, at: 4, in: statement)
            self.bind(Int64(normalizedLimit), at: 5, in: statement)
        }, mapRow: { statement in
            RewriteSuggestion(
                id: UUID(uuidString: self.readString(at: 0, in: statement) ?? "") ?? UUID(),
                cardID: UUID(uuidString: self.readString(at: 1, in: statement) ?? "") ?? UUID(),
                provider: MemoryProviderKind(rawValue: self.readString(at: 2, in: statement) ?? "") ?? .unknown,
                originalText: self.readString(at: 3, in: statement) ?? "",
                suggestedText: self.readString(at: 4, in: statement) ?? "",
                rationale: self.readString(at: 5, in: statement) ?? "",
                confidence: sqlite3_column_double(statement, 6),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
            )
        })
    }

    func fetchLessonsForRewrite(
        query searchQuery: String,
        provider: MemoryProviderKind? = nil,
        limit: Int = 20
    ) throws -> [MemoryLesson] {
        let normalizedQuery = MemoryTextNormalizer.collapsedWhitespace(searchQuery)
        let hasSearchTerm = !normalizedQuery.isEmpty
        let likeValue = "%\(escapedLike(normalizedQuery))%"
        let providerRawValue = provider?.rawValue
        let normalizedLimit = max(1, min(limit, 300))

        let sql = """
        SELECT
            id, source_id, source_file_id, event_id, card_id, provider, mistake_pattern, improved_prompt,
            rationale, validation_confidence, source_metadata_json, created_at, updated_at
        FROM memory_lessons
        WHERE (? IS NULL OR provider = ?)
            AND (
                ? = 0
                OR mistake_pattern LIKE ? ESCAPE '\\'
                OR improved_prompt LIKE ? ESCAPE '\\'
                OR rationale LIKE ? ESCAPE '\\'
            )
        ORDER BY validation_confidence DESC, updated_at DESC
        LIMIT ?;
        """

        return try self.query(sql: sql, bind: { statement in
            self.bind(providerRawValue, at: 1, in: statement)
            self.bind(providerRawValue, at: 2, in: statement)
            self.bind(hasSearchTerm ? 1 : 0, at: 3, in: statement)
            self.bind(likeValue, at: 4, in: statement)
            self.bind(likeValue, at: 5, in: statement)
            self.bind(likeValue, at: 6, in: statement)
            self.bind(Int64(normalizedLimit), at: 7, in: statement)
        }, mapRow: { statement in
            MemoryLesson(
                id: UUID(uuidString: self.readString(at: 0, in: statement) ?? "") ?? UUID(),
                sourceID: UUID(uuidString: self.readString(at: 1, in: statement) ?? "") ?? UUID(),
                sourceFileID: UUID(uuidString: self.readString(at: 2, in: statement) ?? "") ?? UUID(),
                eventID: UUID(uuidString: self.readString(at: 3, in: statement) ?? "") ?? UUID(),
                cardID: UUID(uuidString: self.readString(at: 4, in: statement) ?? "") ?? UUID(),
                provider: MemoryProviderKind(rawValue: self.readString(at: 5, in: statement) ?? "") ?? .unknown,
                mistakePattern: self.readString(at: 6, in: statement) ?? "",
                improvedPrompt: self.readString(at: 7, in: statement) ?? "",
                rationale: self.readString(at: 8, in: statement) ?? "",
                validationConfidence: sqlite3_column_double(statement, 9),
                sourceMetadata: self.decodeStringDictionary(from: self.readString(at: 10, in: statement) ?? "{}"),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 11)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 12))
            )
        })
    }

    func supersedeCompetingLessons(
        with betterLesson: MemoryLesson,
        reason: String,
        timestamp: Date = Date()
    ) throws {
        let normalizedMistake = MemoryTextNormalizer.collapsedWhitespace(betterLesson.mistakePattern)
        let normalizedCorrection = MemoryTextNormalizer.collapsedWhitespace(betterLesson.improvedPrompt)
        guard !normalizedMistake.isEmpty, !normalizedCorrection.isEmpty else { return }

        let candidates = try fetchLessonsForRewrite(
            query: "",
            provider: nil,
            limit: 1200
        )

        for lesson in candidates {
            if lesson.id == betterLesson.id {
                continue
            }
            let lessonMistake = MemoryTextNormalizer.collapsedWhitespace(lesson.mistakePattern)
            let lessonCorrection = MemoryTextNormalizer.collapsedWhitespace(lesson.improvedPrompt)
            guard isSameScenario(lessonMistake, normalizedMistake) else { continue }
            guard !isEquivalentCorrection(lessonCorrection, normalizedCorrection) else { continue }

            if lessonValidationState(from: lesson) == .invalidated {
                continue
            }

            guard shouldInvalidateExistingLesson(lesson, replacement: betterLesson) else { continue }
            let betterScore = lessonSelectionScore(for: betterLesson)
            let existingScore = lessonSelectionScore(for: lesson)

            var updated = lesson
            updated.validationConfidence = min(updated.validationConfidence, 0.05)
            updated.updatedAt = timestamp

            var metadata = updated.sourceMetadata
            metadata["validation_state"] = MemoryRewriteLessonValidationState.invalidated.rawValue
            metadata["invalidated_by_lesson_id"] = betterLesson.id.uuidString
            metadata["invalidated_at"] = iso8601Timestamp(timestamp)
            metadata["invalidation_reason"] = MemoryTextNormalizer.normalizedSummary(reason, limit: 240)
            metadata["invalidation_existing_score"] = String(format: "%.3f", existingScore)
            metadata["invalidation_replacement_score"] = String(format: "%.3f", betterScore)
            updated.sourceMetadata = metadata

            try upsertLesson(updated)

            let scope = scopeContext(from: updated.sourceMetadata)
            let patternKey = MemoryIdentifier.stableHexDigest(
                for: "pattern|\(scope.scopeKey)|\(MemoryTextNormalizer.collapsedWhitespace(updated.mistakePattern).lowercased())|\(MemoryTextNormalizer.collapsedWhitespace(updated.improvedPrompt).lowercased())"
            )
            try recordPatternOccurrence(
                patternKey: patternKey,
                scope: scope,
                cardID: updated.cardID,
                lessonID: updated.id,
                trigger: .manualPin,
                outcome: .bad,
                confidence: 0.10,
                metadata: [
                    "origin": "lesson-invalidation",
                    "validation_state": MemoryRewriteLessonValidationState.invalidated.rawValue
                ],
                timestamp: timestamp
            )
        }
    }

    func fetchCardsForRewrite(
        query: String,
        options: MemoryRewriteLookupOptions = MemoryRewriteLookupOptions()
    ) throws -> [MemoryCard] {
        let normalizedQuery = MemoryTextNormalizer.collapsedWhitespace(query)
        let hasSearchTerm = !normalizedQuery.isEmpty
        let likeValue = "%\(escapedLike(normalizedQuery))%"
        let providerRawValue = options.provider?.rawValue
        let sql = """
        SELECT
            id, source_id, source_file_id, event_id, provider, title, summary, detail, keywords_json,
            score, created_at, updated_at, is_plan_content, metadata_json
        FROM memory_cards
        WHERE (? IS NULL OR provider = ?)
            AND (? = 1 OR is_plan_content = 0)
            AND (? = 0 OR title LIKE ? ESCAPE '\\' OR summary LIKE ? ESCAPE '\\' OR detail LIKE ? ESCAPE '\\')
        ORDER BY score DESC, updated_at DESC
        LIMIT ?;
        """

        return try self.query(sql: sql, bind: { statement in
            self.bind(providerRawValue, at: 1, in: statement)
            self.bind(providerRawValue, at: 2, in: statement)
            self.bind(options.includePlanContent ? 1 : 0, at: 3, in: statement)
            self.bind(hasSearchTerm ? 1 : 0, at: 4, in: statement)
            self.bind(likeValue, at: 5, in: statement)
            self.bind(likeValue, at: 6, in: statement)
            self.bind(likeValue, at: 7, in: statement)
            self.bind(Int64(options.limit), at: 8, in: statement)
        }, mapRow: { statement in
            let id = UUID(uuidString: self.readString(at: 0, in: statement) ?? "") ?? UUID()
            let sourceID = UUID(uuidString: self.readString(at: 1, in: statement) ?? "") ?? UUID()
            let sourceFileID = UUID(uuidString: self.readString(at: 2, in: statement) ?? "") ?? UUID()
            let eventID = UUID(uuidString: self.readString(at: 3, in: statement) ?? "") ?? UUID()
            let provider = MemoryProviderKind(rawValue: self.readString(at: 4, in: statement) ?? "") ?? .unknown
            let title = self.readString(at: 5, in: statement) ?? ""
            let summary = self.readString(at: 6, in: statement) ?? ""
            let detail = self.readString(at: 7, in: statement) ?? ""
            let keywordsJSON = self.readString(at: 8, in: statement) ?? "[]"
            let score = sqlite3_column_double(statement, 9)
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 10))
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 11))
            let isPlanContent = sqlite3_column_int(statement, 12) == 1
            let metadataJSON = self.readString(at: 13, in: statement) ?? "{}"

            return MemoryCard(
                id: id,
                sourceID: sourceID,
                sourceFileID: sourceFileID,
                eventID: eventID,
                provider: provider,
                title: title,
                summary: summary,
                detail: detail,
                keywords: self.decodeStringArray(from: keywordsJSON),
                score: score,
                createdAt: createdAt,
                updatedAt: updatedAt,
                isPlanContent: isPlanContent,
                metadata: self.decodeStringDictionary(from: metadataJSON)
            )
        })
    }

    func fetchIndexedEntries(
        query searchQuery: String,
        provider: MemoryProviderKind? = nil,
        sourceRootPath: String? = nil,
        includePlanContent: Bool = false,
        limit: Int = 80
    ) throws -> [MemoryIndexedEntry] {
        let normalizedQuery = MemoryTextNormalizer.collapsedWhitespace(searchQuery)
        let hasSearchTerm = !normalizedQuery.isEmpty
        let likeValue = "%\(escapedLike(normalizedQuery))%"
        let providerRawValue = provider?.rawValue
        let normalizedSourceRootPath = sourceRootPath?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLimit = max(1, min(limit, 400))

        let sql = """
        SELECT
            c.id,
            c.provider,
            s.root_path,
            f.relative_path,
            c.metadata_json,
            e.metadata_json,
            c.title,
            c.summary,
            c.detail,
            e.event_timestamp,
            c.updated_at,
            c.is_plan_content
        FROM memory_cards c
        JOIN memory_sources s ON s.id = c.source_id
        JOIN memory_files f ON f.id = c.source_file_id
        JOIN memory_events e ON e.id = c.event_id
        WHERE (? IS NULL OR c.provider = ?)
            AND (? = 1 OR c.is_plan_content = 0)
            AND (? IS NULL OR s.root_path = ?)
            AND (? = 0 OR c.title LIKE ? ESCAPE '\\' OR c.summary LIKE ? ESCAPE '\\' OR c.detail LIKE ? ESCAPE '\\')
        ORDER BY e.event_timestamp DESC, c.updated_at DESC, c.score DESC
        LIMIT ?;
        """

        return try self.query(sql: sql, bind: { statement in
            self.bind(providerRawValue, at: 1, in: statement)
            self.bind(providerRawValue, at: 2, in: statement)
            self.bind(includePlanContent ? 1 : 0, at: 3, in: statement)
            self.bind(normalizedSourceRootPath, at: 4, in: statement)
            self.bind(normalizedSourceRootPath, at: 5, in: statement)
            self.bind(hasSearchTerm ? 1 : 0, at: 6, in: statement)
            self.bind(likeValue, at: 7, in: statement)
            self.bind(likeValue, at: 8, in: statement)
            self.bind(likeValue, at: 9, in: statement)
            self.bind(Int64(normalizedLimit), at: 10, in: statement)
        }, mapRow: { statement in
            let provider = MemoryProviderKind(rawValue: self.readString(at: 1, in: statement) ?? "") ?? .unknown
            let sourceRootPath = self.readString(at: 2, in: statement) ?? ""
            let sourceFileRelativePath = self.readString(at: 3, in: statement) ?? ""
            let cardMetadata = self.readString(at: 4, in: statement) ?? "{}"
            let eventMetadata = self.readString(at: 5, in: statement) ?? "{}"
            let title = self.readString(at: 6, in: statement) ?? ""
            let summary = self.readString(at: 7, in: statement) ?? ""
            let detail = self.readString(at: 8, in: statement) ?? ""
            let cardMetadataDictionary = self.decodeStringDictionary(from: cardMetadata)
            let eventMetadataDictionary = self.decodeStringDictionary(from: eventMetadata)
            let projectContext = self.inferProjectContext(
                provider: provider,
                cardMetadataJSON: cardMetadata,
                eventMetadataJSON: eventMetadata,
                sourceRootPath: sourceRootPath,
                sourceFileRelativePath: sourceFileRelativePath,
                title: title,
                summary: summary,
                detail: detail
            )

            return MemoryIndexedEntry(
                id: UUID(uuidString: self.readString(at: 0, in: statement) ?? "") ?? UUID(),
                provider: provider,
                sourceRootPath: sourceRootPath,
                sourceFileRelativePath: sourceFileRelativePath,
                projectName: projectContext.projectName,
                repositoryName: projectContext.repositoryName,
                title: title,
                summary: summary,
                detail: detail,
                eventTimestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
                isPlanContent: sqlite3_column_int(statement, 11) == 1,
                issueKey: cardMetadataDictionary["issue_key"] ?? eventMetadataDictionary["issue_key"],
                attemptNumber: self.parseInt(
                    cardMetadataDictionary["attempt_number"] ?? eventMetadataDictionary["attempt_number"]
                ),
                attemptCount: self.parseInt(
                    cardMetadataDictionary["attempt_count"] ?? eventMetadataDictionary["attempt_count"]
                ),
                outcomeStatus: cardMetadataDictionary["outcome_status"] ?? eventMetadataDictionary["outcome_status"],
                outcomeEvidence: cardMetadataDictionary["outcome_evidence"] ?? eventMetadataDictionary["outcome_evidence"],
                fixSummary: cardMetadataDictionary["fix_summary"] ?? eventMetadataDictionary["fix_summary"],
                validationState: cardMetadataDictionary["validation_state"] ?? eventMetadataDictionary["validation_state"],
                invalidatedByAttempt: self.parseInt(
                    cardMetadataDictionary["invalidated_by_attempt"] ?? eventMetadataDictionary["invalidated_by_attempt"]
                ),
                relationConfidence: nil,
                relationType: nil
            )
        })
    }

    func fetchRelatedIndexedEntries(
        forCardID cardID: UUID,
        includePlanContent: Bool = false,
        limit: Int = 8
    ) throws -> [MemoryIndexedEntry] {
        try ensureLinkSchema()
        let normalizedLimit = max(1, min(limit, 24))
        let sql = """
        SELECT
            c.id,
            c.provider,
            s.root_path,
            f.relative_path,
            c.metadata_json,
            e.metadata_json,
            c.title,
            c.summary,
            c.detail,
            e.event_timestamp,
            c.updated_at,
            c.is_plan_content,
            l.confidence,
            l.link_type
        FROM memory_links l
        JOIN memory_cards c ON c.id = l.to_card_id
        JOIN memory_sources s ON s.id = c.source_id
        JOIN memory_files f ON f.id = c.source_file_id
        JOIN memory_events e ON e.id = c.event_id
        WHERE l.from_card_id = ?
            AND (? = 1 OR c.is_plan_content = 0)
        ORDER BY l.confidence DESC, e.event_timestamp DESC
        LIMIT ?;
        """

        return try query(sql: sql, bind: { statement in
            self.bind(cardID.uuidString, at: 1, in: statement)
            self.bind(includePlanContent ? 1 : 0, at: 2, in: statement)
            self.bind(Int64(normalizedLimit), at: 3, in: statement)
        }, mapRow: { statement in
            let provider = MemoryProviderKind(rawValue: self.readString(at: 1, in: statement) ?? "") ?? .unknown
            let sourceRootPath = self.readString(at: 2, in: statement) ?? ""
            let sourceFileRelativePath = self.readString(at: 3, in: statement) ?? ""
            let cardMetadata = self.readString(at: 4, in: statement) ?? "{}"
            let eventMetadata = self.readString(at: 5, in: statement) ?? "{}"
            let cardMetadataDictionary = self.decodeStringDictionary(from: cardMetadata)
            let eventMetadataDictionary = self.decodeStringDictionary(from: eventMetadata)
            let title = self.readString(at: 6, in: statement) ?? ""
            let summary = self.readString(at: 7, in: statement) ?? ""
            let detail = self.readString(at: 8, in: statement) ?? ""
            let projectContext = self.inferProjectContext(
                provider: provider,
                cardMetadataJSON: cardMetadata,
                eventMetadataJSON: eventMetadata,
                sourceRootPath: sourceRootPath,
                sourceFileRelativePath: sourceFileRelativePath,
                title: title,
                summary: summary,
                detail: detail
            )

            return MemoryIndexedEntry(
                id: UUID(uuidString: self.readString(at: 0, in: statement) ?? "") ?? UUID(),
                provider: provider,
                sourceRootPath: sourceRootPath,
                sourceFileRelativePath: sourceFileRelativePath,
                projectName: projectContext.projectName,
                repositoryName: projectContext.repositoryName,
                title: title,
                summary: summary,
                detail: detail,
                eventTimestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
                isPlanContent: sqlite3_column_int(statement, 11) == 1,
                issueKey: cardMetadataDictionary["issue_key"] ?? eventMetadataDictionary["issue_key"],
                attemptNumber: self.parseInt(
                    cardMetadataDictionary["attempt_number"] ?? eventMetadataDictionary["attempt_number"]
                ),
                attemptCount: self.parseInt(
                    cardMetadataDictionary["attempt_count"] ?? eventMetadataDictionary["attempt_count"]
                ),
                outcomeStatus: cardMetadataDictionary["outcome_status"] ?? eventMetadataDictionary["outcome_status"],
                outcomeEvidence: cardMetadataDictionary["outcome_evidence"] ?? eventMetadataDictionary["outcome_evidence"],
                fixSummary: cardMetadataDictionary["fix_summary"] ?? eventMetadataDictionary["fix_summary"],
                validationState: cardMetadataDictionary["validation_state"] ?? eventMetadataDictionary["validation_state"],
                invalidatedByAttempt: self.parseInt(
                    cardMetadataDictionary["invalidated_by_attempt"] ?? eventMetadataDictionary["invalidated_by_attempt"]
                ),
                relationConfidence: sqlite3_column_double(statement, 12),
                relationType: self.readString(at: 13, in: statement)
            )
        })
    }

    func fetchIssueTimelineEntries(
        issueKey: String,
        provider: MemoryProviderKind? = nil,
        includePlanContent: Bool = false,
        limit: Int = 40
    ) throws -> [MemoryIndexedEntry] {
        let normalizedIssueKey = issueKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedIssueKey.isEmpty else { return [] }
        let providerRawValue = provider?.rawValue
        let normalizedLimit = max(1, min(limit, 400))

        let sql = """
        SELECT
            c.id,
            c.provider,
            s.root_path,
            f.relative_path,
            c.metadata_json,
            e.metadata_json,
            c.title,
            c.summary,
            c.detail,
            e.event_timestamp,
            c.updated_at,
            c.is_plan_content
        FROM memory_cards c
        JOIN memory_sources s ON s.id = c.source_id
        JOIN memory_files f ON f.id = c.source_file_id
        JOIN memory_events e ON e.id = c.event_id
        WHERE (? IS NULL OR c.provider = ?)
            AND (? = 1 OR c.is_plan_content = 0)
        ORDER BY e.event_timestamp DESC
        LIMIT ?;
        """

        let entries: [MemoryIndexedEntry] = try query(sql: sql, bind: { statement in
            self.bind(providerRawValue, at: 1, in: statement)
            self.bind(providerRawValue, at: 2, in: statement)
            self.bind(includePlanContent ? 1 : 0, at: 3, in: statement)
            self.bind(Int64(normalizedLimit), at: 4, in: statement)
        }, mapRow: { statement in
            let provider = MemoryProviderKind(rawValue: self.readString(at: 1, in: statement) ?? "") ?? .unknown
            let sourceRootPath = self.readString(at: 2, in: statement) ?? ""
            let sourceFileRelativePath = self.readString(at: 3, in: statement) ?? ""
            let cardMetadata = self.readString(at: 4, in: statement) ?? "{}"
            let eventMetadata = self.readString(at: 5, in: statement) ?? "{}"
            let cardMetadataDictionary = self.decodeStringDictionary(from: cardMetadata)
            let eventMetadataDictionary = self.decodeStringDictionary(from: eventMetadata)
            let title = self.readString(at: 6, in: statement) ?? ""
            let summary = self.readString(at: 7, in: statement) ?? ""
            let detail = self.readString(at: 8, in: statement) ?? ""
            let projectContext = self.inferProjectContext(
                provider: provider,
                cardMetadataJSON: cardMetadata,
                eventMetadataJSON: eventMetadata,
                sourceRootPath: sourceRootPath,
                sourceFileRelativePath: sourceFileRelativePath,
                title: title,
                summary: summary,
                detail: detail
            )

            return MemoryIndexedEntry(
                id: UUID(uuidString: self.readString(at: 0, in: statement) ?? "") ?? UUID(),
                provider: provider,
                sourceRootPath: sourceRootPath,
                sourceFileRelativePath: sourceFileRelativePath,
                projectName: projectContext.projectName,
                repositoryName: projectContext.repositoryName,
                title: title,
                summary: summary,
                detail: detail,
                eventTimestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
                isPlanContent: sqlite3_column_int(statement, 11) == 1,
                issueKey: cardMetadataDictionary["issue_key"] ?? eventMetadataDictionary["issue_key"],
                attemptNumber: self.parseInt(
                    cardMetadataDictionary["attempt_number"] ?? eventMetadataDictionary["attempt_number"]
                ),
                attemptCount: self.parseInt(
                    cardMetadataDictionary["attempt_count"] ?? eventMetadataDictionary["attempt_count"]
                ),
                outcomeStatus: cardMetadataDictionary["outcome_status"] ?? eventMetadataDictionary["outcome_status"],
                outcomeEvidence: cardMetadataDictionary["outcome_evidence"] ?? eventMetadataDictionary["outcome_evidence"],
                fixSummary: cardMetadataDictionary["fix_summary"] ?? eventMetadataDictionary["fix_summary"],
                validationState: cardMetadataDictionary["validation_state"] ?? eventMetadataDictionary["validation_state"],
                invalidatedByAttempt: self.parseInt(
                    cardMetadataDictionary["invalidated_by_attempt"] ?? eventMetadataDictionary["invalidated_by_attempt"]
                ),
                relationConfidence: nil,
                relationType: nil
            )
        })

        let filtered = entries.filter { entry in
            (entry.issueKey?.lowercased() ?? "") == normalizedIssueKey
        }
        return filtered.sorted { lhs, rhs in
            let leftAttempt = lhs.attemptNumber ?? Int.max
            let rightAttempt = rhs.attemptNumber ?? Int.max
            if leftAttempt == rightAttempt {
                return lhs.eventTimestamp < rhs.eventTimestamp
            }
            return leftAttempt < rightAttempt
        }
    }

    func fetchSourceFile(
        sourceID: UUID,
        relativePath: String
    ) throws -> MemorySourceFile? {
        let sql = """
        SELECT
            id, source_id, absolute_path, relative_path, file_hash, file_size_bytes,
            modified_at, indexed_at, parse_error
        FROM memory_files
        WHERE source_id = ? AND relative_path = ?
        LIMIT 1;
        """

        let rows: [MemorySourceFile] = try query(sql: sql, bind: { statement in
            self.bind(sourceID.uuidString, at: 1, in: statement)
            self.bind(relativePath, at: 2, in: statement)
        }, mapRow: { statement in
            MemorySourceFile(
                id: UUID(uuidString: self.readString(at: 0, in: statement) ?? "") ?? UUID(),
                sourceID: UUID(uuidString: self.readString(at: 1, in: statement) ?? "") ?? sourceID,
                absolutePath: self.readString(at: 2, in: statement) ?? "",
                relativePath: self.readString(at: 3, in: statement) ?? "",
                fileHash: self.readString(at: 4, in: statement) ?? "",
                fileSizeBytes: sqlite3_column_int64(statement, 5),
                modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                indexedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
                parseError: self.readString(at: 8, in: statement)
            )
        })

        return rows.first
    }

    func hasIndexedEvents(forSourceFileID sourceFileID: UUID) throws -> Bool {
        let sql = """
        SELECT 1
        FROM memory_events
        WHERE source_file_id = ?
        LIMIT 1;
        """

        let rows: [Int64] = try query(sql: sql, bind: { statement in
            self.bind(sourceFileID.uuidString, at: 1, in: statement)
        }, mapRow: { statement in
            sqlite3_column_int64(statement, 0)
        })

        return !rows.isEmpty
    }

    func clearIndexedMemories() throws {
        try execute(sql: "DELETE FROM memory_pattern_occurrences;")
        try execute(sql: "DELETE FROM memory_pattern_stats;")
        try execute(sql: """
        DELETE FROM rewrite_suggestions
        WHERE card_id IN (
            SELECT id FROM memory_cards WHERE is_plan_content = 0
        );
        """)
        try execute(sql: "DELETE FROM memory_cards WHERE is_plan_content = 0;")
        try execute(sql: "DELETE FROM memory_events WHERE is_plan_content = 0;")
    }

    func clearIndexedContent(forSourceFileID sourceFileID: UUID) throws {
        try execute(sql: "DELETE FROM memory_events WHERE source_file_id = ?;", bind: { statement in
            self.bind(sourceFileID.uuidString, at: 1, in: statement)
        })
    }

    func clearAllIndexedData() throws {
        try execute(sql: "DELETE FROM memory_pattern_occurrences;")
        try execute(sql: "DELETE FROM memory_pattern_stats;")
        try execute(sql: "DELETE FROM rewrite_suggestions;")
        try execute(sql: "DELETE FROM memory_lessons;")
        try execute(sql: "DELETE FROM memory_links;")
        try execute(sql: "DELETE FROM memory_cards;")
        try execute(sql: "DELETE FROM memory_events;")
        try execute(sql: "DELETE FROM memory_files;")
        try execute(sql: "DELETE FROM memory_sources;")
    }

    func backfillAndCleanupMetadata(
        removeMarkedLowValueCards: Bool = false,
        limit: Int = 5000
    ) throws -> MetadataCleanupReport {
        let normalizedLimit = max(1, min(limit, 25_000))
        let now = Date()
        let nowEpoch = now.timeIntervalSince1970
        let markedAt = iso8601Timestamp(now)
        let issuePattern = #"[A-Za-z][A-Za-z0-9]{1,14}-[0-9]{1,8}"#

        struct CleanupRow {
            let cardID: String
            let title: String
            let summary: String
            let detail: String
            let score: Double
            let sourceRootPath: String
            let sourceFileRelativePath: String
            let cardMetadataJSON: String
            let eventMetadataJSON: String
        }

        let sql = """
        SELECT
            c.id,
            c.provider,
            c.title,
            c.summary,
            c.detail,
            c.score,
            s.root_path,
            f.relative_path,
            c.metadata_json,
            e.metadata_json
        FROM memory_cards c
        JOIN memory_sources s ON s.id = c.source_id
        JOIN memory_files f ON f.id = c.source_file_id
        JOIN memory_events e ON e.id = c.event_id
        WHERE c.is_plan_content = 0
        ORDER BY c.updated_at DESC
        LIMIT ?;
        """

        let rows: [CleanupRow] = try query(sql: sql, bind: { statement in
            self.bind(Int64(normalizedLimit), at: 1, in: statement)
        }, mapRow: { statement in
            CleanupRow(
                cardID: self.readString(at: 0, in: statement) ?? "",
                title: self.readString(at: 2, in: statement) ?? "",
                summary: self.readString(at: 3, in: statement) ?? "",
                detail: self.readString(at: 4, in: statement) ?? "",
                score: sqlite3_column_double(statement, 5),
                sourceRootPath: self.readString(at: 6, in: statement) ?? "",
                sourceFileRelativePath: self.readString(at: 7, in: statement) ?? "",
                cardMetadataJSON: self.readString(at: 8, in: statement) ?? "{}",
                eventMetadataJSON: self.readString(at: 9, in: statement) ?? "{}"
            )
        })

        var metadataUpdatedCards = 0
        var lowValueInvalidatedCards = 0
        var removableMarkedCards = 0
        var removedCards = 0

        for row in rows {
            var cardMetadata = normalizedMetadataKeys(decodeStringDictionary(from: row.cardMetadataJSON))
            let originalCardMetadata = cardMetadata
            let eventMetadata = normalizedMetadataKeys(decodeStringDictionary(from: row.eventMetadataJSON))

            var mergedMetadata = eventMetadata
            for (key, value) in cardMetadata {
                mergedMetadata[key] = value
            }

            let isLowValue = isLowValueMemoryCard(
                title: row.title,
                summary: row.summary,
                detail: row.detail,
                score: row.score,
                metadata: mergedMetadata
            )

            let issueKey = normalizedIssueKey(
                from: cardMetadata["issue_key"]
                    ?? eventMetadata["issue_key"]
                    ?? firstIssueKeyMatch(
                        in: [
                            row.title,
                            row.summary,
                            row.detail,
                            row.sourceFileRelativePath,
                            row.sourceRootPath
                        ],
                        pattern: issuePattern
                    )
            )

            var validationState = canonicalValidationState(
                cardMetadata["validation_state"] ?? eventMetadata["validation_state"]
            )
            var outcomeStatus = canonicalOutcomeStatus(
                cardMetadata["outcome_status"] ?? eventMetadata["outcome_status"]
            )

            let protectedHighSignal = isHighSignalMemoryCard(
                title: row.title,
                summary: row.summary,
                detail: row.detail,
                score: row.score,
                issueKey: issueKey,
                outcomeStatus: outcomeStatus,
                validationState: validationState
            )

            if issueKey == nil {
                cardMetadata["issue_key"] = (isLowValue && !protectedHighSignal)
                    ? Self.cleanupNoiseIssueKey
                    : Self.cleanupUnknownIssueKey
            } else if let issueKey {
                cardMetadata["issue_key"] = issueKey
            }

            if validationState == nil {
                if isLowValue && !protectedHighSignal {
                    validationState = MemoryRewriteLessonValidationState.invalidated.rawValue
                } else if outcomeStatus == "fixed" {
                    validationState = MemoryRewriteLessonValidationState.indexedValidated.rawValue
                } else {
                    validationState = MemoryRewriteLessonValidationState.unvalidated.rawValue
                }
            }

            if outcomeStatus == nil {
                switch validationState {
                case MemoryRewriteLessonValidationState.userConfirmed.rawValue,
                    MemoryRewriteLessonValidationState.indexedValidated.rawValue:
                    outcomeStatus = "fixed"
                case MemoryRewriteLessonValidationState.invalidated.rawValue:
                    outcomeStatus = "invalidated"
                default:
                    outcomeStatus = "attempted"
                }
            }

            if let validationState {
                cardMetadata["validation_state"] = validationState
            }
            if let outcomeStatus {
                cardMetadata["outcome_status"] = outcomeStatus
            }

            if isLowValue && !protectedHighSignal {
                if cardMetadata["validation_state"] != MemoryRewriteLessonValidationState.invalidated.rawValue {
                    cardMetadata["validation_state"] = MemoryRewriteLessonValidationState.invalidated.rawValue
                    lowValueInvalidatedCards += 1
                }
                cardMetadata["outcome_status"] = "invalidated"
                if cardMetadata["issue_key"] == Self.cleanupUnknownIssueKey {
                    cardMetadata["issue_key"] = Self.cleanupNoiseIssueKey
                }
                if cardMetadata["cleanup_candidate"] != "removable" {
                    cardMetadata["cleanup_candidate"] = "removable"
                    removableMarkedCards += 1
                }
                if cardMetadata["cleanup_marked_at"] == nil {
                    cardMetadata["cleanup_marked_at"] = markedAt
                }

                if removeMarkedLowValueCards,
                   cardMetadata["validation_state"] == MemoryRewriteLessonValidationState.invalidated.rawValue {
                    try execute(sql: "DELETE FROM memory_cards WHERE id = ?;", bind: { statement in
                        self.bind(row.cardID, at: 1, in: statement)
                    })
                    removedCards += 1
                    continue
                }
            }

            if cardMetadata != originalCardMetadata {
                try execute(sql: """
                UPDATE memory_cards
                SET metadata_json = ?, updated_at = ?
                WHERE id = ?;
                """, bind: { statement in
                    self.bind(self.encodeJSON(cardMetadata, fallback: "{}"), at: 1, in: statement)
                    self.bind(nowEpoch, at: 2, in: statement)
                    self.bind(row.cardID, at: 3, in: statement)
                })
                metadataUpdatedCards += 1
            }
        }

        return MetadataCleanupReport(
            scannedCards: rows.count,
            metadataUpdatedCards: metadataUpdatedCards,
            lowValueInvalidatedCards: lowValueInvalidatedCards,
            removableMarkedCards: removableMarkedCards,
            removedCards: removedCards
        )
    }

    private static func ensureParentDirectory(for databaseURL: URL, fileManager: FileManager) throws {
        let parentDirectory = databaseURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        } catch {
            throw MemorySQLiteStoreError.failedToCreateDirectory(path: parentDirectory.path)
        }
    }

    private func fetchSchemaVersion() throws -> Int? {
        let sql = """
        SELECT schema_version
        FROM memory_schema_meta
        WHERE id = 1
        LIMIT 1;
        """

        let rows: [Int64] = try query(sql: sql, mapRow: { statement in
            sqlite3_column_int64(statement, 0)
        })

        guard let first = rows.first else { return nil }
        return Int(first)
    }

    private func lessonValidationState(from lesson: MemoryLesson) -> MemoryRewriteLessonValidationState {
        let metadata = lesson.sourceMetadata
        if let rawState = metadata["validation_state"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            switch rawState {
            case "invalidated":
                return .invalidated
            case "user-confirmed":
                return .userConfirmed
            case "indexed-validated":
                return .indexedValidated
            case "unvalidated":
                return .unvalidated
            default:
                break
            }
        }

        let origin = metadata["origin"]?.lowercased() ?? ""
        if origin.contains("prompt-rewrite-feedback") || origin.contains("user-feedback") {
            return .userConfirmed
        }
        if lesson.validationConfidence >= 0.80 {
            return .indexedValidated
        }
        return .unvalidated
    }

    private func lessonSelectionScore(for lesson: MemoryLesson) -> Double {
        let state = lessonValidationState(from: lesson)
        let stateBoost: Double
        switch state {
        case .userConfirmed:
            stateBoost = 0.50
        case .indexedValidated:
            stateBoost = 0.28
        case .unvalidated:
            stateBoost = 0.0
        case .invalidated:
            stateBoost = -1.0
        }
        return lesson.validationConfidence + stateBoost
    }

    private func shouldInvalidateExistingLesson(_ existingLesson: MemoryLesson, replacement: MemoryLesson) -> Bool {
        let replacementState = lessonValidationState(from: replacement)
        guard replacementState != .invalidated else { return false }

        let replacementScore = lessonSelectionScore(for: replacement)
        let existingScore = lessonSelectionScore(for: existingLesson)

        switch replacementState {
        case .userConfirmed:
            if replacementScore + 0.02 < existingScore {
                return false
            }
            if replacementScore > existingScore + 0.04 {
                return true
            }
            return replacement.updatedAt >= existingLesson.updatedAt
        case .indexedValidated:
            return replacementScore > existingScore + 0.05
        case .unvalidated:
            return replacementScore > existingScore + 0.08
        case .invalidated:
            return false
        }
    }

    private func isSameScenario(_ lhs: String, _ rhs: String) -> Bool {
        if lhs.caseInsensitiveCompare(rhs) == .orderedSame {
            return true
        }

        let lhsLower = lhs.lowercased()
        let rhsLower = rhs.lowercased()
        let shorterLength = min(lhsLower.count, rhsLower.count)
        if shorterLength >= 20,
           lhsLower.contains(rhsLower) || rhsLower.contains(lhsLower) {
            return true
        }

        let lhsTokens = tokenSet(for: lhsLower)
        let rhsTokens = tokenSet(for: rhsLower)
        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else { return false }

        let shared = lhsTokens.intersection(rhsTokens).count
        guard shared >= 3 else { return false }
        let minCount = min(lhsTokens.count, rhsTokens.count)
        let containment = Double(shared) / Double(max(1, minCount))
        return containment >= 0.68
    }

    private func isEquivalentCorrection(_ lhs: String, _ rhs: String) -> Bool {
        if lhs.caseInsensitiveCompare(rhs) == .orderedSame {
            return true
        }

        let lhsTokens = tokenSet(for: lhs)
        let rhsTokens = tokenSet(for: rhs)
        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else { return false }

        let shared = lhsTokens.intersection(rhsTokens).count
        let minCount = min(lhsTokens.count, rhsTokens.count)
        if minCount <= 3 {
            return shared == minCount
        }

        let containment = Double(shared) / Double(max(1, minCount))
        return shared >= 3 && containment >= 0.84
    }

    private func tokenSet(for value: String, minTokenLength: Int = 3, limit: Int = 24) -> Set<String> {
        let tokens = MemoryTextNormalizer.keywords(from: value, limit: limit)
            .filter { $0.count >= minTokenLength }
            .map { $0.lowercased() }
        return Set(tokens)
    }

    private func iso8601Timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func open() throws {
        var db: OpaquePointer?
        let openFlags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(databaseURL.path, &db, openFlags, nil)
        guard code == SQLITE_OK, let db else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown sqlite error"
            sqlite3_close(db)
            throw MemorySQLiteStoreError.failedToOpenDatabase(path: databaseURL.path, code: code, message: message)
        }
        database = db
    }

    private func close() {
        lock.lock()
        defer { lock.unlock() }

        guard let database else { return }
        sqlite3_close(database)
        self.database = nil
    }

    private func execute(sql: String, bind: ((OpaquePointer) throws -> Void)? = nil) throws {
        try withDatabase { database in
            var statement: OpaquePointer?
            let prepareCode = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
            guard prepareCode == SQLITE_OK, let statement else {
                let message = String(cString: sqlite3_errmsg(database))
                throw MemorySQLiteStoreError.failedToPrepareStatement(sql: sql, code: prepareCode, message: message)
            }
            defer { sqlite3_finalize(statement) }

            try bind?(statement)

            var stepCode = sqlite3_step(statement)
            while stepCode == SQLITE_ROW {
                stepCode = sqlite3_step(statement)
            }

            guard stepCode == SQLITE_DONE else {
                let message = String(cString: sqlite3_errmsg(database))
                throw MemorySQLiteStoreError.failedToExecuteStatement(sql: sql, code: stepCode, message: message)
            }
        }
    }

    private func executeReturningChanges(
        sql: String,
        bind: ((OpaquePointer) throws -> Void)? = nil
    ) throws -> Int {
        try withDatabase { database in
            var statement: OpaquePointer?
            let prepareCode = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
            guard prepareCode == SQLITE_OK, let statement else {
                let message = String(cString: sqlite3_errmsg(database))
                throw MemorySQLiteStoreError.failedToPrepareStatement(sql: sql, code: prepareCode, message: message)
            }
            defer { sqlite3_finalize(statement) }

            try bind?(statement)

            var stepCode = sqlite3_step(statement)
            while stepCode == SQLITE_ROW {
                stepCode = sqlite3_step(statement)
            }

            guard stepCode == SQLITE_DONE else {
                let message = String(cString: sqlite3_errmsg(database))
                throw MemorySQLiteStoreError.failedToExecuteStatement(sql: sql, code: stepCode, message: message)
            }

            return Int(sqlite3_changes(database))
        }
    }

    private func query<T>(
        sql: String,
        bind: ((OpaquePointer) throws -> Void)? = nil,
        mapRow: (OpaquePointer) throws -> T
    ) throws -> [T] {
        try withDatabase { database in
            var statement: OpaquePointer?
            let prepareCode = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
            guard prepareCode == SQLITE_OK, let statement else {
                let message = String(cString: sqlite3_errmsg(database))
                throw MemorySQLiteStoreError.failedToPrepareStatement(sql: sql, code: prepareCode, message: message)
            }
            defer { sqlite3_finalize(statement) }

            try bind?(statement)

            var rows: [T] = []
            while true {
                let stepCode = sqlite3_step(statement)
                if stepCode == SQLITE_DONE {
                    break
                }
                if stepCode != SQLITE_ROW {
                    let message = String(cString: sqlite3_errmsg(database))
                    throw MemorySQLiteStoreError.failedToExecuteStatement(sql: sql, code: stepCode, message: message)
                }
                rows.append(try mapRow(statement))
            }
            return rows
        }
    }

    private func withDatabase<T>(_ block: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }

        guard let database else {
            throw MemorySQLiteStoreError.invalidDatabaseState
        }
        return try block(database)
    }

    private func bind(_ value: String?, at index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, sqliteTransientDestructor)
    }

    private func bind(_ value: Int64, at index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_int64(statement, index, value)
    }

    private func bind(_ value: Int, at index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_int64(statement, index, Int64(value))
    }

    private func bind(_ value: Double, at index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_double(statement, index, value)
    }

    private func readString(at index: Int32, in statement: OpaquePointer) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private func encodeJSON<T: Encodable>(_ value: T, fallback: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8) else {
            return fallback
        }
        return json
    }

    private func decodeStringArray(from json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return values
    }

    private func decodeStringDictionary(from json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return value
    }

    private func memoryCard(from statement: OpaquePointer) -> MemoryCard {
        let id = UUID(uuidString: self.readString(at: 0, in: statement) ?? "") ?? UUID()
        let sourceID = UUID(uuidString: self.readString(at: 1, in: statement) ?? "") ?? UUID()
        let sourceFileID = UUID(uuidString: self.readString(at: 2, in: statement) ?? "") ?? UUID()
        let eventID = UUID(uuidString: self.readString(at: 3, in: statement) ?? "") ?? UUID()
        let provider = MemoryProviderKind(rawValue: self.readString(at: 4, in: statement) ?? "") ?? .unknown
        let title = self.readString(at: 5, in: statement) ?? ""
        let summary = self.readString(at: 6, in: statement) ?? ""
        let detail = self.readString(at: 7, in: statement) ?? ""
        let keywordsJSON = self.readString(at: 8, in: statement) ?? "[]"
        let score = sqlite3_column_double(statement, 9)
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 10))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 11))
        let isPlanContent = sqlite3_column_int(statement, 12) == 1
        let metadataJSON = self.readString(at: 13, in: statement) ?? "{}"

        return MemoryCard(
            id: id,
            sourceID: sourceID,
            sourceFileID: sourceFileID,
            eventID: eventID,
            provider: provider,
            title: title,
            summary: summary,
            detail: detail,
            keywords: self.decodeStringArray(from: keywordsJSON),
            score: score,
            createdAt: createdAt,
            updatedAt: updatedAt,
            isPlanContent: isPlanContent,
            metadata: self.decodeStringDictionary(from: metadataJSON)
        )
    }

    private func scoreLink(from source: MemoryCard, to candidate: MemoryCard) -> (
        linkType: String,
        confidence: Double,
        metadata: [String: String]
    ) {
        let sourceIssue = source.metadata["issue_key"]?.lowercased()
        let candidateIssue = candidate.metadata["issue_key"]?.lowercased()
        let sameIssue = sourceIssue != nil && sourceIssue == candidateIssue

        let sourceKeywords = Set(source.keywords.map { $0.lowercased() })
        let candidateKeywords = Set(candidate.keywords.map { $0.lowercased() })
        let shared = sourceKeywords.intersection(candidateKeywords)
        let keywordUnionCount = max(1, sourceKeywords.union(candidateKeywords).count)
        let keywordJaccard = Double(shared.count) / Double(keywordUnionCount)

        let projectA = contextLabel(from: source.metadata, keys: ["project", "workspace", "repository"])
        let projectB = contextLabel(from: candidate.metadata, keys: ["project", "workspace", "repository"])
        let sameProject = !projectA.isEmpty && !projectB.isEmpty && projectA.caseInsensitiveCompare(projectB) == .orderedSame

        var confidence = 0.0
        var linkType = "similar_topic"
        if sameIssue {
            confidence += 0.55
            linkType = "same_issue"
        }
        confidence += keywordJaccard * 0.35
        if sameProject {
            confidence += 0.1
        }
        confidence += min(candidate.score, source.score) * 0.05

        let validationState = (candidate.metadata["validation_state"] ?? "").lowercased()
        switch validationState {
        case "indexed-validated", "user-confirmed":
            confidence += 0.08
        case "invalidated":
            confidence -= 0.18
        default:
            confidence += 0.02
        }

        if sameIssue,
           let sourceAttempt = parseInt(source.metadata["attempt_number"]),
           let candidateAttempt = parseInt(candidate.metadata["attempt_number"]),
           sourceAttempt > candidateAttempt {
            linkType = "follow_up"
        }

        let bounded = min(1.0, max(0.0, confidence))
        let metadata: [String: String] = [
            "shared_keywords": "\(shared.count)",
            "keyword_jaccard": String(format: "%.3f", keywordJaccard),
            "same_project": sameProject ? "true" : "false",
            "same_issue": sameIssue ? "true" : "false",
            "validation_state": validationState
        ]
        return (linkType, bounded, metadata)
    }

    private func contextLabel(from metadata: [String: String], keys: [String]) -> String {
        for key in keys {
            if let value = metadata[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
        }
        return ""
    }

    private func scopeContext(from metadata: [String: String]) -> MemoryScopeContext {
        let appName = metadata["app_name"] ?? metadata["app"] ?? "Open Assist"
        let bundleID = metadata["bundle_id"] ?? metadata["bundle"] ?? "com.openassist.unknown"
        let surfaceLabel = metadata["surface_label"] ?? metadata["context_label"] ?? "Conversation"
        let projectKey = metadata["canonical_project_key"] ?? metadata["project_key"]
        let projectName = metadata["project_name"] ?? metadata["project"]
        let repositoryName = metadata["repository_name"] ?? metadata["repository"] ?? metadata["repo"]
        let identityKey = metadata["identity_key"] ?? metadata["identity"]
        let identityType = metadata["identity_type"]
        let identityLabel = metadata["identity_label"]
        let codingSignals = [
            bundleID.lowercased().contains("xcode"),
            bundleID.lowercased().contains("cursor"),
            bundleID.lowercased().contains("code"),
            bundleID.lowercased().contains("codex"),
            bundleID.lowercased().contains("jetbrains"),
            bundleID.lowercased().contains("vscode"),
            (projectName ?? "").contains("/"),
            (repositoryName ?? "").contains("/")
        ]
        return MemoryScopeContext(
            appName: appName,
            bundleID: bundleID,
            surfaceLabel: surfaceLabel,
            projectKey: projectKey,
            projectName: projectName,
            repositoryName: repositoryName,
            identityKey: identityKey,
            identityType: identityType,
            identityLabel: identityLabel,
            isCodingContext: codingSignals.contains(true)
        )
    }

    private func ensureLinkSchema() throws {
        try execute(sql: """
        CREATE TABLE IF NOT EXISTS memory_links (
            id TEXT PRIMARY KEY NOT NULL,
            from_card_id TEXT NOT NULL REFERENCES memory_cards(id) ON DELETE CASCADE,
            to_card_id TEXT NOT NULL REFERENCES memory_cards(id) ON DELETE CASCADE,
            link_type TEXT NOT NULL,
            confidence REAL NOT NULL DEFAULT 0,
            metadata_json TEXT NOT NULL DEFAULT '{}',
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            UNIQUE(from_card_id, to_card_id)
        );
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_memory_links_from_confidence
            ON memory_links(from_card_id, confidence DESC, updated_at DESC);
        """)
    }

    private func conversationDisambiguationRule(from statement: OpaquePointer) -> ConversationDisambiguationRuleRecord {
        let ruleType = ConversationDisambiguationRuleType(
            rawValue: self.readString(at: 1, in: statement) ?? ""
        ) ?? .person
        let decision = ConversationDisambiguationDecision(
            rawValue: self.readString(at: 5, in: statement) ?? ""
        ) ?? .separate

        return ConversationDisambiguationRuleRecord(
            id: self.readString(at: 0, in: statement) ?? "",
            ruleType: ruleType,
            appPairKey: self.readString(at: 2, in: statement) ?? "",
            subjectKey: self.readString(at: 3, in: statement) ?? "",
            contextScopeKey: self.readString(at: 4, in: statement),
            decision: decision,
            canonicalKey: self.readString(at: 6, in: statement),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8))
        )
    }

    private func expiredConversationContext(from statement: OpaquePointer) -> ExpiredConversationContextRecord {
        let summaryMethod = ExpiredSummaryMethod(
            rawValue: self.readString(at: 7, in: statement) ?? ""
        ) ?? .fallback
        let summaryConfidence: Double?
        if sqlite3_column_type(statement, 8) == SQLITE_NULL {
            summaryConfidence = nil
        } else {
            summaryConfidence = sqlite3_column_double(statement, 8)
        }
        let consumedAt: Date?
        if sqlite3_column_type(statement, 15) == SQLITE_NULL {
            consumedAt = nil
        } else {
            consumedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 15))
        }

        return ExpiredConversationContextRecord(
            id: self.readString(at: 0, in: statement) ?? "",
            scopeKey: self.readString(at: 1, in: statement) ?? "",
            threadID: self.readString(at: 2, in: statement) ?? "",
            bundleID: self.readString(at: 3, in: statement) ?? "",
            projectKey: self.readString(at: 4, in: statement),
            identityKey: self.readString(at: 5, in: statement),
            summaryText: self.readString(at: 6, in: statement) ?? "",
            summaryMethod: summaryMethod,
            summaryConfidence: summaryConfidence,
            sourceTurnCount: Int(sqlite3_column_int64(statement, 9)),
            recentTurnsJSON: self.readString(at: 10, in: statement) ?? "[]",
            rawTurnsJSON: self.readString(at: 11, in: statement) ?? "[]",
            trigger: self.readString(at: 12, in: statement) ?? "unknown",
            expiredAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 13)),
            deleteAfterAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 14)),
            consumedAt: consumedAt,
            consumedByThreadID: self.readString(at: 16, in: statement),
            metadata: self.decodeStringDictionary(from: self.readString(at: 17, in: statement) ?? "{}")
        )
    }

    private func normalizeLookupKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func normalizeLookupOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = normalizeLookupKey(value)
        return normalized.isEmpty ? nil : normalized
    }

    private func normalizeAppPairKey(_ value: String) -> String {
        let normalized = value
            .split(separator: "|")
            .map { normalizeLookupKey(String($0)) }
            .filter { !$0.isEmpty }

        if normalized.count >= 2 {
            return normalized.sorted().joined(separator: "|")
        }
        return normalizeLookupKey(value)
    }

    private func parseInt(_ value: String?) -> Int? {
        guard let value else { return nil }
        return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func scalarInt(
        sql: String,
        bind: ((OpaquePointer) throws -> Void)? = nil
    ) throws -> Int {
        let values: [Int64] = try query(sql: sql, bind: bind, mapRow: { statement in
            sqlite3_column_int64(statement, 0)
        })
        guard let first = values.first else { return 0 }
        return Int(first)
    }

    private func scalarInt64(
        sql: String,
        bind: ((OpaquePointer) throws -> Void)? = nil
    ) throws -> Int64 {
        let values: [Int64] = try query(sql: sql, bind: bind, mapRow: { statement in
            sqlite3_column_int64(statement, 0)
        })
        return values.first ?? 0
    }

    private func promotionDecisionSummary(
        metadata: [String: String],
        trigger: String
    ) -> String {
        let explicit = [
            metadata["promotion_decision_summary"],
            metadata["promotion_summary"],
            metadata["decision_summary"]
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        if let explicit {
            return explicit
        }

        let decision = metadata["promotion_decision"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !decision.isEmpty {
            let score = metadata["promotion_score"]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let threshold = metadata["promotion_threshold"]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !score.isEmpty, !threshold.isEmpty {
                return "\(decision) (\(score)/\(threshold))"
            }
            return decision
        }

        let normalizedTrigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedTrigger.isEmpty {
            return "trigger=\(normalizedTrigger)"
        }
        return "No promotion decision yet."
    }

    private func patternOutcome(from raw: String) -> MemoryPatternOutcome {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case MemoryPatternOutcome.good.rawValue:
            return .good
        case MemoryPatternOutcome.bad.rawValue:
            return .bad
        default:
            return .neutral
        }
    }

    private func inferProjectContext(
        provider: MemoryProviderKind,
        cardMetadataJSON: String,
        eventMetadataJSON: String,
        sourceRootPath: String,
        sourceFileRelativePath: String,
        title: String,
        summary: String,
        detail: String
    ) -> (projectName: String?, repositoryName: String?) {
        let cardMetadata = normalizedMetadataKeys(decodeStringDictionary(from: cardMetadataJSON))
        let eventMetadata = normalizedMetadataKeys(decodeStringDictionary(from: eventMetadataJSON))

        let repositoryKeys = [
            "repository", "repository_name", "repo", "repo_name",
            "git_repository", "git_repo", "repositorypath"
        ]
        let baseProjectKeys = [
            "project", "project_name", "workspace", "workspace_name",
            "folder", "cwd", "working_directory", "workdir", "path", "uri"
        ]
        let projectKeys = providerSpecificProjectKeys(for: provider) + baseProjectKeys

        let repositoryValue = firstContextValue(
            keys: repositoryKeys,
            primary: cardMetadata,
            secondary: eventMetadata
        )
        let projectValue = firstContextValue(
            keys: projectKeys,
            primary: cardMetadata,
            secondary: eventMetadata
        )

        var repositoryName = normalizeContextLabel(repositoryValue)
        var projectName = normalizeContextLabel(projectValue)

        let textPathCandidate = extractPathLikeValue(
            from: [detail, summary, title]
        )

        if repositoryName == nil {
            repositoryName = derivePathLabel(from: textPathCandidate ?? sourceFileRelativePath)
        }
        if projectName == nil {
            projectName = derivePathLabel(from: textPathCandidate ?? sourceFileRelativePath)
                ?? derivePathLabel(from: sourceRootPath)
        }

        if projectName == nil {
            projectName = repositoryName
        }

        if let projectName,
           let repositoryName,
           projectName.caseInsensitiveCompare(repositoryName) == .orderedSame {
            return (projectName, nil)
        }

        return (projectName, repositoryName)
    }

    private func providerSpecificProjectKeys(for provider: MemoryProviderKind) -> [String] {
        switch provider {
        case .codex:
            return ["cwd"]
        case .opencode:
            return ["workspace", "cwd", "path"]
        case .claude:
            return ["project", "cwd"]
        case .cursor, .windsurf:
            return ["folder", "workspace", "path", "uri"]
        case .copilot:
            return ["workspace", "folder", "path"]
        case .kimi, .gemini, .codeium:
            return ["path", "cwd", "workspace", "project", "folder"]
        case .unknown:
            return []
        }
    }

    private func normalizedMetadataKeys(_ metadata: [String: String]) -> [String: String] {
        var normalized: [String: String] = [:]
        normalized.reserveCapacity(metadata.count)
        for (key, value) in metadata {
            normalized[key.lowercased()] = value
        }
        return normalized
    }

    private func firstContextValue(
        keys: [String],
        primary: [String: String],
        secondary: [String: String]
    ) -> String? {
        for key in keys {
            let normalizedKey = key.lowercased()
            if let value = primary[normalizedKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
            if let value = secondary[normalizedKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func normalizeContextLabel(_ rawValue: String?) -> String? {
        guard var value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        value = value.replacingOccurrences(of: "\\", with: "/")
        if value.hasPrefix("file://"),
           let url = URL(string: value) {
            value = url.path
        }
        if let decoded = value.removingPercentEncoding,
           !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            value = decoded
        }

        if value.contains("/") {
            return derivePathLabel(from: value)
        }

        let collapsed = MemoryTextNormalizer.collapsedWhitespace(value)
        guard !collapsed.isEmpty else { return nil }
        let lowered = collapsed.lowercased()
        let genericValues: Set<String> = [
            "workspace", "project", "repository", "repo", "unknown", "state", "storage", "clipboard"
        ]
        guard !genericValues.contains(lowered) else { return nil }
        guard !looksLikeOpaqueIdentifier(collapsed) else { return nil }
        guard !isNumericOrDatePathComponent(collapsed) else { return nil }
        return collapsed
    }

    private func extractPathLikeValue(from texts: [String]) -> String? {
        let patterns = [
            #"file://[^\s"'<>\]\[)\(,;]+"#,
            #"/(?:Users|Volumes|private)/[^\s"'<>\]\[)\(,;]{3,}"#,
            #"[A-Za-z]:\\[^\s"'<>\]\[)\(,;]{3,}"#
        ]

        for text in texts {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }

            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                    continue
                }
                let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
                guard let match = regex.firstMatch(in: normalized, options: [], range: range),
                      let tokenRange = Range(match.range(at: 0), in: normalized) else {
                    continue
                }
                let token = String(normalized[tokenRange])
                let cleaned = cleanedExtractedPathToken(token)
                if !cleaned.isEmpty {
                    return cleaned
                }
            }
        }

        return nil
    }

    private func cleanedExtractedPathToken(_ rawToken: String) -> String {
        var token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimCharacters = CharacterSet(charactersIn: "\"'`()[]{}<>,;")
        token = token.trimmingCharacters(in: trimCharacters)
        token = token.replacingOccurrences(of: "\\", with: "/")
        if let decoded = token.removingPercentEncoding,
           !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            token = decoded
        }
        return token
    }

    private func derivePathLabel(from rawPath: String) -> String? {
        let normalized = rawPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty else { return nil }

        let rawComponents = normalized
            .split(separator: "/")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !rawComponents.isEmpty else { return nil }

        for component in rawComponents.reversed() {
            var candidate = component.removingPercentEncoding ?? component
            candidate = stripTrackerHashSuffix(from: candidate)
            let lowered = candidate.lowercased()
            if isLikelyFilenameComponent(candidate) {
                continue
            }
            guard !isGenericPathComponent(lowered) else { continue }
            guard !looksLikeOpaqueIdentifier(candidate) else { continue }
            guard !isNumericOrDatePathComponent(candidate) else { continue }
            if candidate.count > 96 { continue }
            return candidate
        }

        return nil
    }

    private func isGenericPathComponent(_ value: String) -> Bool {
        let genericComponents: Set<String> = [
            "users", "user", "library", "application support", "workspace", "workspacestorage",
            "globalstorage", "storage", "state", "session", "sessions", "chat", "history",
            "archives", "archived_sessions", "projects", "repos", "repositories", "repo",
            "memory", "index", "unknown", "tmp", "temp", "active", "default", "clipboard",
            "worktree", "worktrees",
            ".codex", ".claude", ".opencode",
            "codex", "claude", "opencode", "cursor", "copilot", "windsurf", "codeium", "gemini", "kimi"
        ]
        return genericComponents.contains(value)
    }

    private func looksLikeOpaqueIdentifier(_ value: String) -> Bool {
        let normalized = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 12 else { return false }

        if normalized.range(of: "^[0-9a-f]{12,}$", options: .regularExpression) != nil {
            return true
        }
        if normalized.range(of: "^[0-9a-f-]{20,}$", options: .regularExpression) != nil {
            return true
        }
        if normalized.range(of: "^[0-9a-z_-]{24,}$", options: .regularExpression) != nil,
           normalized.rangeOfCharacter(from: CharacterSet.letters) == nil {
            return true
        }
        return false
    }

    private func isNumericOrDatePathComponent(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        if normalized.range(of: "^[0-9]+$", options: .regularExpression) != nil {
            return true
        }
        let datePatterns = [
            #"^[0-9]{4}[-_.][0-9]{1,2}([\-_.][0-9]{1,2})?$"#,
            #"^[0-9]{8}$"#,
            #"^[0-9]{6}$"#,
            #"^[0-9]{1,2}[-_.][0-9]{1,2}([\-_.][0-9]{2,4})?$"#
        ]
        return datePatterns.contains {
            normalized.range(of: $0, options: .regularExpression) != nil
        }
    }

    private func stripTrackerHashSuffix(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.lowercased() == "no_repo" {
            return ""
        }

        let parts = trimmed.split(separator: "_")
        guard parts.count >= 2, let last = parts.last else {
            return trimmed
        }

        let lastPart = String(last)
        if lastPart.range(of: "^[0-9a-f]{8,}$", options: .regularExpression) != nil {
            return parts.dropLast().map(String.init).joined(separator: "_")
        }
        return trimmed
    }

    private func isLikelyFilenameComponent(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix(".") {
            return false
        }
        return trimmed.range(of: "\\.[A-Za-z]{1,8}$", options: .regularExpression) != nil
    }

    private func escapedLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private func canonicalValidationState(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !rawValue.isEmpty else { return nil }

        if rawValue == MemoryRewriteLessonValidationState.invalidated.rawValue || rawValue.contains("invalid") {
            return MemoryRewriteLessonValidationState.invalidated.rawValue
        }
        if rawValue == MemoryRewriteLessonValidationState.userConfirmed.rawValue || rawValue.contains("user") {
            return MemoryRewriteLessonValidationState.userConfirmed.rawValue
        }
        if rawValue == MemoryRewriteLessonValidationState.indexedValidated.rawValue || rawValue.contains("validated") {
            return MemoryRewriteLessonValidationState.indexedValidated.rawValue
        }
        if rawValue == MemoryRewriteLessonValidationState.unvalidated.rawValue || rawValue.contains("pending") {
            return MemoryRewriteLessonValidationState.unvalidated.rawValue
        }
        return nil
    }

    private func canonicalOutcomeStatus(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !rawValue.isEmpty else { return nil }

        switch rawValue {
        case "fixed", "resolved", "success", "successful", "pass", "passed":
            return "fixed"
        case "invalidated", "invalid", "noise", "ignored", "discarded":
            return "invalidated"
        case "failed", "failure", "regressed", "error", "broken":
            return "failed"
        case "attempted", "responded", "in_progress", "in-progress", "started", "open":
            return "attempted"
        default:
            return nil
        }
    }

    private func normalizedIssueKey(from rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else { return nil }
        let upper = rawValue.uppercased()
        if upper.range(of: "^[A-Z][A-Z0-9]{1,14}-[0-9]{1,8}$", options: .regularExpression) != nil {
            return upper
        }
        return nil
    }

    private func firstIssueKeyMatch(in texts: [String], pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        for text in texts {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: range),
                  let matchedRange = Range(match.range, in: text) else {
                continue
            }
            return String(text[matchedRange]).uppercased()
        }
        return nil
    }

    private func isLowValueMemoryCard(
        title: String,
        summary: String,
        detail: String,
        score: Double,
        metadata: [String: String]
    ) -> Bool {
        let lowerTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lowerSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lowerDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let combined = "\(lowerTitle) \(lowerSummary) \(lowerDetail)"

        let rewriteIndicators = ["->", "=>", "→", "rewrite", "suggested", "correction"]
        if rewriteIndicators.contains(where: { combined.contains($0) }) {
            return false
        }

        let genericTitles: Set<String> = [
            "chat", "message", "conversation", "session", "history", "note", "section", "event",
            "workspace", "storage", "state"
        ]
        if genericTitles.contains(lowerTitle) || genericTitles.contains(lowerSummary) {
            return true
        }
        if lowerTitle == "q&a: hi" || lowerTitle == "q&a: hello" || lowerTitle == "q&a: hey" {
            return true
        }
        let outcomeStatus = (metadata["outcome_status"] ?? "").lowercased()
        let validationState = (metadata["validation_state"] ?? "").lowercased()
        if (outcomeStatus == "responded" || outcomeStatus == "attempted" || outcomeStatus.isEmpty),
           (validationState == "unvalidated" || validationState.isEmpty),
           (lowerSummary.hasPrefix("q: hi")
                || lowerSummary.hasPrefix("q: hello")
                || lowerSummary.hasPrefix("q: hey")
                || lowerDetail.contains("how can i help")
                || lowerDetail.contains("how can i assist")) {
            return true
        }

        let alphaWords = combined.split(whereSeparator: \.isWhitespace).filter { token in
            token.contains(where: \.isLetter)
        }
        if alphaWords.count < 5 {
            return true
        }

        return score < 0.35
    }

    private func isHighSignalMemoryCard(
        title: String,
        summary: String,
        detail: String,
        score: Double,
        issueKey: String?,
        outcomeStatus: String?,
        validationState: String?
    ) -> Bool {
        let lowerTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lowerSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lowerDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let combined = "\(lowerTitle) \(lowerSummary) \(lowerDetail)"

        if let validationState,
           validationState == MemoryRewriteLessonValidationState.userConfirmed.rawValue
            || validationState == MemoryRewriteLessonValidationState.indexedValidated.rawValue {
            return true
        }
        if let outcomeStatus, outcomeStatus == "fixed" {
            return true
        }
        if let issueKey,
           issueKey != Self.cleanupUnknownIssueKey,
           issueKey != Self.cleanupNoiseIssueKey {
            return true
        }
        if combined.contains("->") || combined.contains("rewrite") || combined.contains("correction") {
            return score >= 0.50
        }
        return score >= 0.85
    }
}
