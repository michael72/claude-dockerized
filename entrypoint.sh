#!/bin/bash
# Runs as root, does the few privileged things that are needed, then drops to
# the non-root "coder" user for good. Per-project setup (skills, OpenSpec,
# graphify, model picker) already runs as coder, so everything it writes into
# the project or the state directory belongs to you.
set -euo pipefail

TARGET_UID="${HOST_UID:-1000}"
TARGET_GID="${HOST_GID:-1000}"
WORKDIR="${CLAUDE_WORKDIR:-/}"
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-/home/coder/.claude}"

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
    for d in .claude .cache .config .local .npm .m2 .gradle .venv; do
        chown -R "$TARGET_UID:$TARGET_GID" "/home/coder/$d" 2>/dev/null || true
    done
fi

export HOME=/home/coder
export USER=coder

# as_coder <command string> - runs a shell as the target user in WORKDIR.
# Not a login shell: Debian's /etc/profile resets PATH, which would drop the
# image's ENV PATH (venv, nvm default, ~/.local/bin tools such as graphify).
as_coder() {
    setpriv --reuid="$TARGET_UID" --regid="$TARGET_GID" --init-groups --inh-caps=-all \
        bash -c "cd \"\$CLAUDE_WORKDIR_RESOLVED\" && $1"
}
export CLAUDE_WORKDIR_RESOLVED="$WORKDIR"

# Only the interactive `claude` launch gets the per-project setup; `shell`,
# `models` and `version` should start fast and leave the project alone.
is_claude_launch=false
[ "${1:-}" = "claude" ] && is_claude_launch=true

# --- LLM traffic interception (setting.llm_interceptor_support) --------------
# 'lli watch' runs on the HOST. This trusts its mitmproxy CA and points the
# proxy variables at it. Trusting the CA has to happen here, as root.
if [ "${LLM_INTERCEPTOR_SUPPORT:-false}" = "true" ]; then
    LLI_CA=/run/mitmproxy-ca-cert.pem
    if [ -f "$LLI_CA" ]; then
        install -m 0644 "$LLI_CA" /usr/local/share/ca-certificates/mitmproxy.crt
        update-ca-certificates >/dev/null 2>&1 || true
        # Claude Code (Node >= 22.15) reads the system store on its own;
        # NODE_EXTRA_CA_CERTS also covers npx-launched MCP servers and other
        # Node tools, the rest cover Python and anything using OpenSSL defaults.
        export NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/mitmproxy.crt
        export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
        export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
    else
        echo "llm-interceptor: no CA mounted - HTTPS interception will fail."
        echo "  Run 'lli watch' once on the host to generate ~/.mitmproxy, then relaunch."
    fi

    # HTTP_PROXY and HTTPS_PROXY are the SAME endpoint: one is used for http://
    # targets, the other for https:// targets tunnelled through CONNECT.
    export HTTP_PROXY="${LLM_INTERCEPTOR_PROXY:-http://127.0.0.1:9090}"
    export HTTPS_PROXY="$HTTP_PROXY" http_proxy="$HTTP_PROXY" https_proxy="$HTTP_PROXY"

    # Loopback stays off the proxy by default (pumlsrv, a local model server).
    # NO_PROXY matches hosts, not ports, so capturing a local model means
    # proxying all of loopback.
    if [ "${LLM_INTERCEPTOR_CAPTURE_LOCAL:-false}" = "true" ]; then
        export NO_PROXY="${LLM_INTERCEPTOR_NO_PROXY:-}"
    else
        export NO_PROXY="${LLM_INTERCEPTOR_NO_PROXY:-localhost,127.0.0.1,::1}"
    fi
    export no_proxy="$NO_PROXY"
    echo "llm-interceptor: routing through $HTTP_PROXY (NO_PROXY=${NO_PROXY:-<none>})"
    if [ "${LLM_INTERCEPTOR_CAPTURE_LOCAL:-false}" = "true" ]; then
        echo "llm-interceptor: lli records only URLs matching its filter - start it with e.g."
        echo "  lli watch --include '*127.0.0.1*' --include '*localhost*'"
    fi
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

# --- Matt Pocock's agent skills (setting.matt_pocock_skills_support) ---------
# Staged in the image by the upstream installer; synced into the personal
# skills directory, which Claude Code reads for every project. Unlike
# OpenCode, Claude Code lists skills in the / menu itself and understands
# disable-model-invocation natively, so no wrapper commands are needed.
#
# ~/.claude is the persistent state mount, so a manifest records which skill
# directories this sync owns: they are refreshed from the image on every
# launch (edits to them are overwritten), removed when the setting is turned
# off, and a skill of your own with the same name is never touched.
MP_STAGE="${MATT_POCOCK_SKILLS_DIR:-/opt/matt-pocock-skills}/.claude/skills"
MP_MANIFEST="$CLAUDE_CONFIG_DIR/skills/.matt-pocock-skills"
if [ "${MATT_POCOCK_SKILLS_SUPPORT:-false}" = "true" ]; then
    if [ -d "$MP_STAGE" ]; then
        as_coder "
            mkdir -p '$CLAUDE_CONFIG_DIR/skills'
            touch '$MP_MANIFEST'
            installed=0 skipped=''
            for src in '$MP_STAGE'/*/; do
                name=\$(basename \"\$src\")
                dst='$CLAUDE_CONFIG_DIR/skills/'\$name
                if [ -e \"\$dst\" ] && ! grep -qxF \"\$name\" '$MP_MANIFEST'; then
                    skipped=\"\$skipped \$name\"; continue
                fi
                rm -rf \"\$dst\" && cp -R \"\$src\" \"\$dst\" && installed=\$((installed + 1))
                grep -qxF \"\$name\" '$MP_MANIFEST' || echo \"\$name\" >> '$MP_MANIFEST'
            done
            echo \"Matt Pocock skills: \$installed skills in ~/.claude/skills (run /setup-matt-pocock-skills once per repo)\"
            [ -z \"\$skipped\" ] || echo \"Matt Pocock skills: kept your own skill(s) with the same name:\$skipped\"
        " || echo "Matt Pocock skills: sync failed (non-fatal)"
    else
        echo "Matt Pocock skills: not staged in this image (non-fatal) — rebuild the image"
    fi
elif [ -f "$MP_MANIFEST" ]; then
    as_coder "
        while read -r name; do
            [ -n \"\$name\" ] && rm -rf '$CLAUDE_CONFIG_DIR/skills/'\"\$name\"
        done < '$MP_MANIFEST'
        rm -f '$MP_MANIFEST'
        echo 'Matt Pocock skills: removed (setting is off)'
    " || true
fi

if [ "$is_claude_launch" = true ] && [ "$WORKDIR" != "/" ]; then
    # --- OpenSpec (setting.openspec_support) ---------------------------------
    # First launch in a project: 'openspec init --tools claude'. Every launch:
    # 'openspec update' to regenerate the skills and /opsx:* commands for the
    # CLI version in the image.
    if [ "${OPENSPEC_SUPPORT:-false}" = "true" ]; then
        as_coder "
            if [ ! -d openspec ]; then
                echo 'OpenSpec: initializing project for Claude Code...'
                openspec init --tools claude --profile core >/dev/null 2>&1 ||
                    echo \"OpenSpec: init failed (non-fatal) — run 'openspec init --tools claude' manually\"
            fi
            openspec update >/dev/null 2>&1 || true
        " || true
    fi

    # --- graphify (setting.graphify_support) ---------------------------------
    # 'graphify claude install --project' writes the graphify skill to
    # .claude/skills/graphify (which is /graphify in the / menu), a section in
    # CLAUDE.md and PreToolUse hooks in .claude/settings.json. It is re-run when
    # the image ships a newer graphify than the stamp the skill was written by.
    # 'graphify update .' builds or refreshes graphify-out/ including
    # GRAPH_REPORT.md from the AST alone: no API key, no tokens, no network.
    if [ "${GRAPHIFY_SUPPORT:-false}" = "true" ]; then
        as_coder "
            cli=\$(graphify --version 2>/dev/null | awk '{print \$NF}')
            stamp=\$(cat .claude/skills/graphify/.graphify_version 2>/dev/null || true)
            if [ ! -d .claude/skills/graphify ] || { [ -n \"\$cli\" ] && [ \"\$cli\" != \"\$stamp\" ]; }; then
                echo \"Graphify: registering graphify \$cli for Claude Code in this project...\"
                graphify claude install --project >/dev/null ||
                    echo \"Graphify: registration failed (non-fatal) — run 'graphify claude install --project'\"
            fi
            echo 'Graphify: building/refreshing graphify-out/ ...'
            graphify update . >/dev/null 2>&1 ||
                echo \"Graphify: graph update failed (non-fatal) — run 'graphify update .'\"
        " || true
    fi
fi

# --- Local model server (setting.local_model_support) ------------------------
# ANTHROPIC_BASE_URL and a placeholder ANTHROPIC_AUTH_TOKEN come from the
# wrapper. Here: pick the model, map every alias to it (subagents ask for
# "haiku"/"sonnet", which a local server does not have), and refresh the
# /model picker from the server's model list. Anything you set yourself wins.
if [ "${LOCAL_MODEL_SUPPORT:-false}" = "true" ]; then
    local_model="$(as_coder 'claude-local-models --default' 2>/dev/null || true)"
    if [ -n "$local_model" ]; then
        export ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-$local_model}"
        export ANTHROPIC_DEFAULT_OPUS_MODEL="${ANTHROPIC_DEFAULT_OPUS_MODEL:-$local_model}"
        export ANTHROPIC_DEFAULT_SONNET_MODEL="${ANTHROPIC_DEFAULT_SONNET_MODEL:-$local_model}"
        export ANTHROPIC_DEFAULT_HAIKU_MODEL="${ANTHROPIC_DEFAULT_HAIKU_MODEL:-$local_model}"
        export CLAUDE_CODE_SUBAGENT_MODEL="${CLAUDE_CODE_SUBAGENT_MODEL:-$local_model}"
        echo "local model: $ANTHROPIC_BASE_URL, starting on $ANTHROPIC_MODEL"
    else
        echo "local model: no answer from $ANTHROPIC_BASE_URL — is the server running?"
    fi
    # Pre-release request fields are what local servers most often reject, and
    # update checks/telemetry have no business leaving a local setup.
    export CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS="${CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS:-1}"
    export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-1}"
    if [ "$is_claude_launch" = true ] && [ -n "$local_model" ]; then
        as_coder 'claude-local-models --refresh' || true
    fi
else
    # Setting turned off: take the local models out of the picker again.
    [ -f "$CLAUDE_CONFIG_DIR/.claude-dockerized-model-picker.json" ] &&
        { as_coder 'ANTHROPIC_BASE_URL=unused claude-local-models --clear' || true; }
fi

# --- pumlsrv (setting.pumlsrv_support) ---------------------------------------
if [ "${PUMLSRV_SUPPORT:-false}" = "true" ] && [ "$is_claude_launch" = true ]; then
    if command -v pumlsrv-server >/dev/null 2>&1 || [ -x /home/coder/.local/bin/pumlsrv-server ]; then
        setpriv --reuid="$TARGET_UID" --regid="$TARGET_GID" --init-groups --inh-caps=-all \
            bash -c 'exec pumlsrv-server' >/dev/null 2>&1 &
    else
        echo "pumlsrv: not installed in this image (non-fatal)"
    fi
fi

# --- Drop privileges ---------------------------------------------------------
cd "$WORKDIR"

# shellcheck disable=SC2016  # expanded by the inner shell
exec setpriv --reuid="$TARGET_UID" --regid="$TARGET_GID" --init-groups \
     --inh-caps=-all \
     bash -c 'source "$NVM_DIR/nvm.sh" >/dev/null 2>&1 || true
               source "$SDKMAN_DIR/bin/sdkman-init.sh" >/dev/null 2>&1 || true
               exec "$@"' _ "$@"
