import Testing
import Foundation
@testable import TPCapabilityKit

/// Pins live/virtual adapter parity behind the one sleep seam: neither
/// adapter parks a non-positive sleep, and advancing wakes only the waiters
/// whose deadlines expired — never losing or duplicating a wakeup — while the
/// advance/wait rendezvous stays the synchronization point.
@Suite("Time Adapter Tests")
struct TimeAdapterTests {
    @Test("non-positive sleep never parks on either adapter")
    func nonPositiveSleepNeverParks() async {
        let virtual = Clock()
        virtual.enableDeterministic()
        await virtual.sleep(0)
        await virtual.sleep(-1)
        #expect(virtual.waiterCount == 0)

        let live = Clock.live
        await live.sleep(0)
        #expect(live.waiterCount == 0)
    }

    @Test("advance wakes only expired waiters without loss or duplication")
    func advanceWakesOnlyExpired() async {
        let clock = Clock()
        clock.enableDeterministic()
        actor Flags {
            var first = false
            var second = false
            func markFirst() { first = true }
            func markSecond() { second = true }
        }
        let flags = Flags()

        async let first: Void = {
            await clock.sleep(5.0)
            await flags.markFirst()
        }()
        async let second: Void = {
            await clock.sleep(10.0)
            await flags.markSecond()
        }()
        await clock.waitForWaiters(count: 2)

        await clock.advance(by: 5.0)
        await first
        #expect(await flags.first == true)
        #expect(await flags.second == false)
        #expect(clock.waiterCount == 1)

        await clock.advance(by: 5.0)
        await second
        #expect(await flags.first == true)
        #expect(await flags.second == true)
        #expect(clock.waiterCount == 0)
    }
}
