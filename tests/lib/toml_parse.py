"""Parse each TOML file given on the command line; exit non-zero if any fails."""

import sys
import tomllib

failed = False
for path in sys.argv[1:]:
    try:
        with open(path, "rb") as f:
            tomllib.load(f)
        print(f"  ok  {path}")
    except (OSError, tomllib.TOMLDecodeError) as e:
        print(f"  FAIL {path}: {e}", file=sys.stderr)
        failed = True
if not sys.argv[1:]:
    print("toml_parse.py: no files given", file=sys.stderr)
    failed = True
sys.exit(1 if failed else 0)
