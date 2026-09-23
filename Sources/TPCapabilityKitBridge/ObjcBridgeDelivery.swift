import Combine
@preconcurrency import Foundation

/// One delivery path behind the Bridge.
///
/// The module owns the given-or-main queue hop for state subscribe,
/// capability subscribe, and value-returning waits. Callers cross this seam
/// instead of resolving the queue themselves, so threading behaves
/// identically everywhere and policy changes stay local to this module.
/// The scheduling adapter stays single behind the `taskScheduler` view;
/// this module only delivers values, it never schedules.
enum ObjcBridgeDelivery {
    private static func queue(from queue: DispatchQueue?) -> DispatchQueue {
        queue ?? .main
    }

    static func deliver(on queue: DispatchQueue?, _ work: @escaping @Sendable () -> Void) {
        self.queue(from: queue).async(execute: work)
    }

    static func received<P: Publisher>(_ publisher: P, on queue: DispatchQueue?) -> AnyPublisher<P.Output, P.Failure> {
        publisher.receive(on: self.queue(from: queue)).eraseToAnyPublisher()
    }
}
