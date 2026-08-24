import AppKit

// CLI test mode: `Verbatim --transcribe file.wav` streams a file through the
// realtime engine and prints the transcript, so the whole pipeline can be
// exercised without hotkeys, microphone, or permissions.
if let idx = CommandLine.arguments.firstIndex(of: "--transcribe"),
   CommandLine.arguments.count > idx + 1 {
    transcribeFileAndExit(path: CommandLine.arguments[idx + 1])
} else {
    VerbatimApp.main()
}
