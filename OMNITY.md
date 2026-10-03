# Omnity

Lincoln's fork of Ghostty. Branch `feat/remote-drop` adds:

- `macos-remote-drop = true`: dropping files, or pasting files or an image,
  into a surface whose foreground process is `ssh <host>` uploads them to
  `~/uploads` on that host and types the remote paths. A progress pill shows
  in the bottom-right corner.
- `macos-image-viewer = true`: cmd+click an image path to view it over the
  terminal, with a filmstrip of the other image paths on screen; over ssh the
  images are read from the host. Image URLs and CleanShot share links open
  there too. Cmd+click works inside tmux (no shift needed).
- Name Omnity (menu bar via `omnity-build.sh`, app menu, About, quit dialog), bundle id `com.lincolnaleixo.omnity`, orange icon.
- Sparkle updates disabled (never pulls Ghostty releases).

Every change is marked with an `Omnity:` comment.

## Monthly upstream merge

Build host: robots-mac-server, `~/Developer/omnity`.

1. `git fetch upstream && git merge upstream/main` (fix conflicts; search `Omnity:`).
2. `./omnity-build.sh` (zig build, then names and re-signs `zig-out/Omnity.app`; needs Xcode,
   Metal Toolchain and the Zig in `build.zig.zon`).
3. Run the parser tests: `cd macos && xcodebuild test -project Ghostty.xcodeproj -scheme Ghostty -only-testing:GhosttyTests/RemoteDropTests SYMROOT=$PWD/build`.
4. Install on robots-mac-mini and robots-macbook as `/Applications/Omnity.app` (copy
   `zig-out/Omnity.app`), then quit and reopen it.
5. Manual tests: drop in a local window (local path); drop in `ssh omni` (remote path, pill);
   CleanShot Cmd+V in `ssh omni` (remote path); cmd+click an image path
   and a CleanShot link inside tmux (viewer with filmstrip); drop with the network down (red pill, local path).
6. `git push origin feat/remote-drop`.

## Not tested yet

- Upload failure (network down or host off): expect a red pill with the error for 5 s,
  then the local path typed. Untested as of 2026-10-03.
- Installed on robots-mac-mini and robots-macbook.
