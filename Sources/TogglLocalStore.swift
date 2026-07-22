// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import SQLite3

/// Tracking state derived from Toggl's local store. `unavailable` is distinct
/// from `notTracking` so a missing/unreadable DB never triggers a false nag.
internal enum TrackingState: Equatable {
    case tracking(description: String?)
    case notTracking
    case unavailable
}

/// Reads the Toggl Track (com.toggl.daneel) shared Core Data store — the same
/// SQLite file its own menu-bar widget reads. No API, no token, no network.
///
/// The store is private/undocumented, so this is intentionally defensive: any
/// surprise (missing file, schema change, locked DB) degrades to `.unavailable`
/// rather than guessing. If a Toggl update moves the furniture, fix the path or
/// the query here.
internal final class TogglLocalStore {
    /// Transient-contention retry policy. Small on purpose: a read that needs
    /// more than this isn't a blip, and the watcher re-reads on the next event.
    private static let maxAttempts = 3
    private static let retryBackoff: TimeInterval = 0.05
    /// Milliseconds SQLite waits on a locked page before returning BUSY.
    private static let busyTimeoutMilliseconds: Int32 = 200

    /// `B227VTMZ94` is Toggl's team prefix; the group id is stable per install.
    private let dbPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/B227VTMZ94.group.com.toggl.daneel.extensions")
        .appendingPathComponent("production/DatabaseModel.sqlite")
        .path

    deinit {
        // Deliberately empty: this type owns no resource beyond the SQLite handle,
        // which is opened and closed within a single `query()` call via `defer`.
    }

    internal func currentState() -> TrackingState {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return .unavailable
        }

        // Query the live DB in place, READ-ONLY — never copy. In WAL mode readers
        // don't block (or get blocked by) Toggl's writer, and SQLite only touches
        // the handful of pages the query needs.
        //
        // Contention (a momentary lock during a WAL checkpoint, say) can surface
        // at open, prepare, or step, so retry a couple of times before declaring
        // `.unavailable` — that avoids a false "can't read Toggl" warning on a
        // blip, and the watcher/fallback re-reads on the next event regardless.
        //
        // Never copy the store to read it — read-only in place is the only path.
        for attempt in 0 ..< Self.maxAttempts {
            if let state = query() {
                return state
            }
            if attempt < Self.maxAttempts - 1 {
                Thread.sleep(forTimeInterval: Self.retryBackoff)
            } // brief backoff on a transient lock
        }
        return .unavailable
    }

    /// Returns nil for a *transient* failure — contention at open, prepare, or
    /// step — so `currentState()` retries. Persistent failures, chiefly an
    /// unexpected schema, return `.unavailable`: retrying wouldn't help, and the
    /// distinction is what keeps a momentary lock from being reported to the user
    /// as "Toggl may have updated".
    private func query() -> TrackingState? {
        var db: OpaquePointer?
        let opened = sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil)
        guard opened == SQLITE_OK else {
            sqlite3_close(db)
            // Classify here for the same reason prepare and step do: a permissions
            // or I/O failure is persistent, and retrying it just burns three opens
            // and two sleeps before reaching the same answer.
            return Self.isTransient(opened) ? nil : .unavailable
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, Self.busyTimeoutMilliseconds)

        // A running entry is the single non-deleted row with NULL duration
        // (this client doesn't use the API's negative-duration sentinel).
        let sql = """
        SELECT ZDESCRIPTION_CURRENT FROM ZMANAGEDTIMEENTRY
        WHERE ZDURATION_CURRENT IS NULL
          AND (ZDELETED_CURRENT IS NULL OR ZDELETED_CURRENT = 0)
        ORDER BY ZSTART_CURRENT DESC LIMIT 1;
        """
        var stmt: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepared == SQLITE_OK else {
            // BUSY/LOCKED here is contention, not a schema change — hand it back
            // for retry instead of declaring the store unreadable.
            return Self.isTransient(prepared) ? nil : .unavailable // else: don't guess
        }
        defer { sqlite3_finalize(stmt) }

        let stepped = sqlite3_step(stmt)
        switch stepped {
        case SQLITE_ROW:
            var description: String?
            if let cString = sqlite3_column_text(stmt, 0) {
                let text = String(cString: cString).trimmingCharacters(in: .whitespacesAndNewlines)
                description = text.isEmpty ? nil : text
            }
            return .tracking(description: description)

        case SQLITE_DONE:
            return .notTracking

        default:
            return Self.isTransient(stepped) ? nil : .unavailable
        }
    }

    /// Contention the caller should retry, as opposed to a persistent fault.
    /// `sqlite3_busy_timeout` absorbs most of this, but it doesn't cover every
    /// BUSY path (WAL index recovery among them), so classify explicitly rather
    /// than assuming a non-OK code means the schema moved.
    private static func isTransient(_ code: Int32) -> Bool {
        code == SQLITE_BUSY || code == SQLITE_LOCKED
    }
}
