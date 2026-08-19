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
   for custom PPAs (e.g., Ghostty) and an explicit opt-in to native
   (apt/dnf/pacman) installs via `{ native = true }` (e.g., Firefox).
5. **Personal Layer (`[personal]`):** \* Opt-in, per-machine settings tied to
   a specific app (e.g. Firefox preferences/extensions).
   - Applied by a `run_after_NN_configure_<app>.sh.tmpl` script that reruns
     on every apply and always gates on the target app actually being
     installed first, so these settings are a safe no-op on machines that
     don't have that app.

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
- **`20_configure_firefox`**: (Run-After Phase) Applies `[personal]`
  Firefox settings (Betterfox prefs + enterprise-policy extensions), gated
  on Firefox actually being installed. Reruns every apply, unlike the
  `run_onchange_` install scripts above.
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
firefox = { native = true }  # installed via apt/dnf/pacman, package name = "firefox"
ghostty = "ppa:mkasberg/ghostty-ubuntu"
```

## 🚀 How to Extend the System

### 1. Adding a Standard Package

If a tool just needs a standard `apt install` or a `mise` binary pull, simply
add it to the appropriate section in `.chezmoidata.toml`. The dispatcher will
handle it automatically.

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

## 💻 Installation

To bootstrap a new machine from this repository:

```bash
sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin" init --apply trlarsen/dotProd
```
