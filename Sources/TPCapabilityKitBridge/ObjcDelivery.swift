import Foundation

/// Single given-or-main delivery point behind the Bridge.
///
/// Contract (stated once for the whole Bridge): every Bridge completion arrives
/// on the given queue when supplied, or the main queue when omitted.
enum ObjcDelivery {
    static func on(_ queue: DispatchQueue?, execute work: @escaping @Sendable () -> Void) {
        (queue ?? .main).async(execute: work)
    }
}
