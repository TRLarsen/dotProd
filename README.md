# dotProd

The dot product of two excellent config management solutions (`chezmoi` and
`mise`), plus a little extra scripting secret sauce; dotProd takes new Linux
machines from blank slates to Prod-ready.

> [!NOTE]
>
> Large Language Models (Gemini and Claude) have been used extensively
> throughout this project (including to write the below README). I have read
> through all scripts/code, made edits where appropriate, and designed and
> guided the system from a high level. I actively use this system.

# Declarative Dotfiles

A fully modular, idempotent, and OS-aware system bootstrapping engine.

This repository manages system configuration and environment bootstrapping using
[Chezmoi](https://www.chezmoi.io/) and [Mise](https://mise.jdx.dev/). Rather
than relying on a brittle, monolithic bash script, this setup uses a
**Data-Driven Dispatcher** architecture. State is declared strictly in a TOML
file, and execution is handled by isolated, universally portable template
scripts.

## 🏗️ Architecture

The system is separated into four distinct install domains (to prevent
permissions conflicts, `$PATH` collisions, and cross-platform breakages),
plus one opt-in personalization layer applied after everything else installs.

1. **System Layer (`[system_tools]`):** \* Handled by the native OS package
   manager (APT, DNF, Pacman).
   - Requires `sudo`. Used strictly for kernel-level daemons (Tailscale),
     foundational packages (`curl`, `git`), and system-wide configurations.
2. **Toolchain Layer (`[toolchains]`):** \* Handled by custom isolated scripts
   (e.g., `rustup`).
   - Bootstraps foundational compilers and runtimes into user-space _before_ CLI
     applications are built.
3. **User-Space Layer (`[user_tools]`):** \* Handled concurrently by `mise`.
   - Deploys CLI utilities (Zellij, Helix, Ripgrep) directly to
     `~/.local/share/mise/` without requiring root access, ensuring total
     environment isolation.
4. **Desktop/GUI Layer (`[gui_apps]`):** \* Handled primarily via Flatpak to
   prevent "Double Icon Syndrome" and OS-level package conflicts, with fallbacks
   for custom install scripts (e.g., Ghostty's official installer) and an
   explicit opt-in to native (`apt`/`dnf`/`pacman`) installs via `{ native = true }`
   for packages unavailable as a Flatpak.
5. **Personal Layer (`[personal]`):** \* Opt-in, per-machine settings,
   namespaced per app (e.g. `[personal.zen]` for preferences/extensions).
   - Applied by a single generic `run_after_20_configure_personal.sh.tmpl`
     dispatcher that reruns on every apply. Each app opts in with
     `active = true`; the dispatcher checks that flag itself and only runs
     `.scripts/personal/<app>/configure.sh.tmpl` for apps where it's true,
     so a script can't accidentally run just because it forgot to check.
     Each per-app script additionally gates on the target app actually
     being installed, so these settings are a safe no-op on machines that
     don't have that app.

## 🎚️ Install Profiles

Every machine also picks an install **profile** at `chezmoi init` time:
`standard` (owned desktop, full GUI, no constraints), `headless` (owned
server, no display, sudo available, full dev toolchain), or `minimal`
(resource-constrained and/or shared with others — must work with **no
sudo**). A `[profiles]` capability table in `.chezmoidata.toml` declares what
each profile can do (`sudo`, `gui`), and the System/GUI layers above check it
generically — adding a fourth profile later is a pure data change, no
dispatcher edits. Individual tool entries in any layer can further restrict
themselves to a subset of profiles with a `profiles = [...]` key; omitting it
means "available everywhere the layer's capability allows," so adding a
standard tool stays a one-line change.

## ⚙️ The Execution Pipeline

Chezmoi executes the bootstrapping pipeline in a strict numerical sequence,
guaranteeing dependencies are available exactly when needed. The scripts below
are all prefixed by `run_[onchange_before/after]` and suffixed by `.sh[.tmpl]`.

- **`01_install_system_tools`**: Dynamically detects the host OS, updates native
  package lists, and provisions root-level dependencies.
- **`02_install_user_tools`**: Installs compiler toolchains, bootstraps `mise`,
  and provisions all user-space CLI tools concurrently. Before install, this
  script runs a pre-flight collision detection scan. If legacy binaries (e.g.,
  an `apt` installed version of a tool `mise` is trying to manage) are found in
  the `$PATH`, the pipeline halts to prevent environment corruption.
- **`03_install_gui_apps`**: Detects if a display server (Wayland/X11) is
  active. If true, configures Flathub and provisions desktop applications
  (via Flatpak, a custom script, or natively via the OS package manager for
  `{ native = true }` entries).
- **`20_configure_personal`**: (Run-After Phase) Generic dispatcher for the
  `[personal]` layer — discovers and runs every
  `.scripts/personal/<app>/configure.sh.tmpl` on disk (e.g. Zen's local
  prefs + enterprise-policy extensions), each gated on its target app
  actually being installed. Reruns every apply, unlike the `run_onchange_`
  install scripts above.
- **`90_integrations`**: (Run-After Phase) Executes glue logic, such as
  symlinking system-installed debuggers (LLDB) into the user paths expected by
  terminal editors. This script is currently not standardized and must be
  completely custom.

## 🛠️ Configuration (`.chezmoidata.toml`)

The entire state of the machine is driven by
`~/.local/share/chezmoi/.chezmoidata.toml`. **You should rarely need to edit the
bash templates.** To modify the system, simply update the TOML data:

```toml
[system_tools]
tailscale = "latest"
docker = "latest"

[toolchains]
rust = "stable"

[user_tools]
"cargo:zellij" = "zellij"
helix = "hx"
gh = "gh"

[gui_apps]
zen = "app.zen_browser.zen"  # flatpak app ID, installed via Flathub
ghostty = "custom_script"  # value unused; installed via .scripts/gui/ghostty.sh.tmpl
```

## 🚀 How to Extend the System

### 1. Adding a Standard Package

If a tool just needs a standard `apt install` or a `mise` binary pull, simply
add it to the appropriate section in `.chezmoidata.toml`. The dispatcher will
handle it automatically, and it's available on every install profile by
default — add a `profiles = [...]` key only if it should be restricted (see
[Install Profiles](#-install-profiles)).

### 2. Adding a Complex Package

If a system tool or GUI app requires a custom PPA, a custom `curl | sh`
execution, or pre-installation cleanup:

1. Add the tool to `.chezmoidata.toml`.
2. Create an isolated bash script matching the tool's exact name in the hidden
   `.scripts` directory:
   - **System Tools:** `~/.local/share/chezmoi/.scripts/daemons/<tool_name>.sh`
   - **Toolchains:** `~/.local/share/chezmoi/.scripts/toolchains/<tool_name>.sh`
   - **GUI Apps:** `~/.local/share/chezmoi/.scripts/gui/<tool_name>.sh`

The dispatcher will automatically detect the script, execute it, and pass the
TOML value to it as `$1`.

### 3. Adding a Personal, App-Linked Setting

Opt-in per-machine customizations (e.g. Zen prefs) live under
`[personal.<app>]` in `.chezmoidata.toml`, gated by an `active = true` key,
and are applied by their own script at
`~/.local/share/chezmoi/.scripts/personal/<app>/configure.sh.tmpl`. Unlike
the tiers above, there's a single generic `run_after_20_configure_personal.sh.tmpl`
dispatcher — it loops over every `[personal.<app>]` table, and for each one
where `active` is `true` it runs that app's `configure.sh.tmpl`, so adding a
new app needs no changes to the dispatcher itself. The `active` check lives
in the dispatcher, not the script, so setting it to `false` reliably turns
an app's customization off. A table can also set `profiles = [...]` (see
[Install Profiles](#-install-profiles)) to restrict itself to a subset of
install profiles — useful for settings tied to a GUI app. Each script reads
its own settings straight out of `.personal.<app>` and must still gate on
the target app actually being installed before doing anything else. See
`.scripts/personal/zen/configure.sh.tmpl` for the reference implementation.

## 💻 Installation

To bootstrap a new machine from this repository:

```bash
sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin" init --apply trlarsen/dotProd
```
