#!/usr/bin/env bash
# Thin wrapper around `docker run`, same shape as opencode-dockerized.sh.
set -euo pipefail

IMAGE="${CLAUDE_IMAGE:-claude-dockerized:latest}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Host-side state directory. Deliberately NOT ~/.claude: a container running
# with --dangerously-skip-permissions can write anything it can reach, and your
# host Claude Code credentials and session history are not something the
# sandbox needs write access to. Use a separate login for the container.
STATE_DIR="${CLAUDE_DOCKER_STATE:-$HOME/.claude-dockerized}"

# Set to "true" to enable the in-container egress allowlist. Requires the
# container NOT to use --network host.
FIREWALL="${CLAUDE_FIREWALL:-false}"

usage() {
    cat <<'EOF'
Usage: claude-dockerized.sh <command> [args]

  build            Build the image
  auth             Run `claude` once interactively to sign in (state persists)
  token            Print the command to mint a long-lived token on the host
  run [DIR] [...]  Run Claude Code in DIR (default: $PWD); extra args go to claude
  shell [DIR]      Drop into bash in the container instead of claude
  clean            Remove the image
EOF
}

docker_run() {
    local project="$1"; shift
    project="$(cd "$project" && pwd)"
    mkdir -p "$STATE_DIR"

    local args=(
        --rm -it
        --hostname claude-sandbox
        --user root                       # entrypoint drops to coder itself
        -e HOST_UID="$(id -u)"
        -e HOST_GID="$(id -g)"
        -e CLAUDE_WORKDIR="/workspace"
        -e CLAUDE_FIREWALL="$FIREWALL"
        -e TERM="${TERM:-xterm-256color}"
        -v "$project:/workspace:rw"
        -v "$STATE_DIR:/home/coder/.claude:rw"
        --workdir /workspace
        # No new privileges, and only the capabilities the entrypoint needs to
        # remap the UID/GID, chown state dirs and drop to the coder user. The
        # entrypoint clears them all (setpriv --inh-caps=-all) before exec'ing
        # claude, and no-new-privileges keeps them from coming back.
        --security-opt no-new-privileges
        --cap-drop ALL
        --cap-add SETUID --cap-add SETGID
        --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER
    )

    if [ "$FIREWALL" = "true" ]; then
        args+=(--cap-add NET_ADMIN --cap-add NET_RAW)
    else
        # Browser OAuth callback comes back to localhost; host networking is the
        # simplest way to make that land. Mutually exclusive with the firewall.
        args+=(--network host)
    fi

    # Optional: Testcontainers. Read the README before enabling.
    if [ "${CLAUDE_DOCKER_SOCK:-false}" = "true" ]; then
        args+=(-v /var/run/docker.sock:/var/run/docker.sock)
    fi

    # Pass a token through instead of interactive login, if you have one.
    [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && args+=(-e CLAUDE_CODE_OAUTH_TOKEN)
    [ -n "${ANTHROPIC_API_KEY:-}" ] && args+=(-e ANTHROPIC_API_KEY)

    [ "${DRY_RUN:-false}" = "true" ] && { echo docker run "${args[@]}" "$IMAGE" "$@"; return 0; }
    docker run "${args[@]}" "$IMAGE" "$@"
}

cmd="${1:-help}"; shift || true
case "$cmd" in
    build) docker build -t "$IMAGE" "$HERE" ;;
    auth)  docker_run "${1:-$PWD}" claude ;;
    token) echo "On the host: claude setup-token   # then export CLAUDE_CODE_OAUTH_TOKEN=..." ;;
    run)
        dir="$PWD"
        if [ $# -gt 0 ] && [ -d "$1" ]; then dir="$1"; shift; fi
        docker_run "$dir" claude "$@"
        ;;
    shell) docker_run "${1:-$PWD}" bash ;;
    clean) docker rmi "$IMAGE" ;;
    *)     usage ;;
esac
