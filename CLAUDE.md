# SSH Drop — notes for Claude

macOS SwiftUI utility that copies dropped/pasted content to a remote host via `ssh`/`scp`.

## Build & run

- `xcodebuild -project "SSH Drop.xcodeproj" -scheme "SSH Drop" -configuration Debug build`
- Run the built app: `open ~/Library/Developer/Xcode/DerivedData/SSH_Drop-*/Build/Products/Debug/SSH\ Drop.app`
- Target macOS 15.7, Swift 5, default actor isolation is **MainActor** (project-wide setting).

## Architecture

- `TransferManager` (`@MainActor`, singleton `.shared`) owns host/path + host history (persisted in UserDefaults, max 5, recorded on each successful enqueue), the transfer log, and upload orchestration. UI binds to it via `@StateObject`/`@ObservedObject`.
- `SSHRunner` wraps `Process` for `ssh`/`scp`. Uses `BatchMode=yes`, `ConnectTimeout`, and connection multiplexing (`ControlMaster=auto`, `ControlPath=/tmp/sshdrop-%C`, `ControlPersist=600`). `prewarm(host:)` opens the master so drops start instantly.
- Upload = `ssh mkdir -p '<dir>'` then `scp <local> <host>:<remote>`.
- `PasteboardReader` reads an `NSPasteboard` (clipboard **or** the drag pasteboard) → file URLs, or image/text data written to a unique temp dir.
- Window drops use an **AppKit `NSView` (`DropTargetView`)**, not SwiftUI `.onDrop`. SwiftUI's drop flattens image files to nameless `public.png` data and strips the file URL; the raw dragging pasteboard keeps the file URL + name. Dock drops arrive via `AppDelegate.application(_:open:)`.

## Gotchas (learned the hard way)

- **scp remote path must NOT be shell-quoted** — macOS `scp` uses the SFTP backend and takes the path literally; quotes become part of the filename. Only `ssh mkdir` is shell-interpreted, so quote there.
- **Single `Window` scene** (not `WindowGroup`) — prevents `⌘N` and stops Dock drops from spawning extra windows. `.newItem` command removed too.
- **`⌘V`** handled by `PasteCatcher` `NSView.performKeyEquivalent`; it returns `false` when a text field is first responder so field paste still works (Paste button uses `⌘⇧V`).
- App Sandbox is **off** (required to spawn `ssh`/`scp`); `Info.plist` declares `public.item` document types for Dock drops.

## Debug tracing

`trace(_:)` in `AppDelegate.swift` appends timestamped lines to `/tmp/sshdrop-trace.log` (drop providers, upload timing). Kept intentionally — `cat /tmp/sshdrop-trace.log` to inspect. Launch detached via `open` so logs survive; check timings with an `awk` delta over the first column.

## Conventions

- Extreme concision, self-documenting code, comments only when non-obvious. Minimal diffs. One-line imperative commit messages, no AI attribution.
