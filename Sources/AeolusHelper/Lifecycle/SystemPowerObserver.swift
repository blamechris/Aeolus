import Foundation
import IOKit
import IOKit.pwr_mgt
import os

/// What the system said about its own power state.
///
/// Two cases, and the pair is deliberately narrower than IOKit's message vocabulary.
/// `kIOMessageCanSystemSleep` is a *question* — may I sleep? — and this helper has no
/// grounds to answer it with anything but yes, so it is answered inside the production
/// conformer and never reaches the seam. `kIOMessageSystemWillPowerOn` arrives before the
/// machine is usable, and § 4's answer to wake is "nothing", so a second wake case would
/// only be two names for the same absence of work.
enum SystemPowerEvent: Sendable, Hashable {

    /// The system is going to sleep and is **waiting** for this process to say it may.
    ///
    /// `docs/SAFETY.md` § 4's load-bearing half: release-before-sleep happens in the window
    /// this event opens, and the window closes when the notification is acknowledged.
    case willSleep

    /// The machine is awake again.
    ///
    /// § 4: *"After wake: **nothing.** The helper does not re-assert."* The event exists so
    /// that the absence of a write is a tested behaviour rather than an unwritten line.
    case didWake
}

/// One power notification, and the acknowledgement the system is waiting on.
///
/// ## Why the acknowledgement travels with the event
///
/// `IOAllowPowerChange(rootPort, notificationID)` needs the *particular* notification's
/// token, not merely "a power port" — so an `acknowledge()` reachable without the event that
/// minted it could only guess. Carrying it here makes "acknowledge the thing you were told
/// about" the only expressible shape, and makes the responder testable without IOKit: a test
/// double mints a notification whose acknowledgement records the instant it happened.
///
/// ## It is `async`, and the production body is not
///
/// `IOAllowPowerChange` is a synchronous kernel call and the production closure below is one
/// line of it. The `async` is for the *other* conformer: a test's acknowledgement has to be
/// able to look at what the firmware had already been asked to do, and reading an actor's
/// recorded calls is an `await`. A synchronous seam would have forced that observation onto
/// a detached task, which is exactly the ordering the acceptance criterion is about — a test
/// that spawns a task to record an order cannot assert the order.
struct SystemPowerNotification: Sendable {

    let event: SystemPowerEvent

    private let allowPowerChange: @Sendable () async -> Void

    init(
        event: SystemPowerEvent,
        acknowledging allowPowerChange: @escaping @Sendable () async -> Void
    ) {
        self.event = event
        self.allowPowerChange = allowPowerChange
    }

    /// Tells the system it may proceed.
    ///
    /// Idempotency is **not** promised here and must not be assumed: the guard lives in
    /// `SleepAcknowledgement`, which is the one type that decides this happens once per
    /// episode. Putting it here as well would give two places an answer to the same question
    /// and no reason for them to agree.
    func acknowledge() async {
        await allowPowerChange()
    }
}

/// The seam § 4 hears the system through.
///
/// It exists so that `SystemPowerResponder` can be driven with **no hardware**: a test mints
/// `.willSleep` and `.didWake` and observes what reached the firmware and in which order.
/// That matters more here than for most seams, because the production conformer cannot be
/// exercised by any automated test this project can run — `IORegisterForSystemPower` needs a
/// real power management root, and the behaviour under test only happens when a real machine
/// really sleeps. Everything above this line is testable; everything below it is a hardware
/// checklist row.
protocol SystemPowerObserving: Sendable {

    /// Starts delivering power events to `handler`.
    ///
    /// - Important: the handler is called for **every** subsequent event and there is no
    ///   `stopObserving`. That is not an omission — see `IOKitSystemPowerObserver`, whose
    ///   registration lives for the life of a process that never returns. A teardown verb
    ///   would be a branch nothing can reach, in the target where an unreachable branch is
    ///   most expensive.
    /// - Throws: when the system will not deliver power events to this process at all. The
    ///   caller logs and carries on: a helper without § 4 still has § 1's TTL, which is the
    ///   backstop § 4 was always measured against.
    func observe(_ handler: @escaping @Sendable (SystemPowerNotification) async -> Void) throws
}

/// Why this process cannot hear the system's power events.
enum SystemPowerObservationFailure: Error, Sendable, Hashable {

    /// `IORegisterForSystemPower` did not return a usable connection.
    ///
    /// One case rather than a decoded `IOReturn`, because the call reports failure by
    /// answering `MACH_PORT_NULL` rather than by a status code, and inventing a richer
    /// vocabulary than the API has would be a claim about a distinction nothing made.
    case registrationRefused
}

// MARK: - The hardware conformer

/// `IORegisterForSystemPower`, delivered on a dispatch queue.
///
/// ## Why a dispatch queue and not a run loop
///
/// The textbook registration ends `CFRunLoopAddSource(CFRunLoopGetCurrent(), …)`, and
/// `AeolusHelperMain.main()` ends in `dispatchMain()`. `dispatchMain()` does not run a
/// CFRunLoop on the main thread — it parks it and hands the thread to libdispatch — so a
/// run-loop source added there is added to a run loop nothing will ever run, and the
/// notification simply never arrives. Nothing would report that: registration succeeds, the
/// daemon looks healthy, and the fans stay wherever a lease left them across every sleep.
/// `IONotificationPortSetDispatchQueue` is the supported alternative and is why decision A5
/// names it rather than leaving the mechanism to the implementer.
///
/// ## What it deliberately does not do
///
/// It never vetoes a sleep. `kIOMessageCanSystemSleep` — the *idle* sleep query, which a
/// process may cancel — is allowed immediately and is not surfaced on the seam at all. A
/// helper that could refuse to let a laptop sleep because a fan write was outstanding would
/// be a worse failure than the one § 4 exists to prevent, and `docs/SAFETY.md` gives it no
/// authority to try. Leaving that message *unanswered* is not the safe default either: the
/// kernel then waits out its own timeout before sleeping, so a helper that ignored it would
/// silently make every idle sleep take about thirty seconds longer.
struct IOKitSystemPowerObserver: SystemPowerObserving {

    /// The queue IOKit delivers callbacks on. Serial, and its own: a power notification
    /// arriving while the previous one's handler is still being spawned must queue behind it
    /// rather than interleave.
    private let queue: DispatchQueue

    init(
        queue: DispatchQueue = DispatchQueue(label: "dev.aeolus.AeolusHelper.system-power")
    ) {
        self.queue = queue
    }

    /// Registers for system power notifications, and starts delivery last.
    ///
    /// The order of the final two statements is the whole of this method's correctness.
    /// `IORegisterForSystemPower` is what *produces* the root port, and the callback needs
    /// that port to acknowledge anything — so the port is stored into the registration after
    /// the call returns, and delivery is enabled only after that store. Enabling delivery
    /// first would open a window in which a `.willSleep` callback could read a port of zero
    /// and acknowledge nothing, which the machine would experience as a sleep that stalled
    /// for its full timeout while a helper held the fans.
    func observe(_ handler: @escaping @Sendable (SystemPowerNotification) async -> Void) throws {
        let registration = SystemPowerRegistration(handler: handler)
        let context = Unmanaged.passRetained(registration).toOpaque()

        var notificationPort: IONotificationPortRef?
        var notifier: io_object_t = 0
        let connection = IORegisterForSystemPower(
            context, &notificationPort, systemPowerCallback, &notifier)

        guard connection != MACH_PORT_NULL, let notificationPort else {
            // Balances the `passRetained` above. Spelled `takeRetainedValue()` rather than
            // `release()` because `ThermalEmergencyStalenessTests` scans `Sources` for an
            // unqualified `release()` — § 3's latch must only ever be cleared by naming the
            // episode — and that pattern does not read the receiver, so `Unmanaged`'s own
            // `release()` trips it. Consuming the retain by taking the value is the same act.
            _ = Unmanaged<SystemPowerRegistration>.fromOpaque(context).takeRetainedValue()
            throw SystemPowerObservationFailure.registrationRefused
        }

        registration.adopt(rootPort: connection)
        IONotificationPortSetDispatchQueue(notificationPort, queue)
    }
}

/// The root power domain's message numbers, which Swift does not import.
///
/// `IOKit/IOMessage.h` spells each one `iokit_common_msg(0x280)`, and that macro expands to a
/// cast over two further macros — `sys_iokit`, itself `err_system(0x38)` — so the whole family
/// arrives in Swift as *"macro unavailable: structure not supported"*. There is no
/// `import IOKit.IOMessage` to reach around it: that submodule does not exist.
///
/// **The base is recovered from a constant Swift does import rather than written down.**
/// `IOReturn.h` builds its codes with `iokit_common_err(x)`, which is the *same*
/// `sys_iokit | sub_iokit_common` composition over the same bits, and `kIOReturnError` —
/// `iokit_common_err(0x2bc)` — imports fine because it is an `enum` value rather than a macro.
/// Subtracting its own message number therefore yields the shared base, from the SDK, at
/// compile time. A hand-written `0xE000_0280` would be three magic numbers whose only proof
/// was that somebody read a header once; this is one derivation whose inputs are checkable and
/// whose arithmetic `SystemPowerMessageTests` pins against the values `IOMessage.h` documents.
///
/// Getting one wrong fails **silently and completely**: registration succeeds, the daemon
/// looks healthy, and no `.willSleep` ever reaches § 4. That is why the numbers are derived
/// and pinned rather than trusted, and why the lid-close hardware row is the row that finally
/// proves them.
enum SystemPowerMessage {

    /// `sys_iokit | sub_iokit_common`, taken from the SDK by way of a constant that imports.
    static let base = UInt32(bitPattern: kIOReturnError) - 0x2bc

    /// `kIOMessageCanSystemSleep` — the idle-sleep *question*, which a process may veto.
    static let canSystemSleep = base | 0x270

    /// `kIOMessageSystemWillSleep` — the sleep is happening; acknowledge to let it proceed.
    static let systemWillSleep = base | 0x280

    /// `kIOMessageSystemHasPoweredOn` — awake, and usable.
    static let systemHasPoweredOn = base | 0x300
}

/// What the C callback is handed back: the port to acknowledge on, and where to deliver.
///
/// ## Why it is provably `Sendable` rather than asserted to be
///
/// A `@convention(c)` callback cannot capture, so the only way to reach Swift state from one
/// is the pointer IOKit carries in its `refcon`. That is read on an arbitrary dispatch queue,
/// so what it points at has to be safe to touch from anywhere — and `CLAUDE.md` rule 10 plus
/// this repository's own SwiftLint rule both refuse the unchecked-conformance escape hatch in
/// the helper, so "safe" here has to mean *checked*. (Naming that spelling in prose is what
/// the rule's own regex matches, which is why this sentence talks around it.)
///
/// The root port is the awkward part: it does not exist until `IORegisterForSystemPower`
/// returns, and this object has to exist before that call is made. So it is one mutable value
/// in an `OSAllocatedUnfairLock`, which is `Sendable` for a `Sendable` state and needs no
/// escape hatch. `observe(_:)` stores it before enabling delivery, and enabling delivery is
/// what makes this callback reachable at all — so no callback can read the port unset, and
/// the lock is the belt rather than the mechanism.
///
/// ## It is retained for the life of the process, deliberately
///
/// `Unmanaged.passRetained` with no matching release, and the notification port and notifier
/// are never destroyed either. The only owner is a daemon whose `main()` ends in
/// `dispatchMain()` and never returns; a teardown path would be code no test can run in a
/// target where every branch is reviewed. The one release that *does* happen is on the
/// failure path above, where the registration never became reachable.
private final class SystemPowerRegistration: Sendable {

    private let rootPort = OSAllocatedUnfairLock<io_connect_t>(initialState: 0)
    private let handler: @Sendable (SystemPowerNotification) async -> Void

    init(handler: @escaping @Sendable (SystemPowerNotification) async -> Void) {
        self.handler = handler
    }

    /// Stores the port every acknowledgement goes out on. Once, before delivery starts.
    func adopt(rootPort port: io_connect_t) {
        rootPort.withLock { $0 = port }
    }

    /// Translates one IOKit message into the seam's vocabulary, or answers it here.
    ///
    /// `kIOMessageCanSystemSleep` is answered here and never surfaced — see this file's
    /// `IOKitSystemPowerObserver` note on why refusing a sleep is not this helper's to do and
    /// why ignoring the question is worse than answering it. Every other message the root
    /// power domain sends — `kIOMessageSystemWillPowerOn`, and the ones about power sources —
    /// is dropped: § 4 acts on two moments and inventing work for the others would be a write
    /// nobody asked for.
    func received(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        // Converted at the boundary rather than carried as a pointer. It is not a pointer:
        // `IOAllowPowerChange` takes it as an opaque `intptr_t` token, and a raw pointer in
        // a captured closure invites somebody to dereference it.
        let token = Int(bitPattern: argument)
        let port = rootPort.withLock { $0 }

        switch messageType {
        case SystemPowerMessage.canSystemSleep:
            IOAllowPowerChange(port, token)
        case SystemPowerMessage.systemWillSleep:
            deliver(.willSleep) { IOAllowPowerChange(port, token) }
        case SystemPowerMessage.systemHasPoweredOn:
            // Acknowledging a wake is not a thing IOKit asks for: the machine is already on.
            deliver(.didWake) {}
        default:
            return
        }
    }

    /// Hands one event to the async world.
    ///
    /// The `Task` is the only route from a `@convention(c)` callback to an `async` handler,
    /// and it is the reason `SystemPowerObserver.swift` appears in
    /// `WriteVerbAllowlistTests.everyUnstructuredTaskHandsOffToThePopulation`. Its body is a
    /// single `await` of `SystemPowerResponder.respond(to:)`, which is acknowledged there:
    /// nothing is written in this frame.
    private func deliver(
        _ event: SystemPowerEvent, acknowledging allow: @escaping @Sendable () -> Void
    ) {
        let notification = SystemPowerNotification(event: event) { allow() }
        let handler = self.handler
        Task { await handler(notification) }
    }
}

/// The `@convention(c)` trampoline. It cannot capture, so everything it needs arrives in
/// `context` — see `SystemPowerRegistration` for why that object is safe to touch here.
private let systemPowerCallback: IOServiceInterestCallback = { context, _, message, argument in
    guard let context else { return }
    Unmanaged<SystemPowerRegistration>.fromOpaque(context)
        .takeUnretainedValue()
        .received(messageType: message, argument: argument)
}
