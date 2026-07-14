#!/usr/bin/env bash
#
# Fast path for the pr-risk-analyzer composite action.
#
# Resolves the pre-compiled native binary for this runner's OS/arch from the
# action's GitHub Release, verifies its SHA-256 checksum, and executes it.
# On ANY infrastructure failure (unsupported arch, download error, checksum
# mismatch) it signals `mode=fallback` so action.yml can compile from source
# with the Dart SDK instead. A non-zero exit from the binary ITSELF (e.g. a
# quality-gate violation) is propagated, not treated as a fallback.
set -uo pipefail

fallback() {
  echo "pr-risk-analyzer: $1, falling back to a source build." >&2
  echo "mode=fallback" >>"${GITHUB_OUTPUT:-/dev/null}"
  exit 0
}

# --- Map the runner to an asset name -----------------------------------------
case "${RUNNER_OS:-}" in
  Linux)   os=linux;   ext="" ;;
  macOS)   os=macos;   ext="" ;;
  Windows) os=windows; ext=".exe" ;;
  *) fallback "unsupported RUNNER_OS='${RUNNER_OS:-}'" ;;
esac

case "${RUNNER_ARCH:-}" in
  X64)   arch=x64 ;;
  ARM64) arch=arm64 ;;
  *) fallback "unsupported RUNNER_ARCH='${RUNNER_ARCH:-}'" ;;
esac

asset="pr-risk-analyzer-${os}-${arch}${ext}"
repo="${ACTION_REPO:-}"
ref="${ACTION_REF:-}"
# Local (`uses: ./`) or vendored copies have no release to download from.
[ -n "$repo" ] && [ -n "$ref" ] || fallback "no release ref (local/vendored action)"
# PRA_BASE_URL lets a GHES mirror (or tests) override the release host.
base_url="${PRA_BASE_URL:-https://github.com/${repo}/releases/download/${ref}}"

workdir="$(mktemp -d)"
bin="${workdir}/${asset}"

# --- Download binary + checksum ----------------------------------------------
dl() { curl --fail --silent --show-error --location --retry 3 -o "$2" "$1"; }
dl "${base_url}/${asset}" "$bin" || fallback "could not download ${asset} from ${ref}"
dl "${base_url}/${asset}.sha256" "${bin}.sha256" || fallback "could not download checksum for ${asset}"

# --- Verify SHA-256 (portable across Linux/macOS/Git-Bash) -------------------
expected="$(cut -d' ' -f1 <"${bin}.sha256")"
if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "$bin" | cut -d' ' -f1)"
elif command -v shasum >/dev/null 2>&1; then
  actual="$(shasum -a 256 "$bin" | cut -d' ' -f1)"
else
  fallback "no sha256 tool available"
fi
[ -n "$expected" ] && [ "$expected" = "$actual" ] || \
  fallback "checksum mismatch for ${asset} (expected ${expected:-<none>}, got ${actual})"

# --- Execute (INPUT_* and GITHUB_* env are already in the environment) -------
chmod +x "$bin" 2>/dev/null || true
exec "$bin"
