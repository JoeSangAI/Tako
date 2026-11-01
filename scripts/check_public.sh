#!/bin/bash
# This repository is public. Nothing goes out with a private path, a credential or a word from .local/deny.txt.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
FAILED=0
FILES=()
while IFS= read -r -d "" file; do [ -f "$file" ] && FILES+=("$file"); done < <(git ls-files -z)

GENERIC='/Users/[A-Za-z]|gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY|AKIA[0-9A-Z]{16}'
if grep -InE "$GENERIC" "${FILES[@]}" | grep -v '^scripts/check_public.sh:'; then FAILED=1; fi

if [ -f .local/deny.txt ]; then
  while IFS= read -r word; do
    [ -n "$word" ] || continue
    if grep -InF -- "$word" "${FILES[@]}"; then echo "^^^ matches a private word"; FAILED=1; fi
    if printf '%s\n' "${FILES[@]}" | grep -nF -- "$word"; then echo "^^^ a file name matches a private word"; FAILED=1; fi
  done < .local/deny.txt
fi

if command -v gitleaks >/dev/null 2>&1; then
  gitleaks detect --no-banner --redact --source . >/dev/null 2>&1 || { echo "gitleaks found something: run gitleaks detect"; FAILED=1; }
fi
[ "$FAILED" = 0 ] && echo "public check: clean (${#FILES[@]} files)"
exit "$FAILED"
