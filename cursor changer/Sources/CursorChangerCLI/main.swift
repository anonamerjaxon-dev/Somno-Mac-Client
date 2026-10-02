import AppKit
import CursorChanger
import Foundation

let args = CommandLine.arguments

func printUsage(to handle: FileHandle = .standardOutput) {
    func say(_ line: String) {
        if let data = (line + "\n").data(using: .utf8) {
            handle.write(data)
        }
    }
    say("CursorChangerCLI — apply, capture and restore macOS cursors")
    say("")
    say("USAGE")
    say("  CursorChangerCLI <command> [arguments]")
    say("")
    say("COMMANDS")
    say("  apply <skin-folder>   Replace the system cursors with a skin.")
    say("                        <skin-folder> is a path to a directory holding")
    say("                        arrow.png (or .svg) plus any other cursor images.")
    say("                        A leading ~ is expanded, so '~/Skins/tuff' works.")
    say("  restore               Put the system cursors back. Uses the stock set")
    say("                        saved by `capture` when one exists; otherwise it")
    say("                        unregisters this tool's cursors only.")
    say("  capture               Save the CURRENT system cursors as the stock set")
    say("                        under ~/Library/Application Support/CursorChanger.")
    say("                        Takes no arguments. Run this from a clean session")
    say("                        (or right after a reboot) — once you have applied")
    say("                        a skin, `capture` would just save your own skin.")
    say("  debug <skin-folder>   Diagnostic run: applies the skin, dumps the Core")
    say("                        Graphics cursor registry, monitors the live cursor")
    say("                        seed for a few seconds, then RESTORES the stock")
    say("                        cursors before exiting. It always restores — it")
    say("                        never leaves a skin applied.")
    say("  --help, -h, help      Print this text and exit 0.")
    say("")
    say("EXIT CODES")
    say("  0  success")
    say("  1  the operation failed (the reason is printed above)")
    say("  2  the command was used incorrectly")
    say("")
    say("EXAMPLES")
    say("  CursorChangerCLI apply ~/Skins/tuff")
    say("  CursorChangerCLI debug Examples/Skins/Tuff")
    say("  CursorChangerCLI restore")
}

func printUsageError(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ERROR: \(message)\n\n".utf8))
    printUsage(to: .standardError)
    exit(2)
}

func requireNoExtraArguments(_ extra: ArraySlice<String>, command: String) {
    guard extra.isEmpty else {
        printUsageError("`\(command)` takes no arguments, but got: \(extra.joined(separator: " "))")
    }
}

func requireSkinPath(_ extra: ArraySlice<String>, command: String) -> String {
    guard let path = extra.first else {
        printUsageError("`\(command)` requires a skin folder path (e.g. `\(command) ~/Skins/tuff`)")
    }
    guard extra.count == 1 else {
        printUsageError("`\(command)` takes exactly one skin folder path, but got \(extra.count)")
    }
    return path
}

func runDebug(skinPath: String) throws {
    // `CursorTheme.load(skinPath:)` expands `~` itself and standardizes the
    // path, so the README's `~/Skins/tuff` works here too.
    let theme = try CursorTheme.load(skinPath: skinPath)
    for line in try CursorChanger.runDiagnostics(theme: theme) {
        print(line)
        // `synchronizeFile()` is a disk-flush on a *file* handle and raises
        // NSFileHandleOperationException ("Invalid argument") when applied to
        // stdout, which is not a regular file when output is piped. `fflush`
        // is the right tool for flushing a stdio stream, and it is a no-op
        // error-wise when stdout is a terminal.
        fflush(stdout)
    }
}

if args.count < 2 {
    printUsageError("no command given")
}

let command = args[1]
let rest = args[2...]

if command == "--help" || command == "-h" || command == "help" {
    printUsage()
    exit(0)
}

switch command {
case "apply":
    let skinPath = requireSkinPath(rest, command: "apply")
    do {
        let theme = try CursorTheme.load(skinPath: skinPath)
        let report = try CursorChanger.apply(theme: theme)
        print(report.summary)
        for failure in report.failures {
            print("  failed \(failure.cgsName): \(failure.error?.localizedDescription ?? "unknown error")")
        }
        if !report.isSuccess { exit(1) }
    } catch {
        print("ERROR: \(error.localizedDescription)")
        exit(1)
    }

case "capture":
    requireNoExtraArguments(rest, command: "capture")
    do {
        let count = try CursorChanger.captureStockCursors()
        print("Captured \(count) stock cursor(s) to \(CursorChanger.stockCaptureDirectory.path)")
        if count == 0 {
            print("WARNING: nothing was captured — the current cursors may already be a custom skin.")
        }
    } catch {
        print("ERROR: \(error.localizedDescription)")
        exit(1)
    }

case "restore":
    requireNoExtraArguments(rest, command: "restore")
    do {
        if CursorChanger.hasStockCapture() {
            let count = try CursorChanger.restoreFromStockCapture()
            print("Re-registered \(count) stock cursor(s) from capture")
        } else {
            try CursorChanger.restore()
            print("System cursors restored (unregister-only; no capture existed)")
        }
    } catch {
        print("ERROR: \(error.localizedDescription)")
        exit(1)
    }

case "debug":
    let skinPath = requireSkinPath(rest, command: "debug")
    do {
        try runDebug(skinPath: skinPath)
    } catch {
        print("ERROR: \(error.localizedDescription)")
        exit(1)
    }

default:
    printUsageError("unknown command '\(command)'")
}