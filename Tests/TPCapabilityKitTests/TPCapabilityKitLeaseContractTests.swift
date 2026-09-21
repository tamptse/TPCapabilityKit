import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Lease Transition Contract")
struct LeaseTransitionContractTests {
    private func makeLease(maxRetries: Int = 0) -> Lease {
        Lease(task: TaskDescriptor(requiredCapabilities: [.heavyTask], maxRetries: maxRetries))
    }

    private struct ContractError: Error {}

    @Test("pending activates then completes")
    func pendingActiveCompleted() {
        let lease = makeLease()
        #expect(lease.state == .pending)
        lease.activate()
        #expect(lease.state == .active)
        lease.complete(with: "ok")
        #expect(lease.state == .completed)
        #expect(lease.isTerminal)
    }

    @Test("pending activates then fails")
    func pendingActiveFailed() {
        let lease = makeLease()
        lease.activate()
        lease.fail(with: ContractError())
        #expect(lease.state == .failed(ContractError()))
        #expect(lease.isTerminal)
    }

    @Test("pending activates then expires")
    func pendingActiveExpired() {
        let lease = makeLease()
        lease.activate()
        lease.expire()
        #expect(lease.state == .expired)
        #expect(lease.isTerminal)
    }

    @Test("expire accepts pending")
    func expireFromPending() {
        let lease = makeLease()
        #expect(lease.state == .pending)
        lease.expire()
        #expect(lease.state == .expired)
        #expect(lease.isTerminal)
    }

    @Test("expire accepts active")
    func expireFromActive() {
        let lease = makeLease()
        lease.activate()
        lease.expire()
        #expect(lease.state == .expired)
    }

    @Test("complete from pending is a no-op")
    func completeFromPendingNoOp() {
        let lease = makeLease()
        lease.complete(with: "ok")
        #expect(lease.state == .pending)
        #expect(!lease.isTerminal)
        #expect(lease.result == nil)
        #expect(lease.completedAt == nil)
    }

    @Test("fail from pending is a no-op")
    func failFromPendingNoOp() {
        let lease = makeLease()
        lease.fail(with: ContractError())
        #expect(lease.state == .pending)
        #expect(!lease.isTerminal)
        #expect(lease.completedAt == nil)
    }

    @Test("double activate is a no-op")
    func doubleActivateNoOp() {
        let lease = makeLease()
        lease.activate()
        let firstActivation = lease.activatedAt
        #expect(firstActivation != nil)
        lease.activate()
        #expect(lease.state == .active)
        #expect(!lease.isTerminal)
        #expect(lease.activatedAt == firstActivation)
    }

    @Test("completed state is frozen")
    func completedFrozen() {
        let lease = makeLease()
        lease.activate()
        lease.complete(with: "kept")
        #expect(lease.isTerminal)

        lease.activate()
        lease.complete(with: "overwrite")
        lease.fail(with: ContractError())
        lease.expire()

        #expect(lease.state == .completed)
        #expect((lease.result as? String) == "kept")
    }

    @Test("failed state is frozen")
    func failedFrozen() {
        let lease = makeLease()
        lease.activate()
        lease.fail(with: ContractError())
        #expect(lease.isTerminal)

        lease.activate()
        lease.complete(with: "ok")
        lease.fail(with: ContractError())
        lease.expire()

        #expect(lease.state == .failed(ContractError()))
        #expect(lease.result == nil)
    }

    @Test("expired state is frozen")
    func expiredFrozen() {
        let lease = makeLease()
        lease.expire()
        #expect(lease.isTerminal)

        lease.activate()
        lease.complete(with: "ok")
        lease.fail(with: ContractError())
        lease.expire()

        #expect(lease.state == .expired)
    }

    @Test("beginRetry returns to pending with incremented count and cleared result")
    func beginRetryResets() {
        let lease = makeLease(maxRetries: 2)
        lease.activate()
        lease.complete(with: "stale")
        #expect(lease.state == .completed)

        lease.beginRetry()
        #expect(lease.state == .pending)
        #expect(!lease.isTerminal)
        #expect(lease.retryCount == 1)
        #expect(lease.result == nil)
        #expect(lease.activatedAt == nil)
        #expect(lease.completedAt == nil)
        #expect(lease.canRetry)
    }

    @Test("beginRetry from active clears attempt markers")
    func beginRetryFromActive() {
        let lease = makeLease(maxRetries: 1)
        lease.activate()
        #expect(lease.activatedAt != nil)
        lease.beginRetry()
        #expect(lease.state == .pending)
        #expect(lease.retryCount == 1)
        #expect(lease.activatedAt == nil)
        #expect(lease.completedAt == nil)
        #expect(!lease.canRetry)
    }

    @Test("canRetry reflects remaining budget")
    func canRetryBudget() {
        let exhausted = makeLease(maxRetries: 0)
        #expect(!exhausted.canRetry)

        let lease = makeLease(maxRetries: 2)
        #expect(lease.canRetry)
        lease.activate()
        lease.beginRetry()
        #expect(lease.canRetry)
        lease.activate()
        lease.beginRetry()
        #expect(!lease.canRetry)
    }
}
