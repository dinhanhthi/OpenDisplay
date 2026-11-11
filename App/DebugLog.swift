import Foundation

/// DEBUG only: writes `[<category>] <message>` to stderr, where the Verify steps read it (the unified log is not
/// readable from a plain shell). Compiles to nothing in Release.
nonisolated func debugLog(_ category: String, _ message: @autoclosure () -> String) {
    #if DEBUG
    // One unbuffered write per line, so lines from different threads never interleave.
    FileHandle.standardError.write(Data("[\(category)] \(message())\n".utf8))
    #endif
}
