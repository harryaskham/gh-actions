#!/usr/bin/env bash
# Push store paths, with their closures, to FlakeHub Cache from a GitHub
# Actions job whose runner user is NOT a trusted Nix user (for example a
# self-hosted runner running as `github-runner`).
#
# DeterminateSystems/flakehub-cache-action refuses to start for untrusted users:
# it needs trust to import its own daemon closure and to install a post-build
# hook. An explicit push needs neither. This script fetches the same static
# magic-nix-cache daemon, imports it into a throwaway local store (no Nix daemon
# involved), authenticates with this job's GitHub OIDC token, enqueues the
# paths and waits until FlakeHub Cache reports the upload complete.
#
# Requires `permissions: id-token: write`, plus curl, xz and nix-store on PATH.
# usage: LISTEN=127.0.0.1:PORT flakehub-push-closure.sh STORE_PATH...
set -euo pipefail

if (($# == 0)); then
  echo "usage: $0 STORE_PATH..." >&2
  exit 2
fi
: "${ACTIONS_ID_TOKEN_REQUEST_URL:?the job needs permissions: id-token: write}"
: "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:?the job needs permissions: id-token: write}"
LISTEN=${LISTEN:-127.0.0.1:37515}
# The flakehub-cache-action v3 default daemon revision.
MNC_REV=${MNC_REV:-5a7f052c8f0c6511bbef3570eeed4d39242171ef}

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) suffix=X64-Linux ;;
  Linux-aarch64) suffix=ARM64-Linux ;;
  # Darwin is not supported yet: the macOS daemon closure is not shown to run
  # from a throwaway store. Use cache-push: action on (trusted) macOS runners.
  *) echo "flakehub-push-closure: unsupported platform $(uname -sm)" >&2; exit 2 ;;
esac

work=$(mktemp -d "${RUNNER_TEMP:-/tmp}/flakehub-push.XXXXXX")
daemon_pid=""
cleanup() {
  if [[ -n $daemon_pid ]]; then kill "$daemon_pid" 2>/dev/null || true; fi
  chmod -R u+w "$work" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

echo "Fetching magic-nix-cache $MNC_REV ($suffix)"
curl -fsSL --retry 3 "https://install.determinate.systems/magic-nix-cache-closure/rev/$MNC_REV/$suffix" \
  | xz -dc \
  | nix-store --store "$work/store" --option require-sigs false --import >/dev/null
daemon=$(compgen -G "$work/store/nix/store/*-magic-nix-cache*/bin/magic-nix-cache" | head -n1 || true)
if [[ -z $daemon ]]; then
  echo "flakehub-push-closure: magic-nix-cache binary not found in the closure" >&2
  exit 1
fi

# GitHub OIDC token for FlakeHub; the daemon refreshes it while uploading.
oidc=$(curl -fsS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api.flakehub.com" \
  | sed -n 's/.*"value":"\([^"]*\)".*/\1/p')
if [[ -z $oidc ]]; then
  echo "flakehub-push-closure: could not obtain a GitHub OIDC token" >&2
  exit 1
fi
echo "::add-mask::$oidc"
(
  umask 077
  for host in api.flakehub.com flakehub.com cache.flakehub.com; do
    printf 'machine %s login flakehub password %s\n' "$host" "$oidc"
  done > "$work/netrc"
)
unset oidc

# --nix-conf points at a scratch file: the daemon appends substituter and
# netrc settings there, which must not reach any persistent configuration.
"$daemon" \
  --listen "$LISTEN" \
  --upstream https://cache.nixos.org \
  --diagnostic-endpoint "" \
  --nix-conf "$work/nix.conf" \
  --use-gha-cache disabled \
  --use-flakehub enabled \
  --flakehub-cache-server https://cache.flakehub.com \
  --flakehub-api-server https://api.flakehub.com \
  --flakehub-api-server-netrc "$work/netrc" \
  > "$work/daemon.log" 2>&1 &
daemon_pid=$!

api() { curl -fsS -X POST -H 'Content-Type: application/json' "$@"; }

if ! api --retry 60 --retry-delay 1 --retry-connrefused --data '{}' \
  "http://$LISTEN/api/workflow-start" >/dev/null 2>&1; then
  echo "flakehub-push-closure: daemon did not start" >&2
  cat "$work/daemon.log" >&2
  exit 1
fi

paths=$(printf '"%s",' "$@")
api --data "{\"store_paths\":[${paths%,}]}" "http://$LISTEN/api/enqueue-paths" >/dev/null
echo "Enqueued $# path(s) and their closures; waiting for FlakeHub Cache uploads"

# workflow-finish blocks until the push session has drained, then shuts down.
api --max-time 21600 "http://$LISTEN/api/workflow-finish" >/dev/null || true
wait "$daemon_pid" 2>/dev/null || true
daemon_pid=""

log=$(sed 's/\x1b\[[0-9;]*m//g' "$work/daemon.log")
printf '%s\n' "$log" | grep -E 'FlakeHub|cache|error|ERROR|WARN' | grep -v '^Every log line' | tail -n 20
if ! printf '%s\n' "$log" | grep -q 'FlakeHub Cache uploads completed'; then
  echo "flakehub-push-closure: FlakeHub Cache did not report a completed upload" >&2
  if printf '%s\n' "$log" | grep -q 'Project not found'; then
    echo "flakehub-push-closure: the FlakeHub project does not exist yet; publish the flake first" >&2
  fi
  exit 1
fi
