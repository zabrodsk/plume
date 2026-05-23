# Plume — Roadmap

> v1 is two files. v2 is three. v3 is still three.

The brand promise mostly survives.

- Less app, more page.
- Source surface measured in files, not directories.
- ~~Universal binary under 300 KB.~~ **Adjusted in v3.0 to under 1 MB
  universal** (≈470 KB per architecture). The under-300 KB line was
  set before Sparkle and SSH; the realistic v2.7.2 baseline measured
  ~636 KB universal. v3.0 measures ~948 KB universal — the +312 KB
  delta is the tab strip, multi-tab state, Codable conformances, and
  JSON persistence. Still the smallest notarized Mac editor we're
  aware of.
- Zero non-system dependencies.
- Right-click → Open is fine. We don't notarize.

If a feature would betray any of these, it doesn't ship.

---

## Shipped in v3.0

- **Tabs inside one window** with a custom pill tab strip (⌘T, ⌘1–⌘9,
  ⇧⌘] / ⇧⌘[, ⌃⇥). Each tab keeps native textarea undo, scroll, and
  selection across switches.
- **Multi-window**: ⌘N spawns a new window with its own tab set. Same-
  file dedup walks every window's tab list (local URLs and SSHPath).
- **State restoration**: windows + tabs survive relaunch via
  `~/Library/Application Support/Plume/state.json`. Dirty drafts and
  Untitled scratch buffers are kept; clean tabs reload from disk/SSH.
  Defensive load renames a corrupt file to `state.corrupt.json` and
  falls back to a fresh empty window.
- **Opt-out**: `defaults write com.zabrodsk.Plume plume.restoreWindowsOnLaunch -bool false`.
- **⌘N reassignment**: "New" (Untitled buffer) became ⌘T "New Tab";
  ⌘N is now "New Window". v2 muscle memory will get one wrong window
  on day one and adapt by day two.

The "Multi-tab / multi-document" line in the v2 *out of scope* section
below is preserved for archival reasons — it has now shipped.

---

---

## v2 headline: edit remote files over SSH

You should be able to open a file on a remote server, edit it in Plume, and save it back — without leaving the app, without mounting filesystems, and without bringing any new third-party code into the binary.

### Why this fits the brand

`/usr/bin/ssh` is a system tool. Every Mac ships with it. Plume currently shells out to nothing — but shelling out to `ssh` doesn't compromise the *zero-dependencies* claim, because there's nothing to bundle. It's the same tier of dependency as `lipo` or `codesign` in `build.sh`: shipped with the OS, treated as ambient infrastructure.

Authentication uses whatever ssh keys and `~/.ssh/config` host aliases the user already has. Plume adds nothing to your auth surface, your secret store, or your attack surface.

### The shape of the feature

**Menu bar**: `File → Open via SSH…` (⌥⌘O). Opens a single-field dialog where you type an SSH path, e.g. `dusan@server:/var/www/notes/post.md`, or just `myserver:notes/post.md` if you have a host alias.

**Save flow**: if the file came in over SSH, Cmd-S writes it back over SSH. Otherwise the existing local-save path runs unchanged. The window title shows `host:path` so you always know which file is open.

**Atomic writes**: SSH save uses temp-file-plus-rename, same as local saves. No half-written remote files if the connection drops mid-write.

**Failure modes** surface honestly: SSH timeout → retry/cancel dialog with the exact host. Permission denied → alert with the remote path. Stale connection → fall through to ssh's own re-auth prompt.

### How it lands in the source

| File | Change | Approx LOC |
|---|---|---|
| `src/main.swift` | Add `FileSource` enum (`.local(URL)` / `.remote(SSHPath)`) and replace `currentFileURL` with `currentFile: FileSource?`. New `SSHIO` namespace wrapping `Process` calls to `/usr/bin/ssh`. New menu item + dialog. | ~120 |
| `src/index.html` | Tiny: optional status hint when a remote file is active. No new editor logic. | ~10 |
| **NEW** `src/sshio.swift` *(only if needed)* | Extract SSH I/O if `main.swift` crosses ~450 lines and feels crowded. Stays opt-in to keep the two-file claim. | 0 or ~80 |

Worst case: Plume becomes a three-file project. Best case: it stays two and `main.swift` grows by ~120 lines. Either way the binary should stay under 300 KB.

### Implementation notes

- **Read**: `ssh host "cat -- /path/to/file"` — capture stdout into Swift via `Process`, decode UTF-8. Works for any text file under a few MB. Plume isn't for files larger than that anyway.
- **Write**: `ssh host "cat > /path/file.tmp && mv /path/file.tmp /path/file"` — atomic rename, same guarantees as local atomic writes.
- **Path parsing**: parse `[user@]host:path` ourselves. Let the user's `~/.ssh/config` resolve host aliases — we don't reimplement that.
- **No persistent connections in v2.** Each save round-trip is a fresh `ssh` subprocess. Adds ~200 ms vs ~10 ms for local saves. ControlMaster persistent sockets become v2.1 if it actually matters in real use.
- **No remote folder browsing in v2.** Open by exact path only. Browsing remote trees means a sidebar or file picker — both add UI surface that Plume v1 deliberately avoided.

---

## Secondary v2 (only if zero-cost)

These ride along if they fit the file and byte budgets; otherwise they wait.

- **Tab-completion in the SSH dialog** by reading `Host` entries from `~/.ssh/config`.
- **Recent remote files** — same Open Recent pattern as local files, just keyed by `host:path`.
- **Per-host preference memory** — remember zoom or theme variant for a server you edit often.

## Explicitly out of scope for v2

- Sidebar / file tree.
- Multi-tab / multi-document.
- Remote folder browsing UI.
- Multi-host concurrent editing.
- Full SFTP/SCP parity (binary transfer, permissions, mode bits, symlink semantics).
- Auto-reload when remote file changes externally.

These would betray *less app, more page*. They wait for v3 or never ship.

---

## Migration

v1 users open v2 and see one new menu item. No file format change. No settings migration. No first-run prompt. The local-edit experience is byte-identical to v1.

A v1 user who never touches remote files sees only an extra ~3 KB of binary size and one keystroke (`⌥⌘O`) they will never press.

---

## Known tensions

**WKWebView and SSH timing.** Reading a 50 KB remote file takes ~250 ms over a typical home connection. The editor will briefly show a blank page while content loads. Acceptable for v2 — the alternative is a loading spinner, which is more chrome than Plume tolerates. We mitigate by showing the host name in the title bar immediately so the user knows something's happening.

**Quarantine and ssh.** macOS Gatekeeper does *not* quarantine subprocesses spawned by an unsigned app, but a hardened-runtime app would need the `com.apple.security.cs.allow-jit` or similar entitlement to spawn ssh. v2 stays unsigned — same as v1. If we ever notarize, this is a flag to revisit.

**Cancellation.** A hung SSH read should be cancellable from the UI. Plume v1 has no cancel button anywhere. v2 needs at least an Esc-to-cancel during the brief loading window. This is the only new UI affordance v2 introduces in the editor itself.
