import Foundation

/// Single empty-id rule shared by the Store facade (capability paths) and
/// StoreState (state paths), so no-op semantics cannot diverge by copy-paste.
func validatePluginId(_ pluginId: String) -> Bool {
    guard !pluginId.isEmpty else {
        #if DEBUG
        print("[DynamicStore] Error: Plugin ID cannot be empty")
        #endif
        return false
    }
    return true
}
