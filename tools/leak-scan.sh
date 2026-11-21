#!/bin/sh
# Fails if any real secret value from the local secret files appears in staged changes.
# Secret files live outside the repo; values are never printed.
set -e
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
for f in /root/peers-ss-secrets.env /root/peers-ss-secrets-end.env; do
  [ -r "$f" ] || continue
  grep -oE 'stlth_[A-Za-z0-9_]{8,}|github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|[0-9]{8,12}:[A-Za-z0-9_-]{30,}' "$f" >> "$TMP" || true
  grep -E '^[A-Z_]*(PASSWORD|TOKEN|KEY|SECRET)[A-Z_]*=' "$f" | cut -d= -f2- | grep -E '.{6,}' >> "$TMP" || true
done
git diff --cached -U0 | grep '^+' > "$TMP.diff" || true
if [ -s "$TMP" ] && grep -qFf "$TMP" "$TMP.diff"; then rm -f "$TMP.diff"; echo "SECRET FOUND IN STAGED CHANGES — commit aborted" >&2; exit 1; fi
# generic patterns (real-looking tokens, vless links with uuid)
if grep -qE 'stlth_[A-Za-z0-9]{6,}_[A-Za-z0-9]{6,}|github_pat_[A-Za-z0-9_]{30,}|vless://[0-9a-f]{8}-' "$TMP.diff"; then rm -f "$TMP.diff"; echo "TOKEN-LIKE STRING IN STAGED CHANGES — commit aborted" >&2; exit 1; fi
rm -f "$TMP.diff"; echo "secret check: clean"
