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
- `macos-window-switcher-host = omni` (default; `off` disables): hold Option and press Tab to open a
  cmd+tab style panel of the tmux windows on that host (grouped by session, state dot, last lines of the
  selected window, in the terminal colors via tmux-switch --preview ... --ansi); Tab or Shift+Tab move, releasing Option switches, Esc cancels. Data comes from
  `/home/robot/.local/bin/tmux-switch` over ssh (own ControlMaster, `~/.ssh/omnity-switch-%C`); the key is
  swallowed in a local event monitor only when a terminal is focused (no Accessibility permission needed).
  Code in `macos/Sources/Features/Window Switcher/`.
- Name Omnity (menu bar via `omnity-build.sh`, app menu, About, quit dialog), bundle id `com.lincolnaleixo.omnity`, orange icon.
- Sparkle updates disabled (never pulls Ghostty releases).

Every change is marked with an `Omnity:` comment.

## Releases and updates

Every commit pushed to `feat/remote-drop` becomes a release by itself:
robots-mac-server runs `omnity-release.sh` every 10 minutes (launchd,
`~/Library/LaunchAgents/com.lincolnaleixo.omnity-release.plist`, log in
`~/Library/Logs/omnity-release.log`). It builds with `omnity-build.sh` and publishes
`Omnity.zip` as a GitHub release (newest 5 kept). Each Omnity checks at launch and every 15 minutes,
installs a newer release in `/Applications` in the background and shows "Omnity update
ready" with a Restart button (× hides it until next launch). It never restarts by itself.

Builds are signed with a self-signed identity, "Omnity Self Signing", kept in
`~/Library/Keychains/omnity-signing.keychain-db` on robots-mac-server (passwordless, so launchd
can unlock it). macOS keys privacy permissions to the signing identity, so a fixed identity
keeps Documents and microphone access across updates. If the keychain is lost, create a new
identity with the same name: every Mac asks for the permissions once more.

## Monthly upstream merge

Build host: robots-mac-server, `~/Developer/omnity`.

1. `git fetch upstream && git merge upstream/main` (fix conflicts; search `Omnity:`).
2. `./omnity-build.sh` (zig builds the library, an Xcode scheme build makes the app, then it is
   named and re-signed as `zig-out/Omnity.app`; needs Xcode, Metal Toolchain and the Zig in
   `build.zig.zon`).
3. Run the tests: `cd macos && xcodebuild test -project Ghostty.xcodeproj -scheme Ghostty -arch arm64
   -only-testing:GhosttyTests/RemoteDropTests -only-testing:GhosttyTests/ImageViewerTests SYMROOT=$PWD/build`.
4. Try `zig-out/Omnity.app`: drop in a local window (local path); drop in `ssh omni` (remote path, pill);
   CleanShot Cmd+V in `ssh omni` (remote path); cmd+click an image path and a CleanShot link inside
   tmux (viewer with filmstrip); hold right Option and dictate.
5. `git push origin feat/remote-drop`; the release and the updates follow by themselves.

## Not tested yet

- Upload failure (network down or host off): expect a red pill with the error for 5 s,
  then the local path typed. Untested as of 2026-10-03.
- Self-update end to end: first run 2026-10-05 (release built by launchd, picked up by the app).
- robots-macbook still runs a build without the updater: install the latest release once by hand.
