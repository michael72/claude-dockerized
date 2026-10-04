#!/bin/bash
# Runs as root, does the few privileged things that are needed, then drops to
# the non-root "coder" user for good.
set -euo pipefail

TARGET_UID="${HOST_UID:-1000}"
TARGET_GID="${HOST_GID:-1000}"
WORKDIR="${CLAUDE_WORKDIR:-/}"

# --- Docker socket group (only relevant if the socket is mounted) ------------
if [ -S /var/run/docker.sock ]; then
    sock_gid="$(stat -c '%g' /var/run/docker.sock)"
    getent group "$sock_gid" >/dev/null 2>&1 || groupadd -g "$sock_gid" docker_host || true
    usermod -aG "$sock_gid" coder || true
fi

# --- UID/GID remap so files written into the bind mount belong to you --------
current_uid="$(id -u coder)"
current_gid="$(id -g coder)"
if [ "$TARGET_UID" != "$current_uid" ] || [ "$TARGET_GID" != "$current_gid" ]; then
    [ "$TARGET_GID" != "$current_gid" ] && groupmod -g "$TARGET_GID" coder || true
    [ "$TARGET_UID" != "$current_uid" ] && usermod -u "$TARGET_UID" coder || true
    # Shallow chown on the big toolchain trees, recursive only where it matters.
    chown "$TARGET_UID:$TARGET_GID" /home/coder /home/coder/.nvm /home/coder/.sdkman 2>/dev/null || true
    for d in .claude .cache .local .npm .m2 .gradle .venv; do
        chown -R "$TARGET_UID:$TARGET_GID" "/home/coder/$d" 2>/dev/null || true
    done
fi

# --- Egress allowlist --------------------------------------------------------
# Needs NET_ADMIN + NET_RAW and a bridge network. It is a no-op under
# --network host, where the rules would apply to the host's stack.
if [ "${CLAUDE_FIREWALL:-false}" = "true" ]; then
    if /usr/local/bin/init-firewall.sh; then
        echo "firewall: egress restricted to the allowlist"
    else
        echo "firewall: FAILED to apply — refusing to start" >&2
        exit 1
    fi
fi

# --- Drop privileges ---------------------------------------------------------
export HOME=/home/coder
export USER=coder
cd "$WORKDIR"

exec setpriv --reuid="$TARGET_UID" --regid="$TARGET_GID" --init-groups \
     --inh-caps=-all \
     bash -lc 'source "$NVM_DIR/nvm.sh" >/dev/null 2>&1 || true
               source "$SDKMAN_DIR/bin/sdkman-init.sh" >/dev/null 2>&1 || true
               exec "$@"' _ "$@"
