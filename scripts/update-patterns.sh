#!/bin/bash
# Refreshes Resources/patterns.json from nibzard/awesome-agentic-patterns (Apache-2.0).
# Development only: the app never downloads anything. Needs gh (signed in) and python3.
# Usage: scripts/update-patterns.sh [git-ref]
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=nibzard/awesome-agentic-patterns
REF="${1:-main}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SHA="$(gh api "repos/$REPO/commits/$REF" -q .sha)"
gh api "repos/$REPO/tarball/$SHA" > "$WORK/repo.tar.gz"
mkdir "$WORK/repo" && tar -xzf "$WORK/repo.tar.gz" -C "$WORK/repo" --strip-components 1

python3 -I - "$WORK/repo" "$SHA" <<'EOF'
import json, os, re, sys
root, sha = sys.argv[1], sys.argv[2]

def value(raw):
    raw = raw.strip()
    if raw.startswith("["):
        try:
            return json.loads(raw)
        except ValueError:  # [plain, words] without quotes
            return [w.strip().strip("\"'") for w in raw[1:-1].split(",") if w.strip()]
    return raw.strip("\"'")

def section(body, name, limit):
    m = re.search(r"^## " + name + r"\s*\n(.*?)(?=^## |\Z)", body, re.S | re.M)
    text = re.sub(r"\n{3,}", "\n\n", m.group(1).strip()) if m else ""
    if len(text) > limit:  # cut at a paragraph boundary
        text = text[:limit].rsplit("\n\n", 1)[0]
    return text

patterns = []
folder = os.path.join(root, "patterns")
for name in sorted(os.listdir(folder)):
    if not name.endswith(".md") or name == "TEMPLATE.md":
        continue
    text = open(os.path.join(folder, name), encoding="utf-8").read()
    m = re.match(r"---\n(.*?)\n---\n(.*)", text, re.S)
    if not m:
        sys.exit("no front matter in " + name)
    # Simple YAML: "key: value", "key: [a, b]", "key:" followed by "- item" lines, "key: >" with indented text.
    meta, key = {}, None
    for line in m.group(1).splitlines():
        if re.match(r"^[a-z_]+:", line):
            key, raw = line.split(":", 1)
            raw = raw.strip()
            meta[key] = [] if raw == "" else "" if raw in (">", "|", ">-", "|-") else value(raw)
        elif key and line.strip().startswith("- ") and isinstance(meta[key], list):
            meta[key].append(value(line.strip()[2:]))
        elif key and line.startswith(" ") and isinstance(meta[key], str):
            meta[key] = (meta[key] + " " + line.strip()).strip()
    patterns.append({
        "slug": name[:-3],
        "title": meta.get("title", ""),
        "category": meta.get("category", ""),
        "status": meta.get("status", ""),
        "summary": meta.get("summary", ""),
        "signals": meta.get("signals", []),
        "antiSignals": meta.get("anti_signals", []),
        "tags": meta.get("tags", []),
        "solution": section(m.group(2), "Solution", 1200),
    })

missing = [p["slug"] for p in patterns if not (p["title"] and p["summary"] and p["solution"])]
if missing:
    print("warning: incomplete patterns skipped:", ", ".join(missing), file=sys.stderr)
patterns = [p for p in patterns if p["slug"] not in missing]
with open("Resources/patterns.json", "w", encoding="utf-8") as f:
    json.dump({"source": "https://github.com/nibzard/awesome-agentic-patterns", "commit": sha, "patterns": patterns},
              f, ensure_ascii=False, indent=1)
print(f"Wrote {len(patterns)} patterns from {sha[:12]}")
EOF

{
  echo "Resources/patterns.json is derived from Awesome Agentic Patterns"
  echo "https://github.com/nibzard/awesome-agentic-patterns, commit $SHA"
  echo "Copyright Nikola Balic and contributors. Licensed under the Apache License, Version 2.0."
  echo "Only titles, metadata and an excerpt of each pattern's Solution section are included."
  echo
  cat "$WORK/repo/LICENSE"
} > Resources/NOTICE-agentic-patterns.txt
