import Foundation

// MARK: - FavoritesEngine
//
// Pure, side-effect-free favorites logic, extracted from AppViewModel so it can
// be unit-tested in isolation and reused. Favorites are stored as
// "providerId:stopId" keys (e.g. "mdb-2126:51425").
//
// Persistence (UserDefaults + iCloud KVS) stays in AppViewModel; this type only
// transforms sets of keys.

enum FavoritesEngine {

    /// Upgrade any bare-ID entries (legacy single-provider format) to the
    /// namespaced "providerId:stopId" form. Unknown legacy IDs are attributed
    /// to STM since it was the only provider before multi-provider support.
    static func migrateLegacyKeys(_ keys: Set<String>) -> Set<String> {
        Set(keys.map { $0.contains(":") ? $0 : "stm:\($0)" })
    }

    /// Toggle a favorite key in a set, returning the new set.
    static func toggling(_ key: String, in keys: Set<String>) -> Set<String> {
        var out = keys
        if out.contains(key) { out.remove(key) } else { out.insert(key) }
        return out
    }

    /// Merge the local set with a remote (iCloud) set: union, then migrate.
    /// Union (not replace) so adding on another device never erases favorites
    /// added locally while offline.
    static func merge(local: Set<String>, remote: [String]) -> Set<String> {
        migrateLegacyKeys(local.union(remote))
    }

    /// Combine both persistence sources at load time and migrate to canonical form.
    static func loaded(remote: [String]?, local: [String]) -> Set<String> {
        migrateLegacyKeys(Set(remote ?? []).union(local))
    }
}
