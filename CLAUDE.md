# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

`dotProd` is a declarative dotfiles / machine-bootstrapping system built on
[chezmoi](https://www.chezmoi.io/) and [mise](https://mise.jdx.dev/). It takes a
blank Linux machine to a fully configured dev environment. It is **not an
application** — there is no build, test, or lint suite to run. Changes are
validated by applying them with chezmoi (dry-run) and reasoning about the
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
   pipx, uv, and GitHub-release backends). The key is the mise package
   spec (e.g. `"cargo:ripgrep"`, `"pipx:ruff"`), the value is the resulting
   binary name, used only for the collision check. Actually installed by
   `run_onchange_after_10_install_mise_tools.sh.tmpl` (`mise install -y`),
   after `private_dot_config/mise/config.toml.tmpl` has rendered the `[tools]`
   table from this same data.
4. **`[gui_apps]`** — desktop apps, installed via Flatpak by default, or a
   custom script if one exists, or natively via `apt`/`dnf`/`pacman` if the
   entry is a table with `native = true` (e.g. `firefox = { native = true }`).
   Installed by `run_onchange_before_03_install_gui_apps.sh.tmpl`, gated on a
   display server (`$WAYLAND_DISPLAY`/`$DISPLAY`) being present — this gate
   applies to native entries too, so an app marked `native = true` is still
   skipped entirely on headless machines/SSH sessions.
5. **`[personal]`** — opinionated, per-machine opt-in settings tied to a
   specific app (e.g. `firefox_prefs`, `firefox_extensions`). Not part of the
   install dispatcher above; applied by a plain
   `run_after_NN_configure_<app>.sh.tmpl` script (e.g.
   `run_after_20_configure_firefox.sh.tmpl`) that reruns on *every* `chezmoi
   apply` (deliberately `run_after_`, not `run_onchange_after_`, so it also
   picks up state that changes outside `.chezmoidata.toml`, like a
   newly-created browser profile). **Every such script must gate on the
   target app's presence** (`command -v <app>` or equivalent) as its first
   real statement, before touching any `[personal]` data — this keeps
   `[personal]` settings a safe no-op on machines where that app was never
   installed (headless, commented out of `[gui_apps]`/`[system_tools]`,
   etc.), rather than erroring or writing config for software that isn't
   there. See `run_after_20_configure_firefox.sh.tmpl` for the reference
   implementation of this pattern.

`run_after_90_integrations.sh` runs last and handles cross-tool glue that
doesn't fit the tiered model (currently: symlinking the system LLDB debug
adapter to `~/.local/bin/lldb-dap` for Helix).

### Execution order

Chezmoi runs scripts in lexical order of their `run_*` prefix
(`before_01` → `before_02` → `before_03` → `after_10` → `after_20` →
`after_90`), so system packages exist before toolchains, toolchains before
mise, mise before GUI apps, and everything before the personalization and
final integrations passes. `onchange` scripts are hashed by chezmoi and only
re-run when their content (or, for the mise script, the `Hash: {{
.user_tools | toJson | sha256sum }}` comment) changes — `after_20`-style
`[personal]` scripts are plain `run_after_` (not `run_onchange_after_`) and
so always re-run, relying on their own idempotency/gating instead.

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
section of `.chezmoidata.toml`. No script needed.

**Complex package** (custom repo/PPA, `curl | sh` install, pre-install
cleanup): add the entry to `.chezmoidata.toml`, then create a script named
exactly after the TOML key:

| Tier | Script path |
|---|---|
| `system_tools` | `.scripts/daemons/<tool>.sh` |
| `external_user_tools`, kind = `toolchains` | `.scripts/toolchains/<tool>.sh` |
| `external_user_tools`, kind = `standalone` | `.scripts/standalone/<tool>.sh` |
| `gui_apps` | `.scripts/gui/<app>.sh` or `.scripts/gui/<app>.sh.tmpl` |

The dispatcher passes the TOML value to the script as `$1`. GUI scripts may
be `.tmpl` files (rendered through `chezmoi execute-template` before
execution) if they need OS conditionals — see `.scripts/gui/ghostty.sh.tmpl`
for the pattern (checks `.chezmoi.osRelease.id` for ubuntu/debian vs fedora).
Every script should be idempotent: check `command -v <tool>` (or equivalent)
before doing work, and `set -euo pipefail` at the top.

**Personal, app-linked settings** (a new key under `[personal]`, e.g. a
future `bitwarden_prefs`): create `run_after_NN_configure_<app>.sh.tmpl`
(pick `NN` after `10`/before `90`; `20` is taken by firefox). As its first
real statement — before any `{{ if index .personal ... }}` template logic —
the script must gate on the target app actually being present (`command -v
<app>` or equivalent), then `exit 0` if it's not. This is what makes
`[personal]` entries safe to leave declared even on machines that don't
install that app (headless boxes, or the app commented out of
`[gui_apps]`/`[system_tools]`). Follow
`run_after_20_configure_firefox.sh.tmpl` as the reference implementation.

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
  as a `system_tools` dependency; recent history shows it's the formatter of
  record for this repo's `.sh`/`.sh.tmpl` files).
- `czap` (zsh function defined in `dot_zshrc`) — on a machine with this repo
  applied, runs `chezmoi apply` and reloads the shell.
- `czup` (same file) — upgrades mise tools and the rust toolchain, then
  reloads the shell.

## Editor/tooling notes relevant to config changes

- Helix (`private_dot_config/helix/languages.toml`) runs basedpyright + ruff
  for Python (dual language servers, ruff for lint/format), prettier for
  markdown, and expects `auto-format = true` for c/cpp/rust/markdown.
- Zellij is the terminal multiplexer; Ghostty's config
  (`private_dot_config/ghostty/config`) deliberately unbinds its own
  tab/split/window shortcuts so they don't conflict with Zellij's.
- SSH agent socket in `dot_zshrc` currently points at the Bitwarden Flatpak
  path (`~/.var/app/com.bitwarden.desktop/...`); there are commented-out
  alternates for the Snap path if that ever needs to change back.
