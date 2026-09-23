// Every entity that can hit Supabase needs a real UUID — the Postgres
// uuid columns reject anything else. Web equivalent: lib/uuid.ts (which
// wraps crypto.randomUUID). On Apple platforms Foundation's UUID is
// always available, so there's no fallback path to port.

import CryptoKit
import Foundation

/// Lowercased RFC-4122 v4 UUID string, matching the format the web mints.
public func newUUID() -> String {
    UUID().uuidString.lowercased()
}

/// True if `s` is a syntactically valid UUID. Mirrors the UUID-format
/// gate in lib/sync/bridge.ts that stops malformed ids reaching Postgres.
public func isUUID(_ s: String) -> Bool {
    UUID(uuidString: s) != nil
}

/// UUIDv5(NAMESPACE_URL, "https://unstucknow.io/ns/cal-block-occurrence") — fixed for ever.
public let OCCURRENCE_ID_NAMESPACE = "acd13342-1379-568a-9f73-6acb660047d5"

/// A repeating task's occurrence id for one civil date: the same on every
/// device, so two devices minting the same day land on one row (audit
/// 2026-09-22, C21 — owner decision "same id for same day", 2026-09-23).
///
/// RFC 4122 §4.3 UUIDv5 of "<task id, trimmed + lowercased>|<YYYY-MM-DD>"
/// under OCCURRENCE_ID_NAMESPACE. Web `lib/occurrence-id.ts` and Android
/// `core/logic/Uuid.kt` compute the same string; the shared vectors live in
/// audit/parity-2026-09-23/deterministic-occurrence-ids.md §1.5. The trim is
/// `.whitespacesAndNewlines` on purpose: `.whitespaces` keeps a trailing
/// newline, and the platforms would then disagree.
public func occurrenceId(taskId: String, date: String) -> String {
    let ns = UUID(uuidString: OCCURRENCE_ID_NAMESPACE)!.uuid
    var bytes = withUnsafeBytes(of: ns) { Array($0) }
    bytes += Array("\(taskId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(date)".utf8)
    var h = Array(Insecure.SHA1.hash(data: bytes).prefix(16))
    h[6] = (h[6] & 0x0F) | 0x50
    h[8] = (h[8] & 0x3F) | 0x80
    return UUID(uuid: h.withUnsafeBytes { $0.load(as: uuid_t.self) }).uuidString.lowercased()
}
