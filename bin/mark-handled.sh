#!/usr/bin/env bash
# Args: PR numbers to record as handled. Merges into seen (unique, sorted).
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

{ cat "$SEEN"; printf '%s\n' "$@" | grep -oE '[0-9]+'; } \
  | sort -un > "$SEEN.tmp" && mv "$SEEN.tmp" "$SEEN"
echo "seen=$(wc -l < "$SEEN" | tr -d ' ')"
