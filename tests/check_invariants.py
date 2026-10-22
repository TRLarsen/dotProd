"""Data invariants for .chezmoidata.toml and the files it refers to.

Usage: check_invariants.py [repo-root]

Each check encodes a rule from CLAUDE.md/README.md that the dispatcher
templates rely on but don't (or can't cheaply) enforce themselves -- most
of these would otherwise only surface as a failed `chezmoi apply`, or worse,
as something silently skipped, on one particular profile/distro.
"""

import re
import sys
import tomllib
from pathlib import Path

REPO = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent)
DATA = tomllib.loads((REPO / ".chezmoidata.toml").read_text())
SCRIPTS = REPO / ".scripts"
# Distros the per-distro [system_tools] maps must cover (the ones CI renders
# and applies on). Arch is unsupported on purpose -- see tests/lib/common.sh.
DISTROS = ("fedora", "ubuntu", "debian")

errors: list[str] = []
checks = 0


def check(cond: bool, msg: str) -> None:
    global checks
    checks += 1
    if not cond:
        errors.append(msg)


PROFILES = DATA.get("profiles", {})
PROFILE_NAMES = set(PROFILES)


def entry_profiles(entry) -> set[str]:
    """Profiles an entry is available on (mirror of entry-in-profile)."""
    if isinstance(entry, dict) and "profiles" in entry:
        return set(entry["profiles"])
    return set(PROFILE_NAMES)


def check_profiles_key(where: str, entry) -> None:
    if isinstance(entry, dict) and "profiles" in entry:
        p = entry["profiles"]
        check(isinstance(p, list) and len(p) > 0 and all(isinstance(x, str) for x in p),
              f"{where}: `profiles` must be a non-empty list of strings, got {p!r}")
        if isinstance(p, list):
            unknown = sorted(set(p) - PROFILE_NAMES)
            check(not unknown, f"{where}: `profiles` names unknown profile(s) {unknown} (known: {sorted(PROFILE_NAMES)})")
            check(len(p) == len(set(p)), f"{where}: `profiles` has duplicates: {p}")


# --- [profiles] capability table ---------------------------------------------
check(len(PROFILES) > 0, "[profiles] is empty")
for name, caps in PROFILES.items():
    check(isinstance(caps, dict) and set(caps) == {"sudo", "gui"}
          and all(isinstance(v, bool) for v in caps.values()),
          f"[profiles.{name}] must have exactly boolean `sudo` and `gui` keys, got {caps!r}")
    if isinstance(caps, dict) and caps.get("gui") and not caps.get("sudo"):
        # GUI installs run `sudo flatpak ...`; a gui-without-sudo profile would fail at apply time.
        errors.append(f"[profiles.{name}] has gui = true but sudo = false; the gui_apps tier needs sudo")

# The profile list is also hardcoded in two templates; both must match [profiles].
partial = (REPO / ".chezmoitemplates" / "entry-in-profile").read_text()
m = re.search(r'\$allowed\s*:=\s*list((?:\s+"[^"]+")+)', partial)
check(m is not None, ".chezmoitemplates/entry-in-profile: could not find the `$allowed := list ...` default")
if m:
    allowed = re.findall(r'"([^"]+)"', m.group(1))
    check(set(allowed) == PROFILE_NAMES,
          f".chezmoitemplates/entry-in-profile default list {allowed} != [profiles] keys {sorted(PROFILE_NAMES)}")

config_tmpl = (REPO / ".chezmoi.toml.tmpl").read_text()
m = re.search(r'promptChoiceOnce\s+\.\s+"profile"\s+"[^"]*"\s+\(list((?:\s+"[^"]+")+)\)\s+"([^"]+)"', config_tmpl)
check(m is not None, ".chezmoi.toml.tmpl: could not find the `profile` promptChoiceOnce")
if m:
    choices, default = re.findall(r'"([^"]+)"', m.group(1)), m.group(2)
    check(set(choices) == PROFILE_NAMES,
          f".chezmoi.toml.tmpl profile choices {choices} != [profiles] keys {sorted(PROFILE_NAMES)}")
    check(default in choices, f".chezmoi.toml.tmpl profile default {default!r} is not one of its choices")

# Machine-local data keys .chezmoi.toml.tmpl writes under [data] (for `requires`).
data_block = config_tmpl.split("[data]", 1)[1] if "[data]" in config_tmpl else ""
MACHINE_KEYS = set(re.findall(r"^\s*(\w+)\s*=", data_block, re.M))
check("profile" in MACHINE_KEYS and "laptop" in MACHINE_KEYS,
      f".chezmoi.toml.tmpl [data] should define laptop and profile, found {sorted(MACHINE_KEYS)}")

# --- [system_tools] ----------------------------------------------------------
SYSTEM_KEYS = {"version", "profiles"}
system_pkg_names: set[str] = set()
for tool, entry in DATA.get("system_tools", {}).items():
    where = f"[system_tools].{tool}"
    check_profiles_key(where, entry)
    if isinstance(entry, str):
        system_pkg_names.add(tool)
        continue
    if not isinstance(entry, dict):
        errors.append(f"{where}: must be a version string or a table, got {entry!r}")
        continue
    distro_keys = set(entry) - SYSTEM_KEYS
    if "version" in entry:
        # The dispatcher ignores per-distro tables whenever `version` is set.
        check(not distro_keys, f"{where}: has both `version` and per-distro keys {sorted(distro_keys)}; "
                               "the per-distro names would be silently ignored")
        check(isinstance(entry["version"], str), f"{where}: `version` must be a string")
        system_pkg_names.add(tool)
    else:
        missing = [d for d in DISTROS if d not in entry]
        check(not missing, f"{where}: per-distro table is missing {missing}; "
                           "`chezmoi apply` fails on those distros")
        for d in distro_keys:
            osent = entry[d]
            ok = isinstance(osent, dict) and set(osent) == {"name", "version"} \
                and all(isinstance(v, str) and v for v in osent.values())
            check(ok, f"{where}.{d}: must be exactly {{ name = \"...\", version = \"...\" }}, got {osent!r}")
            if ok:
                system_pkg_names.add(osent["name"])
for script in sorted((SCRIPTS / "daemons").glob("*")):
    check(script.suffix == ".sh" and script.stem in DATA.get("system_tools", {}),
          f".scripts/daemons/{script.name}: no matching [system_tools] key (dispatcher only runs <key>.sh)")

# --- [external_user_tools] ---------------------------------------------------
EXT_KINDS = {"toolchains", "standalone"}
for tool, entry in DATA.get("external_user_tools", {}).items():
    where = f"[external_user_tools].{tool}"
    check_profiles_key(where, entry)
    if not isinstance(entry, dict):
        errors.append(f"{where}: must be a table {{ version = ..., kind = ... }}, got {entry!r}")
        continue
    check(set(entry) <= {"version", "kind", "profiles"}, f"{where}: unknown keys {sorted(set(entry) - {'version', 'kind', 'profiles'})}")
    check(isinstance(entry.get("version"), str), f"{where}: missing string `version`")
    kind = entry.get("kind")
    check(kind in EXT_KINDS, f"{where}: `kind` must be one of {sorted(EXT_KINDS)}, got {kind!r}")
    if kind in EXT_KINDS:
        check((SCRIPTS / kind / f"{tool}.sh").is_file(), f"{where}: missing installer .scripts/{kind}/{tool}.sh")
for kind in EXT_KINDS:
    for script in sorted((SCRIPTS / kind).glob("*")):
        ent = DATA.get("external_user_tools", {}).get(script.stem.removesuffix(".sh"))
        check(script.suffix == ".sh" and isinstance(ent, dict) and ent.get("kind") == kind,
              f".scripts/{kind}/{script.name}: no [external_user_tools] entry with kind = {kind!r} uses it")

# --- [user_tools] ------------------------------------------------------------
user_tools = DATA.get("user_tools", {})
bins: dict[str, str] = {}
for pkg, entry in user_tools.items():
    where = f"[user_tools].{pkg!r}"
    check_profiles_key(where, entry)
    if isinstance(entry, dict):
        check(set(entry) <= {"bin", "profiles", "version"},
              f"{where}: unknown keys {sorted(set(entry) - {'bin', 'profiles', 'version'})}")
        check(isinstance(entry.get("bin"), str) and entry["bin"],
              f"{where}: table form needs a `bin` (the collision check would render an empty name)")
        if "version" in entry:
            check(isinstance(entry["version"], str) and entry["version"], f"{where}: `version` must be a non-empty string")
        b = entry.get("bin")
    elif isinstance(entry, str):
        b = entry
    else:
        errors.append(f"{where}: must be a binary-name string or a {{ bin = ... }} table, got {entry!r}")
        continue
    if isinstance(b, str):
        check(re.fullmatch(r"[A-Za-z0-9._+-]+", b) is not None, f"{where}: bin {b!r} is not a plain binary name")
        check(b not in bins, f"{where}: bin {b!r} is also declared by {bins.get(b)!r}")
        bins[b] = pkg
        # The collision guard aborts the whole apply if a mise-managed binary
        # is already on PATH from somewhere else -- e.g. the system package.
        check(b not in system_pkg_names and b not in DATA.get("system_tools", {}),
              f"{where}: bin {b!r} is also installed by [system_tools]; the collision guard would abort apply")

# mise backends that need another tool present on the same profile.
# npm: needs node; pipx: runs through uv (mise config sets pipx.uvx = true);
# cargo: needs cargo, i.e. the rust toolchain from [external_user_tools].
BACKEND_PREREQS = {
    "npm:": ("node", lambda: entry_profiles(user_tools["node"]) if "node" in user_tools else set()),
    "pipx:": ("uv", lambda: entry_profiles(user_tools["uv"]) if "uv" in user_tools else set()),
    "cargo:": ("rust ([external_user_tools])",
               lambda: entry_profiles(DATA["external_user_tools"]["rust"]) if "rust" in DATA.get("external_user_tools", {}) else set()),
}
for pkg, entry in user_tools.items():
    for prefix, (prereq, prereq_profiles) in BACKEND_PREREQS.items():
        if pkg.startswith(prefix):
            missing = sorted(entry_profiles(entry) - prereq_profiles())
            check(not missing, f"[user_tools].{pkg!r}: available on {missing} where its prerequisite {prereq} is not")

# --- [gui_apps] --------------------------------------------------------------
for app, ident in DATA.get("gui_apps", {}).items():
    where = f"[gui_apps].{app}"
    check_profiles_key(where, ident)
    script = SCRIPTS / "gui" / f"{app}.sh.tmpl"
    if isinstance(ident, dict):
        check(ident.get("native") is True and set(ident) <= {"native", "profiles"},
              f"{where}: the only supported table form is {{ native = true }} (+ optional profiles), got {ident!r}")
    elif isinstance(ident, str):
        if ident == "custom_script" or ident.startswith("ppa:") or "/" in ident:
            check(script.is_file(), f"{where}: {ident!r} is not a Flatpak ID, so .scripts/gui/{app}.sh.tmpl must exist")
        else:
            check(re.fullmatch(r"[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+){2,}", ident) is not None,
                  f"{where}: {ident!r} doesn't look like a Flatpak app ID (reverse-DNS)")
    else:
        errors.append(f"{where}: must be a Flatpak ID string or {{ native = true }}, got {ident!r}")
for script in sorted((SCRIPTS / "gui").glob("*")):
    # The dispatcher only ever looks for <app>.sh.tmpl.
    check(script.name.endswith(".sh.tmpl") and script.name.removesuffix(".sh.tmpl") in DATA.get("gui_apps", {}),
          f".scripts/gui/{script.name}: dispatcher only runs .scripts/gui/<[gui_apps] key>.sh.tmpl")

# --- [personal] --------------------------------------------------------------
personal = DATA.get("personal", {})
for app, settings in personal.items():
    where = f"[personal.{app}]"
    if not isinstance(settings, dict):
        errors.append(f"{where}: must be a table")
        continue
    check_profiles_key(where, settings)
    if "active" in settings:
        check(isinstance(settings["active"], bool), f"{where}: `active` must be a boolean")
    if settings.get("active"):
        check((SCRIPTS / "personal" / app / "configure.sh.tmpl").is_file(),
              f"{where}: active but .scripts/personal/{app}/configure.sh.tmpl is missing")
    if "requires" in settings:
        # The dispatcher does `index $ $requires`; an unknown key is just
        # falsy, so a typo would silently disable the app everywhere.
        check(settings["requires"] in MACHINE_KEYS,
              f"{where}: requires = {settings['requires']!r} is not a machine-local key from .chezmoi.toml.tmpl "
              f"({sorted(MACHINE_KEYS)})")
for d in sorted((SCRIPTS / "personal").glob("*")):
    check(d.name in personal, f".scripts/personal/{d.name}/: no [personal.{d.name}] table uses it")

# --- Script hygiene (CLAUDE.md: every script uses `set -euo pipefail`) ------
scripts = sorted(SCRIPTS.rglob("*.sh")) + sorted(SCRIPTS.rglob("*.sh.tmpl")) + sorted(REPO.glob("run_*.sh*"))
for s in scripts:
    rel = s.relative_to(REPO)
    text = s.read_text()
    check(text.startswith("#!/bin/bash\n") or text.startswith("#!/usr/bin/env bash\n"),
          f"{rel}: should start with a bash shebang")
    check(re.search(r"^set -euo pipefail$", text, re.M) is not None, f"{rel}: missing `set -euo pipefail`")
# Every personal script must gate on its app as its first real statement --
# not checkable in general, but at least require some presence check.
for s in sorted((SCRIPTS / "personal").glob("*/configure.sh.tmpl")):
    text = s.read_text()
    check(re.search(r"command -v|flatpak info|\[\[ ! -[fde] ", text) is not None,
          f"{s.relative_to(REPO)}: no presence gate (command -v / flatpak info / file test) found")

if errors:
    print(f"{len(errors)} of {checks} invariant check(s) failed:", file=sys.stderr)
    for e in errors:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(1)
print(f"all {checks} invariant checks passed")
