"""Semantic checks on the templates rendered by tests/container/render.sh.

Usage: check_rendered.py <repo-root> <distro> <rendered-dir>

<rendered-dir> holds one sub-directory per "<profile>-laptop_<bool>" case.
For each case this re-derives, straight from .chezmoidata.toml, what every
install tier *should* do on that profile/distro, and checks the rendered
dispatcher scripts agree. In particular it pins down the cross-file
contract CLAUDE.md calls out: the [tools] table in the rendered mise config
and the MISE_TOOLS collision-check array must list the same tools.
"""

import re
import sys
import tomllib
from pathlib import Path

repo, distro, rendered = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
data = tomllib.loads((repo / ".chezmoidata.toml").read_text())
SOURCE_DIR = "/src"  # where the container mounts the repo (.chezmoi.sourceDir)

errors: list[str] = []


def check(cond: bool, msg: str) -> None:
    if not cond:
        errors.append(msg)


def in_profile(entry, profile: str) -> bool:
    """Python mirror of .chezmoitemplates/entry-in-profile."""
    if isinstance(entry, dict) and "profiles" in entry:
        return profile in entry["profiles"]
    return profile in data["profiles"]


def contains_line(text: str, line: str) -> bool:
    return any(l.strip() == line for l in text.splitlines())


cases = sorted(p for p in rendered.iterdir() if p.is_dir())
check(len(cases) == 3 * 2, f"expected 6 profile x laptop cases, found {[c.name for c in cases]}")

for case in cases:
    m = re.fullmatch(r"(\w+)-laptop_(true|false)", case.name)
    if not m:
        errors.append(f"unexpected case directory {case}")
        continue
    profile, laptop = m.group(1), m.group(2) == "true"
    caps = data["profiles"][profile]
    where = f"[{distro}/{profile}/laptop={str(laptop).lower()}]"

    def read(rel: str) -> str:
        return (case / rel).read_text()

    # --- .chezmoi.toml.tmpl -> machine-local config
    cfg = tomllib.loads(read("chezmoi.toml"))
    check(cfg.get("data") == {"laptop": laptop, "profile": profile},
          f"{where} rendered chezmoi config data is {cfg.get('data')}")

    # --- [user_tools]: mise config [tools] vs. MISE_TOOLS collision array
    expected_tools = {
        pkg: (cfg_.get("version", "latest") if isinstance(cfg_, dict) else "latest")
        for pkg, cfg_ in data["user_tools"].items()
        if in_profile(cfg_, profile)
    }
    expected_bins = sorted(
        cfg_["bin"] if isinstance(cfg_, dict) else cfg_
        for pkg, cfg_ in data["user_tools"].items()
        if in_profile(cfg_, profile)
    )
    mise = tomllib.loads(read("private_dot_config/mise/config.toml"))
    check(mise.get("tools") == expected_tools,
          f"{where} mise [tools] mismatch:\n  got      {sorted(mise.get('tools', {}))}\n  expected {sorted(expected_tools)}")
    check(mise.get("settings", {}).get("pipx", {}).get("uvx") is True,
          f"{where} mise config lost pipx.uvx = true")

    user = read("run_onchange_before_02_install_user_tools.sh")
    arr = re.search(r"^MISE_TOOLS=\((.*?)^\)", user, re.S | re.M)
    if not arr:
        errors.append(f"{where} no MISE_TOOLS=( ... ) array in rendered 02 script")
    else:
        got_bins = sorted(re.findall(r'"([^"]+)"', arr.group(1)))
        check(got_bins == expected_bins,
              f"{where} MISE_TOOLS collision array mismatch:\n  got      {got_bins}\n  expected {expected_bins}")

    # --- [external_user_tools]
    for tool, ext in data["external_user_tools"].items():
        script = f'SCRIPT_PATH="{SOURCE_DIR}/.scripts/{ext["kind"]}/{tool}.sh"'
        if in_profile(ext, profile):
            check(contains_line(user, script), f"{where} 02 does not install {tool} via {script}")
            check(f'bash "$SCRIPT_PATH" "{ext["version"]}"' in user,
                  f"{where} 02 does not pass version {ext['version']!r} to {tool}")
        else:
            check(script not in user, f"{where} 02 installs {tool}, which is excluded from {profile}")
            check(f"Skipping {tool} (not in profile" in user, f"{where} 02 does not report skipping {tool}")

    # --- [system_tools]
    system = read("run_onchange_before_01_install_system_tools.sh")
    if not caps["sudo"]:
        check("Skipping system_tools tier entirely" in system,
              f"{where} 01 should skip the whole tier (profile has no sudo)")
        check(not re.search(r"^\s*(sudo |\$PKG_MANAGER)", system, re.M),
              f"{where} 01 runs sudo/$PKG_MANAGER on a no-sudo profile")
    else:
        for tool, entry in data["system_tools"].items():
            if not in_profile(entry, profile):
                check(f"Skipping {tool} (not in profile" in system, f"{where} 01 does not skip {tool}")
                continue
            if isinstance(entry, dict) and "version" not in entry:
                pkg, version = entry[distro]["name"], entry[distro]["version"]
            else:
                pkg, version = tool, (entry["version"] if isinstance(entry, dict) else entry)
            daemon = repo / ".scripts" / "daemons" / f"{tool}.sh"
            if daemon.exists():
                check(contains_line(system, f'bash "{SOURCE_DIR}/.scripts/daemons/{tool}.sh" "{version}"'),
                      f"{where} 01 does not run the daemon script for {tool}")
            else:
                check(contains_line(system, f'$PKG_MANAGER "{pkg}"'),
                      f"{where} 01 does not install package {pkg!r} for {tool}")

    # --- [gui_apps]
    gui = read("run_onchange_before_03_install_gui_apps.sh")
    if not caps["gui"]:
        check("Skipping gui_apps tier entirely" in gui, f"{where} 03 should skip the whole tier (no gui)")
    else:
        check("No display server detected" in gui, f"{where} 03 lost its display-server gate")
        for app, ident in data["gui_apps"].items():
            if in_profile(ident, profile):
                check(f'SCRIPT_PATH="{SOURCE_DIR}/.scripts/gui/{app}.sh.tmpl"' in gui,
                      f"{where} 03 does not handle {app}")

    # Nested renders must call the running chezmoi binary, not whatever
    # `chezmoi` is on PATH: after README's bootstrap ~/.local/bin usually
    # isn't on PATH yet.
    for rel in ("run_onchange_before_03_install_gui_apps.sh", "run_after_20_configure_personal.sh"):
        check(not re.search(r"^\s*chezmoi ", read(rel), re.M),
              f"{where} {rel} calls a bare `chezmoi` (use {{{{ .chezmoi.executable }}}})")

    # --- [personal] dispatcher
    personal = read("run_after_20_configure_personal.sh")
    for app, settings in data.get("personal", {}).items():
        script = f'SCRIPT_PATH="{SOURCE_DIR}/.scripts/personal/{app}/configure.sh.tmpl"'
        runs = contains_line(personal, script)
        if not (isinstance(settings, dict) and settings.get("active")):
            check(not runs, f"{where} 20 runs inactive personal app {app}")
        elif not in_profile(settings, profile):
            check(not runs and f"Skipping {app} (not available on profile" in personal,
                  f"{where} 20 should skip {app} on profile {profile}")
        elif "requires" in settings and not cfg["data"].get(settings["requires"]):
            check(not runs and f"Skipping {app} (requires = {settings['requires']}" in personal,
                  f"{where} 20 should skip {app} (requires = {settings['requires']})")
        else:
            check(runs, f"{where} 20 should run {app}'s configure script")

if errors:
    print(f"{len(errors)} rendered-output check(s) failed on {distro}:", file=sys.stderr)
    for e in errors:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(1)
print(f"rendered-output checks OK on {distro} ({len(cases)} cases)")
