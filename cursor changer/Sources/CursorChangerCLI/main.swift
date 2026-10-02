import AppKit
import Foundation
import CursorChanger

let args = CommandLine.arguments

func runDebug(skinPath: String) throws {
    let url = URL(fileURLWithPath: NSString(string: skinPath).expandingTildeInPath)
    let theme = try CursorTheme.load(directory: url)
    for line in try CursorChanger.runDiagnostics(theme: theme) {
        print(line)
        FileHandle.standardOutput.synchronizeFile()
    }
}

guard args.count >= 2 else {
    print("Usage:")
    print("  CursorChangerCLI apply <skin-folder>    replace cursors with skin")
    print("  CursorChangerCLI restore                back to system cursors")
    print("  CursorChangerCLI capture                save current cursors as the stock set")
    print("  CursorChangerCLI debug <skin-folder>    apply + registry dump + live seed monitor")
    exit(2)
}

switch args[1] {
case "apply":
    guard args.count == 3 else {
        print("apply requires a skin folder path")
        exit(2)
    }
    let url = URL(fileURLWithPath: NSString(string: args[2]).expandingTildeInPath)
    do {
        let theme = try CursorTheme.load(directory: url)
        let report = try CursorChanger.apply(theme: theme)
        print(report.summary)
        for failure in report.failures {
            print("  failed \(failure.cgsName): \(failure.error!)")
        }
    } catch {
        print("ERROR: \(error)")
        exit(1)
    }
case "capture":
    do {
        let count = try CursorChanger.captureStockCursors()
        print("Captured \(count) stock cursor(s) to \(CursorChanger.stockCaptureDirectory.path)")
    } catch {
        print("ERROR: \(error)")
        exit(1)
    }
case "restore":
    do {
        if CursorChanger.hasStockCapture() {
            let count = try CursorChanger.restoreFromStockCapture()
            print("Re-registered \(count) stock cursor(s) from capture")
        } else {
            try CursorChanger.restore()
            print("System cursors restored (unregister-only; no capture existed)")
        }
    } catch {
        print("ERROR: \(error)")
        exit(1)
    }
case "debug":
    guard args.count == 3 else {
        print("debug requires a skin folder path")
        exit(2)
    }
    do {
        try runDebug(skinPath: args[2])
    } catch {
        print("ERROR: \(error)")
        exit(1)
    }
default:
    print("Unknown command: \(args[1])")
    exit(2)
}
