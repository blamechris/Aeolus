import Foundation

/// Writes a line to a file descriptor with `write(2)`, and says whether it arrived.
///
/// **Why not `FileHandle.write`.** It raises an Objective-C exception on EPIPE, which Swift
/// cannot catch: a consumer that went away would crash a process that is holding a lease,
/// instead of ending the hold in an orderly way. `fanctl set` ignores SIGPIPE and treats a
/// failed write to standard output as one of the ways a hold ends
/// ([#317](https://github.com/blamechris/Aeolus/issues/317)), which needs the write to be able
/// to say no.
///
/// **It does not block on a consumer that is alive and not reading.** A process stuck in
/// `write(2)` is a process that has stopped renewing its lease, so a pipe or socket with no room
/// is reported as failed. `poll(2)` with a zero timeout asks the question; a line is far smaller
/// than the room a writable pipe promises (`PIPE_BUF`), so a descriptor that is writable takes
/// it whole.
///
/// **Only pipes and sockets are asked.** macOS answers `POLLNVAL` for `/dev/null` and other
/// devices, so polling every descriptor would read `fanctl set … > /dev/null` as a consumer
/// that had gone, and end the hold the moment it began. A file or a terminal is written to and
/// the result of the write is the answer; neither stalls for want of a reader.
enum FileDescriptorWriter {

    /// Writes `text` and a newline, completely, or reports `false`.
    ///
    /// `false` means the line did not (or may not have wholly) arrive: the reader has gone, the
    /// descriptor is closed or invalid, or a pipe has no room to write without waiting.
    static func writeLine(_ text: String, to descriptor: Int32) -> Bool {
        // A descriptor `fstat` cannot describe leaves `status` zeroed, which is neither a pipe
        // nor a socket; the write then fails with EBADF and says so.
        var status = stat()
        _ = fstat(descriptor, &status)
        let kind = status.st_mode & S_IFMT
        let canStall = kind == S_IFIFO || kind == S_IFSOCK

        let bytes = Array((text + "\n").utf8)
        var written = 0
        while written < bytes.count {
            if canStall, !isWritable(descriptor) { return false }
            let count = bytes[written...].withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return false
            }
            written += count
        }
        return true
    }

    /// Whether a write would be accepted now: `POLLOUT` and none of `POLLERR`, `POLLHUP` or
    /// `POLLNVAL`, which is how a pipe whose reader closed announces itself.
    private static func isWritable(_ descriptor: Int32) -> Bool {
        var request = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        while true {
            let ready = poll(&request, 1, 0)
            if ready < 0 {
                if errno == EINTR { continue }
                return false
            }
            guard ready > 0 else { return false }
            let broken = Int16(POLLERR | POLLHUP | POLLNVAL)
            return request.revents & broken == 0 && request.revents & Int16(POLLOUT) != 0
        }
    }
}
