# Omnity

Lincoln's fork of Ghostty. Branch `feat/remote-drop` adds:

- `macos-remote-drop = true`: dropping files, or pasting files or an image,
  into a surface whose foreground process is `ssh <host>` uploads them to
  `~/uploads` on that host and types the remote paths. A progress pill shows
  in the bottom-right corner.
- Display name Omnity, bundle id `com.lincolnaleixo.omnity`, orange icon.
- Sparkle updates disabled (never pulls Ghostty releases).

Every change is marked with an `Omnity:` comment.

## Monthly upstream merge

Build host: robots-mac-server, `~/Developer/omnity`.

1. `git fetch upstream && git merge upstream/main` (fix conflicts; search `Omnity:`).
2. `zig build -Doptimize=ReleaseFast` (needs Xcode, Metal Toolchain and the Zig in `build.zig.zon`).
3. Run the parser tests: `cd macos && xcodebuild test -project Ghostty.xcodeproj -scheme Ghostty -only-testing:GhosttyTests/RemoteDropTests SYMROOT=$PWD/build`.
4. Install on robots-mac-mini as `/Applications/Omnity.app` (copy `zig-out/Ghostty.app`), then quit and reopen it.
5. Manual tests: drop in a local window (local path); drop in `ssh omni` (remote path, pill);
   CleanShot Cmd+V in `ssh omni` (remote path); drop with the network down (red pill, local path).
6. `git push origin feat/remote-drop`.

## Not tested yet

- Upload failure (network down or host off): expect a red pill with the error for 5 s,
  then the local path typed. Untested as of 2026-10-03.
