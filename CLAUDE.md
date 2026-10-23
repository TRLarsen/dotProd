# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

`dotProd` is a declarative dotfiles / machine-bootstrapping system built on
[chezmoi](https://www.chezmoi.io/) and [mise](https://mise.jdx.dev/). It takes a
blank Linux machine to a fully configured dev environment. It is **not an
application** — there is no build step. Changes are validated by the test
suite in `tests/` (lint, data invariants, a render matrix and real
container applies — see [Testing / CI](#testing--ci)), which CI runs on
every PR, plus applying them with chezmoi (dry-run) and reasoning about the
generated shell.

The README.md is thorough and authoritative on intent — read it if unsure
about the architecture rationale. Note the numeric script prefixes described
below sometimes drift from the README; trust the actual filenames in the repo
over the README's prose when they disagree.

## Core architecture: the Data-Driven Dispatcher

All machine state is declared in `.chezmoidata.toml`, which is organized into
four installer tiers, each installed by a different mechanism, plus one
opt-in personalization tier layered on top:

1. **`[system_tools]`** — native OS packages requiring `sudo` (apt/dnf/pacman,
   auto-detected from `.chezmoi.osRelease.id`). Installed by
   `run_onchange_before_01_install_system_tools.sh.tmpl`.
2. **`[external_user_tools]`** — anything installed by a custom script rather
   than mise (compiler toolchains, curl-installed CLIs). Each entry is a table
   `{ version = "...", kind = "..." }`; `kind` selects the script directory
   (`toolchains` or `standalone`). Installed by
   `run_onchange_before_02_install_user_tools.sh.tmpl`, which also runs a
   **collision-detection health check** (see below) and bootstraps `mise`
   itself.
3. **`[user_tools]`** — CLI apps installed concurrently via `mise` (cargo, npm,
   pipx, uv, aqua, github, and other GitHub-release-style backends). The key
   is the mise package spec (e.g. `"ripgrep"`, `"pipx:ruff"`), the value is
   either a plain binary-name string (used for the collision check, version
   defaults to `"latest"`) or a table `{ bin = "...", profiles = [...],
   version = "..." }` for entries that need restricting to a subset of
   profiles and/or pinning to an explicit version — same optional-field
   pattern `[system_tools]`/`[external_user_tools]` already use. Pinning is
   the exception: it opts a tool out of `czup`'s rolling-latest upgrades.
   Actually installed by
   `run_onchange_after_10_install_mise_tools.sh.tmpl` (`mise install -y`),
   after `private_dot_config/mise/config.toml.tmpl` has rendered the `[tools]`
   table from this same data.
4. **`[gui_apps]`** — desktop apps, installed via Flatpak by default, or a
   custom script if one exists, or natively via `apt`/`dnf`/`pacman` if the
   entry is a table with `native = true` (for a package unavailable as a
   Flatpak).
   Installed by `run_onchange_before_03_install_gui_apps.sh.tmpl`, gated on a
   display server (`$WAYLAND_DISPLAY`/`$DISPLAY`) being present — this gate
   applies to native entries too, so an app marked `native = true` is still
   skipped entirely on headless machines/SSH sessions.
5. **`[personal]`** — opinionated, per-machine opt-in settings, namespaced
   per app (e.g. `[personal.zen]` with an `active` key and a nested
   `[personal.zen.extensions]` table). Not part of the install
   dispatcher above; applied by the generic
   `run_after_20_configure_personal.sh.tmpl` dispatcher, which reruns on
   *every* `chezmoi apply` (deliberately `run_after_`, not
   `run_onchange_after_`, so it also picks up state that changes outside
   `.chezmoidata.toml`, like a newly-created browser profile). It Go-template
   `range`s over `.personal` and, for each app whose table has `active =
   true`, runs `.scripts/personal/<app>/configure.sh.tmpl` — **the `active`
   check happens in the dispatcher itself**, not in the per-app script, so a
   `[personal.<app>]` table with `active = false` (or no `active` key)
   reliably disables that app's script even if the script forgot to check.
   **Every per-app script must still gate on the target app's presence**
   (`command -v <app>` or equivalent) as its first real statement — that
   part is orthogonal to `active` and keeps the script a safe no-op if the
   app itself isn't installed (headless, commented out of
   `[gui_apps]`/`[system_tools]`, etc.), rather than erroring or writing
   config for software that isn't there. See
   `.scripts/personal/zen/configure.sh.tmpl` for the reference
   implementation of this pattern.

   A `[personal.<app>]` table may also set `requires = "<machine-class>"`
   (e.g. `requires = "laptop"`, see `[personal.battery_charge_threshold]`)
   to scope itself to a class of machine. This checks a **machine-local**
   data key of the same name (`.laptop`), sourced from `.chezmoi.toml.tmpl`
   — chezmoi's own mechanism for per-machine data that's deliberately *not*
   committed to git (it lives in `~/.config/chezmoi/chezmoi.toml`, answered
   once via `promptBoolOnce` at `chezmoi init`, auto-detected where
   possible). This is what lets a genuinely machine-specific setting stay
   declared with `active = true` on every machine's shared
   `.chezmoidata.toml` and just safely no-op where it doesn't apply, instead
   of forking a separate git branch per machine class (which was the old
   pattern — don't do that anymore for this kind of difference). Chezmoi has
   no built-in "profiles" feature; this data+template approach is the
   documented, intended way to differentiate machines. Add a new machine
   class the same way: extend `.chezmoi.toml.tmpl`'s `[data]` table with
   another `promptBoolOnce`, then reference it via `requires` — no dispatcher
   changes needed, it's already generic over the key name. `laptop`/`requires`
   and the install-`profile` mechanism below are both instances of this same
   machine-local-data pattern, kept orthogonal on purpose (a shared/borrowed
   laptop can still be install-profile `minimal`) — see "Install profiles"
   below.

   A `[personal.<app>]` table may also set `profiles = [...]` (e.g.
   `profiles = ["standard"]`, see `[personal.zen]`) to restrict itself to a
   subset of install profiles, checked in `run_after_20_configure_personal.sh.tmpl`
   via the same shared `entry-in-profile` partial the four install-tier
   dispatchers use (see "Install profiles" below). This is for settings tied
   to a GUI app that should be a declared no-op on `headless`/`minimal`
   rather than an implicit side effect of the app never being installed
   there. Omitting `profiles` means "every profile", same default as
   everywhere else that partial is used.

`run_after_90_integrations.sh` runs last and handles cross-tool glue that
doesn't fit the tiered model (currently: symlinking the system LLDB debug
adapter to `~/.local/bin/lldb-dap` for Helix).

### Install profiles

Every machine also answers a **`profile`** — `standard` (owned desktop, full
GUI, no constraints), `headless` (owned server, no display, sudo available,
full dev toolchain), or `minimal` (resource-constrained and/or shared with
others — university lab, coworker's machine — must work with **no sudo**).
Like `laptop`, `profile` is machine-local data from `.chezmoi.toml.tmpl`
(`promptChoiceOnce`, not `promptBoolOnce` — it validates the answer against
the three-item choice list instead of accepting anything, so a typo can't
silently produce an unrecognized profile). Unlike `requires = "laptop"`
(which only gates the opt-in `[personal]` layer), `profile` gates the four
install tiers themselves:

- `.chezmoidata.toml` has a `[profiles]` table declaring what each profile
  can do — `sudo` (gates the whole `[system_tools]` tier and native
  `[gui_apps]` installs) and `gui` (additionally gates `[gui_apps]`, on top
  of the existing display-server runtime check). This is a capability table,
  not a hardcoded name check, specifically so that adding a fourth profile
  later — or a new capability dimension — is a pure data change; none of the
  four dispatcher scripts need editing.
- Individual entries in any tier can further restrict themselves with a
  `profiles = [...]` key (e.g. `rust = { version = "stable", kind =
  "toolchains", profiles = ["standard", "headless"] }`) for cases the
  capability gate doesn't cover — a desktop-integration package excluded
  from `headless` even though headless has sudo, or a heavyweight toolchain
  excluded from `minimal` for footprint reasons even though nothing about it
  needs sudo. Omitting `profiles` means "available on every profile the
  tier's capability gate allows" — this keeps "just add a line" true for the
  common case; only entries that actually need restricting get annotated.
  `[user_tools]` values follow the same flat-string-vs-table duality already
  used for `[system_tools]`'s per-distro entries: a plain string is a binary
  name (all profiles), a table is `{ bin = "...", profiles = [...] }`.
- The `profiles = [...]` check itself lives in one place —
  `.chezmoitemplates/entry-in-profile`, included via `{{ includeTemplate
  "entry-in-profile" (dict "entry" $value "profile" $.profile) }}` — and is
  applied identically in all four tier loops (plus
  `private_dot_config/mise/config.toml.tmpl`, which must filter `[tools]`
  the same way the `[user_tools]` collision check does, or `mise install -y`
  would install things the collision check correctly skipped). If a
  machine's stored `profile` doesn't match a key in `[profiles]`, each
  dispatcher fails loudly at render time rather than guessing.

### Execution order

Chezmoi runs scripts in lexical order of their `run_*` prefix
(`before_01` → `before_02` → `before_03` → `after_10` → `after_20` →
`after_90`), so system packages exist before toolchains, toolchains before
mise, mise before GUI apps, and everything before the personalization and
final integrations passes. `onchange` scripts are hashed by chezmoi and only
re-run when their content (or, for the mise script, the `Hash: {{ printf
"%s|%s" (.user_tools | toJson) .profile | sha256sum }}` comment, which also
covers `.profile` so switching a machine's profile re-triggers the collision
check even when `.user_tools` itself hasn't changed) changes —
`run_after_20_configure_personal.sh.tmpl` and the per-app scripts it
dispatches to are plain `run_after_` (not `run_onchange_after_`) and so
always re-run, relying on their own idempotency/gating instead.

### The collision-detection guard

`run_onchange_before_02_install_user_tools.sh.tmpl` builds a `MISE_TOOLS`
bash array from every value in `[user_tools]` and, before letting mise run,
checks that none of those binaries already resolve on `$PATH` outside
`~/.local/share/mise`, `~/.local/bin/mise`, or `~/.cargo/bin`. If a
system-package version of a mise-managed tool is found, the script **aborts
the whole pipeline** rather than silently shadowing it. When adding a tool to
`[user_tools]`, keep this in mind — don't also install it via
`[system_tools]`.

## Extending the system

**Standard package** (apt/dnf/pacman package with no special install logic,
or a plain mise-installable binary): just add a line to the appropriate
section of `.chezmoidata.toml`. No script needed. It's available on every
install profile by default; add a `profiles = [...]` key only if it should
be restricted (see [Install profiles](#install-profiles)).

**Complex package** (custom repo/PPA, `curl | sh` install, pre-install
cleanup): add the entry to `.chezmoidata.toml`, then create a script named
exactly after the TOML key:

| Tier | Script path |
|---|---|
| `system_tools` | `.scripts/daemons/<tool>.sh` |
| `external_user_tools`, kind = `toolchains` | `.scripts/toolchains/<tool>.sh` |
| `external_user_tools`, kind = `standalone` | `.scripts/standalone/<tool>.sh` |
| `gui_apps` | `.scripts/gui/<app>.sh.tmpl` |

The dispatcher passes the TOML value to the script as `$1`. GUI scripts are
always `.sh.tmpl` files (rendered through `chezmoi execute-template` before
execution — the GUI dispatcher only looks for that name, a plain `.sh` would
be silently ignored), so they can use OS conditionals — see
`.scripts/gui/ghostty.sh.tmpl` for the pattern (checks
`.chezmoi.osRelease.id` for ubuntu/debian vs fedora).
Every script should be idempotent: check `command -v <tool>` (or equivalent)
before doing work, and `set -euo pipefail` at the top. `system_tools` daemon
scripts are the exception to the skip-if-present rule: the dispatcher runs
them every time the tier runs (even when the binary already exists) and
embeds each script's hash in the rendered dispatcher, so editing the script
re-triggers it. That lets them converge more than "is it installed", e.g.
`.scripts/daemons/tailscale.sh` also enforces the package repo, the systemd
service and auto-update, and every step in such a script must be safe to
re-run.

**Personal, app-linked settings** (a new `[personal.<app>]` table, e.g. a
future `[personal.bitwarden]`): add the table to `.chezmoidata.toml` with an
`active = true` key, then create `.scripts/personal/<app>/configure.sh.tmpl`.
No changes to `run_after_20_configure_personal.sh.tmpl` are needed — it Go-
template `range`s over `.personal`, and for every app whose table has
`active = true` it renders `.scripts/personal/<app>/configure.sh.tmpl`
through `chezmoi execute-template` and runs it (same rendering approach as
the GUI dispatcher, but with no `$1` — per-app scripts read their own
settings straight out of `.personal.<app>` via `{{ index .personal "<app>"
... }}`). Because the dispatcher already filters on `active`, the per-app
script doesn't need to (and shouldn't bother) re-checking it — sub-features
within a script (like Zen's `extensions` table) can still have their own
finer-grained checks. As its first real statement the script must instead
gate on the target app actually being present (`command -v <app>` or
equivalent — `flatpak info <app-id>` for a Flatpak-installed app, since a
Flatpak may not export a plain binary name onto `$PATH`), then `exit 0` if
it's not — that's what makes `[personal]` entries safe to leave declared
even on machines that don't install that app (headless boxes, or the app
commented out of `[gui_apps]`/`[system_tools]`). Follow
`.scripts/personal/zen/configure.sh.tmpl` as the reference implementation —
co-locate any non-script assets it needs (e.g. its `user.js`) in the same
`.scripts/personal/<app>/` directory.

**Machine-local shell settings** (untracked, one-machine-only tweaks: a work
proxy, an extra `PATH` entry, a host-specific alias) go in `~/.zshrc.local`
on that machine, not in this repo. `dot_zshrc` sources it as its very last
statement, only if it's readable, so it overrides anything shared. chezmoi
never owns it — there's no source file for it, there's no `exact_` on
`$HOME`, and `.chezmoiignore` lists it so even `chezmoi add ~/.zshrc.local`
is a no-op (keep it that way; `tests/check_managed.sh` and the integration
test assert it). Keep that hook last in `dot_zshrc`: anything added after it
can't be overridden locally. Settings the shared `.zshrc` consumes during
startup (e.g. `ZELLIJ_AUTO_ATTACH` for Zellij's auto-start) are too late
there and belong in the also-unmanaged `~/.zshenv`. This is deliberately a
different mechanism from `[personal]`/`requires`: those are declarative,
tracked in git, and apply on every machine they match; `~/.zshrc.local` is
the untracked escape hatch. A tweak that shows up on several machines, or
one that a whole machine class needs, belongs in the repo instead.

## Chezmoi file-naming conventions in this repo

- `dot_zshrc` → deploys to `~/.zshrc`.
- `private_dot_config/...` → deploys to `~/.config/...` with private
  (0600-ish) permissions.
- `private_dot_local/bin/executable_md-preview` → deploys to
  `~/.local/bin/md-preview` and is marked executable.
- `run_onchange_before_NN_*.sh.tmpl` / `run_onchange_after_NN_*.sh.tmpl` —
  Go-templated scripts chezmoi runs on `apply` when their rendered content
  changes; `before`/`after` controls ordering relative to file deployment,
  `NN` controls ordering within that phase.
- Files/dirs under `.scripts/` and `.chezmoidata.toml` itself are **not**
  deployed to `$HOME` — they're chezmoi source-state helpers (leading `.`
  keeps them out of the target tree; `.chezmoiignore` additionally excludes
  `.config/helix/runtime/` and `.oh-my-zsh/` from being managed even though
  they live under a chezmoi-managed directory).

When editing templates, remember `.chezmoi.sourceDir` inside a template
refers to this repo's path on the target machine (used in
`run_onchange_before_03_install_gui_apps.sh.tmpl` to locate GUI scripts at
render time).

## Useful local commands

- `chezmoi diff` — preview what `apply` would change against `$HOME`, without
  touching anything.
- `chezmoi apply -v` — apply the source state, verbose.
- `chezmoi execute-template < path/to/file.tmpl` — render a single template
  standalone (useful for checking Go-template syntax without a full apply).
- `shfmt -w -i 4 <script>` — format shell scripts (shfmt is itself declared
  as a `system_tools` dependency, and is the formatter of record for this
  repo's plain `.sh` scripts — CI enforces it. It can't parse `.sh.tmpl`
  files; those are shellchecked after rendering instead).
- `tests/run.sh <lint|invariants|render|integration|all>` — the CI test
  suite, locally (see [Testing / CI](#testing--ci)).
- `czap` (zsh function defined in `dot_zshrc`) — on a machine with this repo
  applied, runs `chezmoi apply` and reloads the shell.
- `czup` (same file) — upgrades mise tools and the rust toolchain, then
  reloads the shell.

## Testing / CI

`.github/workflows/ci.yml` runs the suite in `tests/` on every PR; all of
its logic lives in `tests/` so it runs the same locally via `tests/run.sh`
(podman or docker; never touches `~/.config/chezmoi` or `$HOME` — host-side
chezmoi calls use a throwaway config/state, and applies happen only in
disposable containers). Branch protection requires the single **`ci-gate`**
check, which passes only when every required job passed:

- **lint** — shellcheck (`--severity=style`) + `shfmt -d -i 4` on every plain
  shell script, `zsh -n dot_zshrc`, TOML parse.
- **invariants** — `tests/check_invariants.py`: rules the dispatchers rely
  on but don't enforce (every `profiles = [...]` names a `[profiles]` key;
  the hardcoded profile lists in `entry-in-profile` and `.chezmoi.toml.tmpl`
  match `[profiles]`; per-distro `[system_tools]` tables cover
  fedora/ubuntu/debian; every installer script exists and every script maps
  to an entry; `[user_tools]` bins are unique and don't collide with
  `[system_tools]`; `npm:`/`pipx:`/`cargo:` tools only appear on profiles
  that also get node/uv/rust; `requires` names a real machine-local key;
  ...). Plus `tests/check_managed.sh`: `chezmoi managed` never includes
  repo-only files (README/CLAUDE/LICENSE, `tests/`, `.github/`) or
  `~/.zshrc.local`.
- **render (fedora/ubuntu/debian)** — inside each distro's container, render
  every `*.tmpl` for each profile × laptop answer (`.chezmoi.toml.tmpl` via
  `execute-template --init`), `bash -n` + shellcheck (`--severity=warning`)
  the rendered shell, then `tests/check_rendered.py` re-derives from the
  data what each tier should do and checks the rendered dispatchers agree
  (incl. mise `[tools]` == the `MISE_TOOLS` collision array). Also checks
  every package the rendered `$PKG_MANAGER` lines would install (system
  tools + native GUI apps) resolves in that distro's repos.
- **integration (<distro>, minimal)** — real `chezmoi init --apply` via
  the README bootstrap, as a non-root user **without sudo**, then a second
  apply + `chezmoi verify`, `mise ls --missing`, and an interactive zsh
  (on a pty) that must print nothing to stderr; then it drops a
  `~/.zshrc.local` and asserts it's sourced after the shared `.zshrc` (its
  `EDITOR` wins), still nothing on stderr, and that `chezmoi apply`/`add`
  leave it alone.

`integration (<distro>, headless|standard)` runs the same with passwordless
sudo on PRs, weekly and on demand, but is `continue-on-error` and not part
of `ci-gate`: it depends on the latest upstream release of many tools.
The containers have no systemd, so a logging no-op `systemctl` stands in.
The minimal integration *is* gating even though it also installs
`latest` mise tools (a dozen or so small prebuilt binaries), so an upstream
release can break it with no repo change -- an accepted tradeoff for
testing the profile that must work unattended. What is pinned: GitHub
actions and distro images by tag, the CI's chezmoi/shellcheck/shfmt
binaries by version + sha256 (`tests/lib/common.sh`); installer scripts
(`get.chezmoi.io`, `mise.run`, rustup, ...) are fetched live.

When adding a tier, data key or template, extend the matching check in
`tests/` rather than relying on a manual apply. Gotcha:
`chezmoi init/execute-template --promptBool/--promptChoice` are keyed by the
prompt *text*, not the data key, so the tests read the prompt texts out of
`.chezmoi.toml.tmpl` (and assert the rendered answers) rather than
hardcoding them. Arch isn't tested: the dispatchers have an arch branch, but
the per-distro `[system_tools]` maps have no arch entries, so it fails
loudly by design.

## Editor/tooling notes relevant to config changes

- Helix (`private_dot_config/helix/languages.toml`) runs basedpyright + ruff
  for Python (dual language servers, ruff for lint/format), prettier for
  markdown, and expects `auto-format = true` for c/cpp/rust/markdown.
- Zellij is the terminal multiplexer; Ghostty's config
  (`private_dot_config/ghostty/config`) deliberately unbinds its own
  tab/split/window shortcuts so they don't conflict with Zellij's.
- Tab completion UI is fzf-tab (Sheldon plugin, listed first in
  `private_dot_config/sheldon/plugins.toml` so it loads before widget-wrapping
  plugins). Completion colors come from `LS_COLORS` (the same source eza
  uses; `dot_zshrc` generates it via `dircolors` where the distro doesn't),
  and the `_eza_flags` array is shared between the `eza` alias and fzf-tab's
  directory preview — change eza flags there, not in two places. History
  Up/`k` search is Atuin's binding; don't rebind those keys after
  `atuin init`.
- `SSH_AUTH_SOCK` in `dot_zshrc` points at Bitwarden's SSH agent whichever
  way Bitwarden was installed: it checks the three socket paths Bitwarden
  documents (Flatpak `~/.var/app/com.bitwarden.desktop/data/`, Snap
  `~/snap/bitwarden/<rev>/`, native `~/`, each `.bitwarden-ssh-agent.sock`)
  and uses the newest one that's actually a socket. It's left unset when
  none exists, and the whole block is skipped inside SSH sessions so `ssh -A`
  forwarding wins. A machine that wants a different agent can override
  `SSH_AUTH_SOCK` in `~/.zshrc.local`.
