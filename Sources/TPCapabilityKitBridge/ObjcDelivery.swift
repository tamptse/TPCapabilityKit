import Foundation

/// Single given-or-main delivery point behind the Bridge.
enum ObjcDelivery {
    static func on(_ queue: DispatchQueue?, execute work: @escaping @Sendable () -> Void) {
        (queue ?? .main).async(execute: work)
    }
}
