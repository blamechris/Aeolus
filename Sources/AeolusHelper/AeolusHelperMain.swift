import AeolusXPC
import FanKit
import Foundation
import SMCCore

// AeolusHelper — the privileged daemon.
//
// This process is the only thing in Aeolus that writes to the SMC, and it runs as root.
// Three rules govern every line added to this target:
//
//   1. Nothing merges here without review by the orchestrating model. See CLAUDE.md.
//   2. No write path merges before the safety subsystem (E5) exists and is tested.
//   3. Every client is authenticated by its code-signing requirement before it is
//      obeyed. Being able to connect is not authorisation.
//
// The control loop lives here rather than in the app on purpose: if the curve engine ran
// in the GUI, quitting or crashing the GUI would leave the fans pinned wherever they were
// last set. The helper is always the authority on fan state.
//
// TODO(E2): NSXPCListener on the mach service, client code-requirement checking,
//           SMAppService lifecycle.
// TODO(E5): Lease supervisor, thermal emergency override, sleep/wake handling via
//           IORegisterForSystemPower, reclamation watchdog, restore-on-exit paths.

@main
enum AeolusHelperMain {
    static func main() {
        FileHandle.standardError.write(
            Data(
                """
                AeolusHelper is not implemented yet.

                This binary is a scaffold. Registering it as a launch daemon would give a \
                do-nothing process root privileges, so it refuses to run instead.

                Protocol version: \(AeolusXPCVersion.current)
                Mach service:     \(AeolusXPCService.machServiceName)

                """.utf8
            ))
        exit(EXIT_FAILURE)
    }
}
