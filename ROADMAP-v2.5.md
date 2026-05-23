# Plume — Roadmap to v2.5

> v2 added one keystroke. v2.5 makes that keystroke smarter — and lets
> Plume admit what it has become: an editor for files that live anywhere.

## What bends

The v2 roadmap drew a hard line at *less app, more page*. v2.5 does not
erase that line, but it concedes three things:

- **`src/main.swift` splits.** It's 598 lines after v2, past the threshold
  the original roadmap set for extracting a third file. SSH I/O moves to
  `src/sshio.swift`. Source surface goes from two files to three.
- **A modal file picker is new UI surface.** It exists for one job —
  picking a remote file — and vanishes when you do. There is still no
  persistent sidebar. The editor pane stays uncluttered.
- **One outbound HTTPS request on launch.** A version check against
  `api.github.com/repos/zabrodsk/plume/releases/latest`. No third-party
  framework, no analytics, no auth. A preference and a flag disable it.
- **First launch preloads a welcome document.** v1 and v2 open to a
  blank page — the empty page *is* the welcome. v2.5 opens to a single
  pre-filled `.md` document on the very first launch, then never again.
  The user edits it, saves it, or deletes it. See Headline 5 for why
  this is a brand bend and why it's still worth it.

If any of these concessions feels too expensive, that headline drops.

---

## Headline 1 — Browse remote files

Pick a host. Plume shows what's there. Click to open.

### Why this fits the brand (just barely)

A persistent sidebar would betray *less app, more page* — so we don't
add one. A *modal* file picker for the moment of opening a remote file
is the same kind of UI that `NSOpenPanel` is for local files: temporary,
focused, gone when the work begins.

### Shape

`File → Open via SSH…` (⌥⌘O) becomes a two-stage dialog:

1. **Host stage.** Single text field with autocomplete from
   `~/.ssh/config` Host entries. Type or pick.
2. **Browse stage.** A list view of the remote home directory (or the
   last directory visited on this host). Up-arrow goes to parent, double-
   click descends, single-click on `.md` / `.markdown` / `.txt` opens.
   Esc closes.

No multi-select. No write/rename/delete. No new files. Browsing is
read-to-open only — every other remote operation is the user's own SSH
session in Terminal.

### Implementation

- `ssh host "ls -lap --time-style=long-iso"` parsed into rows. Falls
  back to plain `ls -1ap` when BSD `ls` on the remote rejects GNU flags.
- Per-host last-visited path cached in `UserDefaults` under
  `plume.lastDir.<host>`.
- Browse pane is an `NSTableView` inside an `NSWindow` modal — not a
  sheet, so it can be moved and is keyboard-driven (↑↓, ↵, Esc).
- `~/.ssh/config` parsed for `Host` aliases. Pattern globs (`Host *.dev`)
  are ignored for autocomplete. ~50 LOC parser.

**LOC:** ~250 across the new `sshio.swift` + browse window in `main.swift`.

---

## Headline 2 — Finish the SSH story

Items the v2 ROADMAP listed under *Secondary v2 (only if zero-cost)*,
plus one v2 known tension. Together they make SSH feel done.

| Item | Cost | Why now |
|---|---|---|
| ssh_config tab-complete | (in Headline 1) | Free side effect of the browse parser. |
| **Open Recent → remote files** | ~40 LOC | `NSDocumentController` gives Recent for free; we register remote entries via a synthetic `URL` scheme `plume-ssh://host/path`. |
| **ControlMaster persistent sockets** | ~30 LOC | Set `ControlMaster=auto` + `ControlPath=/tmp/plume-%C` in spawned ssh args. First save establishes the master; subsequent saves reuse it (~10 ms vs ~200 ms). |
| **Esc-to-cancel during remote read** | ~50 LOC | The known v2 tension: a hung SSH read should be cancellable. A non-modal progress overlay appears after 250 ms with a Cancel affordance that calls `Process.terminate()`. |
| **Honest failure dialogs** | ~40 LOC | Permission denied, timeout, host unreachable, no such file — each gets a distinct dialog with the host and path. v2 collapses these into a generic "couldn't read remote file" alert. |

**LOC:** ~160 spread across `sshio.swift` and `main.swift`.

---

## Headline 3 — Editor depth

Make the page itself feel deeper without making it look busier.

### Find-in-page (`⌘F`)

A single-line search field drops in from the top edge of the editor.
Matches highlighted in the page; `↵` jumps to next, `⇧↵` to previous,
Esc dismisses. Standard editor affordance Plume currently lacks.

~80 LOC of JS in `index.html`.

### Smarter paste

Three rules added to the editor's paste handler:

1. **Rich-text paste** (clipboard contains HTML): convert `<a>` to
   `[text](url)`, `<strong>`/`<b>` to `**…**`, `<em>`/`<i>` to `*…*`,
   `<code>` to backticks. Drop everything else. Plain-text paste passes
   through unchanged.
2. **URL paste over selection**: if the clipboard is a URL and there's
   a selection, wrap the selection: `[selected](pasted-url)`.
3. **Multi-line paste into a list**: continue the list bullet or number
   on each pasted line.

~80 LOC of JS.

### Syntax highlighting in code fences

Hand-rolled tokenizer for six languages: `swift`, `javascript`/`js`,
`python`/`py`, `bash`/`sh`, `html`, `css`. A triple-backtick fence with a
language tag gets tokenized; tokens get CSS color classes. The
unrecognized-language fallback is the existing "monospace, no color"
rendering — same behavior as v2.

Why not bundle highlight.js or Prism: a 150-KB JS dependency would dwarf
the entire app. The hand-rolled tokenizer is ~40 LOC per language plus
~40 LOC of fence-detection scaffolding. Total ~280 LOC, all in
`index.html`.

The list of languages is short on purpose. Adding a 7th later is a one-
function change; adding 20 turns the editor into a polyglot toolchain
the brand doesn't want.

### Explicitly skipped

- **Tables.** They don't bloom — the per-keystroke animation Plume
  centers on doesn't fit cell-editing semantics.
- **Long-document scroll perf.** Defer until someone reports a real
  problem. v2 already handles 100-KB documents fluently.
- **Custom spellcheck.** WebKit's OS-level spellcheck is free when the
  user enables it; nothing to add.

**LOC for Headline 3:** ~440 in `index.html`.

---

## Headline 4 — Friction reduction

Things that make Plume *easier to keep*.

### Auto-update check

On launch (after a 1-second delay so launch perf isn't affected) a
single `GET` to:

```
https://api.github.com/repos/zabrodsk/plume/releases/latest
```

Compares `tag_name` to `Bundle.main.infoDictionary["CFBundleShortVersionString"]`.
If newer, a small unobtrusive banner appears at the bottom of the
editor: *"v2.6 is out ↗"* — clickable, dismissable, never modal.

Debounced once per day via `UserDefaults.lastUpdateCheckDate`. A
`--no-update-check` argv flag and a preference (`updateCheckEnabled`,
default `true`) opt out entirely. The endpoint requires no auth.

Why not Sparkle: it's a beautiful framework, but adding it pushes the
binary past 1 MB and ends the *zero dependencies* claim. ~40 LOC of
`URLSession` does 95 % of the job and zero of the harm.

### Light theme

A `@media (prefers-color-scheme: light)` block in `index.html` swaps
the background-cream/ink-warm palette for an inverted version. The app
chrome (`NSWindow` appearance) follows `NSApp.effectiveAppearance`
automatically when we leave `appearance = nil`, so macOS controls it.
No menu toggle, no preference — system-following only.

If a manual toggle becomes necessary later, it's a one-menu-item add.
We deliberately don't add it now to avoid the chrome.

~60 LOC across `index.html` + `main.swift`.

### Sample Homebrew cask

A `dist/plume.rb` cask formula committed to the repo. README copy:

> Want Homebrew? Copy `dist/plume.rb` into homebrew-cask as a community
> cask if you'd like to maintain one. We don't host a tap.

The formula sits there for anyone who wants to file a community PR.
~20 LOC of Ruby. Zero ongoing maintenance burden on us.

**LOC for Headline 4:** ~120 across multiple files.

---

## Headline 5 — Onboarding

> The page is the welcome.

Plume's brand rules out the standard onboarding playbook — welcome
screens, multi-step wizards, spotlight tours, "Pick a theme" prompts.
All of them betray *less app, more page*. v2.5 introduces a different
shape of onboarding: **the first thing you see is a page of text, and
that page is the lesson**.

The principle is *show, don't tell*. The editor demonstrates itself by
being the document.

### The welcome document

On first launch, Plume opens with a pre-loaded untitled `.md` document.
The content of that document *is* the onboarding:

- It demonstrates every visual style Plume renders — heading, italic,
  bold, blockquote, list, inline code, fenced code (with v2.5 syntax
  highlighting), link.
- It names the four shortcuts that matter: `⌘O` (local), `⌥⌘O` (SSH),
  `⌘F` (find), `⌘?` (shortcut cheatsheet).
- It says, in one short paragraph, what Plume is.

A draft of the doc, ~12 lines:

```markdown
# Welcome to Plume.

Plume is a markdown editor for the satisfaction of typing. Every
letter *blooms*. **Nothing else does.**

## Four keys that matter

- **⌘O** — open a local file
- **⌥⌘O** — open a file on a remote server via SSH
- **⌘F** — find in this page
- **⌘?** — every other shortcut

## The page is yours.

Delete this. Type something. Save with `⌘S`. That's all there is.

> *Less app. More page.*
```

The user edits, saves, deletes, or simply types over it — there is no
"finish onboarding" button because there is no onboarding mode. There
is just a document, and the document happens to teach.

`UserDefaults.firstLaunchSeen` flips after the first window opens,
keyed by version so v2 users upgrading to v2.5 also see it once (it's
how they discover browse, ⌘F, and ⌘?).

~80 LOC + the welcome string in `main.swift`.

### Empty-state Open Recent

When `File → Open Recent` is empty — fresh install or a user who
cleared history — the menu shows two italic, disabled placeholder rows:

```
no files yet
⌘O local · ⌥⌘O remote
```

The rows don't do anything when clicked; they're signal, not action.
They tell the user what the menu is for and name *both* open paths at
the exact moment the user is looking for files. They vanish as soon
as the recents list has one real entry.

This is the highest-leverage onboarding affordance in v2.5: most v2
users never realize Plume does SSH because the menu is silent. ~20 LOC.

### SSH dialog first-time hint

On the very first invocation of ⌥⌘O, the dialog includes one extra
italic line below the host field:

```
Type a host, or just a path.
Plume reads your ~/.ssh/config.
```

`UserDefaults.sshDialogSeen = true` afterwards; the hint never appears
again. ~15 LOC.

### Keyboard shortcut cheatsheet (`⌘?`)

`⌘?` opens a dismissable overlay listing every Plume shortcut on a
single screen — file ops, edit ops, navigation — three columns, italic
Fraunces section labels, mono-style key glyphs (typographically
consistent with the landing page). Esc dismisses. Never shown
automatically; it's a *reference*, not an onboarding step. The welcome
document mentions ⌘? so users learn it exists, and that's how
discoverability works without ever forcing a tour.

~120 LOC across `main.swift` (window) and `index.html` (markup).

### What this is NOT

Brand-discipline guard rails — naming what we *won't* do is half the
design:

- **No welcome wizard.** No "what's your name", "pick a theme", "watch
  this video".
- **No tooltip tour.** No spotlight bubbles or arrow callouts pointing
  at menu items.
- **No completion analytics.** We don't track whether onboarding
  worked. The proof is whether people tell their friends.
- **No *Skip onboarding* button.** Nothing to skip — the welcome
  document is just a document, and editing or deleting it is the
  natural exit.
- **No re-onboarding.** v2.5 → v2.6 doesn't fire a fresh welcome
  unless the v2.6 release notes specifically call for it.

**LOC for Headline 5:** ~235.

---

## File map after v2.5

```
src/
  main.swift     ~620 lines  AppDelegate, NSWindow, menus, NSDocument,
                             find-in-page wiring, update check, light
                             theme integration, welcome document,
                             cheatsheet window, first-launch flags
  sshio.swift    ~370 lines  SSHPath, ssh_config parser, SSH read/write,
                             ControlMaster, browse window, recents,
                             cancel/timeout handling, first-time hint
  index.html     ~580 lines  editor + find-in-page + paste rules
                             + syntax highlighter + light-mode CSS
                             + cheatsheet markup
  icon.swift     unchanged
  Info.plist     bumped to 2.5.0
  build.sh       unchanged (still universal arm64 + x86_64)
dist/
  release.sh     unchanged (delegate target for the dmg-sign-notarize skill)
  plume.rb       NEW (sample Homebrew cask)
```

Three source files. Roughly **1,570 lines of source**. Read every line
in an afternoon — still under the threshold where the project stops
being *a file* and starts being *a codebase*.

Binary-size estimate after v2.5: **~450–490 KB**, still well under
1 MB, still smaller than most browser extensions.

---

## Out of scope (still)

These remain explicit non-goals. v2.5 does not unlock them:

- **Persistent sidebar.** The browse modal goes away after pick.
- ~~**Multi-tab beyond what `NSDocument` already gives.**~~ **Shipped in
  v3.0 with a custom (non-NSDocument) tab strip and multi-window.**
- **Remote write operations** — `mkdir`, `rename`, `delete`.
- **Concurrent multi-host editing.**
- **Sparkle, Crashlytics, Sentry, any analytics.**
- **A hosted Homebrew tap.** Sample formula only.
- **Auto-reload on remote-file-changed.** Save-from-second-place wins.
- **Vim/Emacs keybindings.** macOS-native keys are non-negotiable.

---

## Migration

A v2 user picks up v2.5 and sees these new things:

1. On their next launch, a one-time welcome document opens. They can
   edit, save, or delete it; it never appears again.
2. The Open via SSH dialog gets a second pane (browse).
3. Code blocks gain color in six supported languages.
4. ⌘F finds in the page.
5. ⌘? shows a shortcut cheatsheet.
6. `File → Open Recent`, when empty, hints at the two open paths.
7. A small *"v2.6 is out"* banner if applicable.

No file format change. No settings migration. After the welcome doc is
dismissed, the local-edit experience is byte-identical to v2.

---

## Decisions still open

I made these calls in this draft. If any feel wrong, push back before
implementation begins — they're the forks that shape the release.

1. **Browse: modal vs persistent sidebar.** I picked modal. A sidebar
   would be a bigger product shift Plume's brand doesn't ask for, but
   it's a defensible choice if you want to commit to *editor with
   workspace*.
2. **Syntax highlighter: hand-rolled six languages vs none vs bundle a
   library.** I picked hand-rolled. The alternative *"no highlighting,
   monospace only"* is brand-purer but less of a v2.5. Bundling
   highlight.js is ruled out by the size cost.
3. **Auto-update: GitHub-JSON banner vs Sparkle vs nothing.** I picked
   the JSON banner. Sparkle is richer (background download, signature
   verification, full UI); nothing is brand-purer.
4. **Light theme: system-following only vs manual toggle.** I picked
   system-following. A toggle adds a menu item.
5. **Homebrew: sample formula vs hosted tap vs nothing.** I picked
   sample. Hosted tap is real ongoing work; nothing is fine but feels
   like a missed easy win.
6. **Welcome document on first launch.** I picked yes. Plume currently
   opens to a blank page; pre-loading content is a real brand bend
   ("the empty page *is* the welcome" was a v1 design choice). The
   alternative — first launch stays blank, onboarding is just the
   empty-Recent state + SSH hint + cheatsheet — is brand-purer but
   leaves v2 features (and v2.5 features) harder to discover.
7. **Cheatsheet trigger: `⌘?` vs Help-menu only vs nothing.** I picked
   `⌘?`. It's an unused shortcut and consistent with how some macOS
   apps surface keyboard help. A Help-menu-only entry is more
   conservative.

---

## Implementation order

The order doubles as a kill-switch list — drop the tail if scope blows up.

1. **Refactor: extract `sshio.swift`.** No behavior change. Ships as a
   pure refactor commit so the v2.5 features land on a clean base.
2. **ControlMaster.** Tiny, makes everything else feel faster.
3. **ssh_config parser + tab-complete.**
4. **Browse pane** (the headline). Lands together with Open Recent.
5. **Esc-to-cancel + honest failure dialogs.**
6. **Find-in-page.**
7. **Smarter paste.**
8. **Syntax highlighter** (six languages, one commit per language).
9. **Light theme.**
10. **Auto-update check.**
11. **Empty-Recent state + SSH first-time hint.** Small, ships
    alongside whichever earlier feature touched its file last.
12. **Keyboard cheatsheet (`⌘?`).** Independent; can ship any time.
13. **Welcome document.** Ships near the end because it relies on
    syntax highlighting, ⌘F, and ⌘? being live so the doc can
    demonstrate them.
14. **Sample Homebrew cask.**

Shipping through step 6 and stopping is a credible v2.5 release.
Shipping through step 8 is the headline release. Shipping through step
13 is the *"v2.5 final"* version. Step 14 (Homebrew) is a freebie
anyone can ship without ceremony.
