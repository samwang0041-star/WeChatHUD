import AppKit
import Darwin
import Foundation

// Line-buffer stdout so `tee`/`tail -f` sees prints immediately.
setvbuf(stdout, nil, _IOLBF, 0)

// CLI subcommand dispatch. Runs BEFORE NSApplication.run() so the binary
// can be used as a one-shot tool for prompt iteration without bringing
// up the full HUD. Recognised subcommands:
//
//   classify <text> [--sender NAME] [--chat NAME] [--group]
//   classify-fixture <path/to/labeled_messages.json>
//   classify-real [--per-chat N] [--out path.json] [--include-groups]
//   suggest-reply <text> [--sender N] [--chat N] [--group] [--type T]
//   group-catchup <chat_username> [--limit N]
//   categorize <chat_username> [--limit N]
//   retrospect [--date YYYY-MM-DD]
//
// Anything else falls through to launching the GUI.
let aiSubcommands: Set<String> = [
    "classify",
    "classify-fixture",
    "classify-real",
    "suggest-reply",
    "group-catchup",
    "categorize",
    "retrospect"
]
if CommandLine.arguments.count >= 2 {
    let sub = CommandLine.arguments[1]
    if aiSubcommands.contains(sub) {
        ClassifierCLI.run(args: Array(CommandLine.arguments.dropFirst(2)), subcommand: sub)
        // ClassifierCLI.run never returns; calls exit(0)/exit(1) itself.
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
