import os

/// Unified-logging channels for the pipeline's diagnostics/timings.
///
/// **Levels.** Per-chunk / per-utterance diagnostics (`pipeline`, `decode`) log
/// at `.debug`, so they are compiled in but suppressed by default — there is no
/// `CHATTERBOX_DEBUG` gate anymore. Only the once-per-launch lifecycle —
/// model load/compile timings and download progress — logs at `.notice`, so a
/// host app reading its own subsystem at default level is not flooded by a
/// stream whose chunk rate scales with the text it is narrating. To view the
/// debug lines:
///   • terminal: `log stream --level debug --predicate 'subsystem == "com.chatterbox.coreml"'`
///   • device over USB: enable debug logging for the subsystem, then `idevicesyslog`
///   • Console.app / Instruments: filter on the subsystem.
///
/// Dynamic values are interpolated with `privacy: .public` so counts, timings,
/// and file names are not redacted in the captured log. Message tags
/// (`[timing]`, `[speech]`, …) are preserved so existing log greps keep working.
enum Log {
    static let subsystem = "com.chatterbox.coreml"

    /// End-to-end pipeline stages (`[chunk]`, `[speech]`, `[timing]`, `[synth]`).
    static let pipeline = Logger(subsystem: subsystem, category: "pipeline")
    /// T3LM decode loop (`[decode:t3lm]`).
    static let decode = Logger(subsystem: subsystem, category: "decode")
    /// Model load / compile timing (`[load]`).
    static let load = Logger(subsystem: subsystem, category: "load")
    /// Hub download / self-heal (`[download]`).
    static let download = Logger(subsystem: subsystem, category: "download")
    /// Resident-memory snapshots (`[rss]`).
    static let memory = Logger(subsystem: subsystem, category: "memory")
}
