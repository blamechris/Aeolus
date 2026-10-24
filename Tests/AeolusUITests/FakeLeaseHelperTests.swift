import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusUI

/// The fake helper's own fidelity, where the driver's suite leans on it: `disconnect()` publishes
/// `.idle` as `HelperClient.disconnect()` does, and answers every call still waiting, delayed ones
/// included.
@Suite("Fake helper: disconnect", .timeLimit(.minutes(1)))
struct FakeLeaseHelperTests {

    static let request = LeaseRequest(holderDescription: LeaseScene.holder, fanIndices: [0])

    /// A disconnect after a call publishes `.idle`, once: a second disconnect, with no connection
    /// left, publishes nothing, and neither does a disconnect before any call.
    ///
    /// **Mutation:** in `FakeLeaseHelper.disconnect`, delete `health.push(.idle)`. Red on the
    /// first `.idle`. **Mutation:** push `.idle` whether or not there was a connection. Red on the
    /// value after the second disconnect.
    @Test("disconnect publishes idle once, and only with a connection")
    func disconnectPublishesIdle() async throws {
        let scene = await LeaseScene()
        var health = scene.helper.healthUpdates().makeAsyncIterator()
        #expect(await health.next() == .handshaken)

        await scene.helper.disconnect()
        _ = try await scene.helper.acquireLease(Self.request)
        await scene.helper.disconnect()
        await scene.helper.disconnect()
        // Two values pushed after the disconnects, so each read below has something to return
        // whatever the disconnects published.
        await scene.helper.pushHealth(.interrupted)
        await scene.helper.pushHealth(.unresponsive)

        #expect(await health.next() == .idle, "a disconnect with a connection publishes idle")
        #expect(await health.next() == .interrupted, "and nothing else did")
        await scene.finish()
    }

    /// A call delayed on the clock is answered by a disconnect, as one parked by hand is, and its
    /// timer is gone at once. Moving the clock to the delay's end afterwards changes nothing: the
    /// answer was already given.
    ///
    /// **Mutation:** in `FakeLeaseHelper.disconnect`, leave the delayed calls and their timers
    /// alone. Red on the parked timer and on the answer, which the timer then gives as a grant.
    @Test("disconnect answers a delayed call")
    func disconnectAnswersADelayedCall() async throws {
        let scene = await LeaseScene()
        await scene.helper.script(.acquire, .after(.seconds(5)))
        let answer = ResultBox<String>()
        let call = scene.call {
            do {
                _ = try await scene.helper.acquireLease(Self.request)
                answer.set("granted")
            } catch {
                answer.set(String(describing: error))
            }
        }
        await scene.clock.untilParked(at: scene.at(.seconds(5)))

        await scene.helper.disconnect()
        #expect(scene.clock.parked.isEmpty, "the delayed call's timer outlived the disconnect")
        scene.clock.advance(to: scene.at(.seconds(5)))
        await scene.waitForReturn(of: call)

        #expect(answer.value == String(describing: HelperClientError.connectionAbandoned))
        await scene.finish()
    }
}

/// The fake answering one parked call rather than all of them, which the wake's suite leans on to
/// answer an old beat's renewal while the wake's own is still waiting.
@Suite("Fake helper: answering the oldest parked call", .timeLimit(.minutes(1)))
struct FakeLeaseHelperOldestParkedTests {

    /// `answerOldestParked` answers the call that parked first, and only that one: the other
    /// stays parked with its timer running.
    ///
    /// Both calls are delayed, so each is known to have parked once its timer is on the clock: a
    /// call's key, its timer and its parking are one step on the fake's actor, and nothing else
    /// runs on it in between.
    ///
    /// **Mutation:** in `FakeLeaseHelper.answerOldestParked`, take `max()` rather than `min()`.
    /// Red on the parked deadline and on which call returned. **Mutation:** answer every parked
    /// call of the verb. Red on the parked deadline.
    @Test("answerOldestParked answers the call that parked first, alone")
    func answersTheOldestAlone() async throws {
        let scene = await LeaseScene()
        let lease = try await scene.helper.acquireLease(FakeLeaseHelperTests.request)
        await scene.helper.script(.renew, .after(.seconds(100)), .after(.seconds(200)))
        let older = scene.call { _ = try? await scene.helper.renewLease(id: lease.id) }
        await scene.clock.untilParked(at: scene.at(.seconds(100)))
        let newer = scene.call { _ = try? await scene.helper.renewLease(id: lease.id) }
        await scene.clock.untilParked(at: scene.at(.seconds(200)))

        #expect(await scene.helper.answerOldestParked(.renew))
        #expect(scene.clock.parked == [scene.at(.seconds(200))], "the newer call's timer runs")
        // Whichever call was answered returns; a mutant that answered the newer one ends the
        // wait too, with the evidence.
        await firstOf(
            { await scene.waitForReturn(of: older) }, { await scene.waitForReturn(of: newer) })
        #expect(await scene.hasReturned(older), "the older call was not the one answered")
        #expect(await scene.entries.contains { $0.event == .renewAnswered(lease.id) })
        await scene.finish()
    }
}
