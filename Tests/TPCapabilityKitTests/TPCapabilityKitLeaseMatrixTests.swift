import Testing
import Foundation
@testable import TPCapabilityKit

private struct MatrixError: Error {}

private enum Prim: Sendable, Hashable {
    case activate
    case complete
    case fail
    case expire
    case beginRetry

    func apply(to lease: Lease) {
        switch self {
        case .activate: lease.activate()
        case .complete: lease.complete(with: "ok")
        case .fail: lease.fail(with: MatrixError())
        case .expire: lease.expire()
        case .beginRetry: lease.beginRetry()
        }
    }
}

private func leaseIn(_ state: Lease.State) -> Lease {
    let lease = Lease(task: TaskDescriptor(requiredCapabilities: [.heavyTask], maxRetries: 2))
    switch state {
    case .pending:
        break
    case .active:
        lease.activate()
    case .completed:
        lease.activate()
        lease.complete(with: "ok")
    case .failed:
        lease.activate()
        lease.fail(with: MatrixError())
    case .expired:
        lease.expire()
    }
    return lease
}

@Suite("Lease Matrix Tests")
struct LeaseMatrixTests {
    @Test("transition matrix pins accepted vs rejected from state comparison")
    func transitionMatrix() {
        let acceptedEnd: [Prim: Lease.State] = [
            .activate: .active,
            .complete: .completed,
            .fail: .failed(MatrixError()),
            .expire: .expired,
            .beginRetry: .pending,
        ]
        let acceptedFrom: [Int: Set<Prim>] = [
            Lease.State.pending.rawValue: [.activate, .expire, .beginRetry],
            Lease.State.active.rawValue: [.complete, .fail, .expire, .beginRetry],
            Lease.State.completed.rawValue: [.beginRetry],
            Lease.State.failed(MatrixError()).rawValue: [.beginRetry],
            Lease.State.expired.rawValue: [.beginRetry],
        ]
        let starts: [Lease.State] = [.pending, .active, .completed, .failed(MatrixError()), .expired]
        let prims: [Prim] = [.activate, .complete, .fail, .expire, .beginRetry]

        for start in starts {
            for prim in prims {
                let lease = leaseIn(start)
                let retriesBefore = lease.retryCount
                prim.apply(to: lease)

                let accepted = acceptedFrom[start.rawValue, default: []].contains(prim)
                if prim == .beginRetry {
                    #expect(
                        (lease.retryCount == retriesBefore + 1) == accepted,
                        "start \(start.rawValue), prim \(prim)"
                    )
                } else {
                    #expect(
                        (lease.state != start) == accepted,
                        "start \(start.rawValue), prim \(prim)"
                    )
                }
                if accepted {
                    #expect(lease.state == acceptedEnd[prim]!, "start \(start.rawValue), prim \(prim)")
                } else {
                    #expect(lease.state == start, "start \(start.rawValue), prim \(prim)")
                }
            }
        }
    }

    @Test("beginRetry consumes budget and clears attempt state")
    func beginRetryBudgetAndClearing() {
        let lease = Lease(task: TaskDescriptor(requiredCapabilities: [.heavyTask], maxRetries: 1))
        #expect(lease.canRetry)

        lease.activate()
        lease.beginRetry()
        #expect(lease.state == .pending)
        #expect(lease.retryCount == 1)
        #expect(!lease.canRetry)
        #expect(lease.activatedAt == nil)
        #expect(lease.completedAt == nil)
        #expect(lease.result == nil)
    }
}
