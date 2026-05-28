// Every entity that can hit Supabase needs a real UUID — the Postgres
// uuid columns reject anything else. Web equivalent: lib/uuid.ts (which
// wraps crypto.randomUUID). On Apple platforms Foundation's UUID is
// always available, so there's no fallback path to port.

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
