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
  selected window, in the terminal font and colors via tmux-switch --preview ... --ansi); Tab or Shift+Tab move, releasing Option switches, Esc cancels. Data comes from
  `/home/robot/.local/bin/tmux-switch` over ssh (own ControlMaster, `~/.ssh/omnity-switch-%C`); the key is
  swallowed in a local event monitor only when a terminal is focused (no Accessibility permission needed).
  Press M (cmd+M or just M while Option is held) to move the selected window to another session (picker with
  the existing sessions and always a "+ New session..." row that opens a name field (Enter creates and moves; typing a
  new name also shows it first); also right-click a row: Move to, New session...), via
  `tmux-switch --sessions` and `--move @id session`; the panel waits for Enter or Esc while the picker is open.
  Code in `macos/Sources/Features/Window Switcher/`.
- `macos-tmux-session-tabs = true` (default) and `macos-tmux-session-order = ecom,youtube,personal,tools`: a slim tab bar
  under the titlebar of a window whose foreground process is `ssh <macos-window-switcher-host>` (and tmux has a client):
  one tab per tmux session (listed ones first, then alphabetical, never MRU), window count, busy/bg dots, a yellow badge
  with the number of waiting windows, hover card with the windows. Click or cmd+1...9 switches session (only in those
  windows; ctrl+cmd+1...9 jump to the native tab, cmd+shift+[ / ] stay native); right-click: Rename session, New window,
  Close session (confirm). Uses the switcher's data (`WindowSwitcher.shared`, `TmuxSwitchClient`) and the host's
  `tmux-switch --session | --rename | --new-window | --kill-session`. Code in `macos/Sources/Features/Session Tabs/`.
- Host stats at the right end of the session tab bar (`Session Tabs/HostStats.swift`): omni's CPU, memory and disk in one dim
  line (amber from 80%, red from 90%, hover for load, GB and top process), read over the switcher's ssh connection
  (/proc and df, nothing installed; CPU/MEM every 5 s, disk every 60 s, paused when Omnity is in the background).
  Labels, then the whole block, drop when the tabs need the room. `OMNITY_HOST_STATS_FIXTURE=<file>` feeds it a captured output.
- Several tmux clients (another Mac, another window): Omnity passes its window's ssh source port (`lsof` of the foreground `ssh`)
  as `tmux-switch --peer PORT`, which puts that window's own client first, so the sidebar and tab bar follow THIS window, not the
  client with the latest activity. In the sidebar's unit view the current window's in-progress task is the first Now row ("this window").
- Lessons: never assume the tmux client with the latest activity is this window (several clients exist: pass the window's own ssh
  port to `tmux-switch --peer`); a cached host reading needs an age limit (`HostDiskCache`), or a failed refresh leaves an old value
  on screen as if it were current.
- Lesson: a local event monitor returns `OmnityMonitor.run(self, event) { $0.handle($1) }`, never `handle(event) ?? event`
  (that turns a swallowed key back into the event: tmux got option+digit as well as Omnity's `--go`).
- Sidebar rule: every task and every agent window appears once in the whole panel (an in-progress task carries its waiting window's question on its Now row), an empty section is not drawn, zero counts are left out of sentences, and a list's empty state starts at the same left edge as its title (gates: SidebarTests `everyItemAppearsOnceInEveryStyleAndMode`, `rowsAndEmptyStateShareTheLeadingInset`).
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
