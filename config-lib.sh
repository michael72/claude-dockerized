#!/bin/bash
# config-lib.sh - shared configuration module for claude-dockerized.
# Sourced by claude-dockerized.sh and setup.sh, never executed directly.
#
# Same idea and file format as opencode-dockerized's config-lib.sh:
#   setting.<name>=<value>                           built-in features
#   mount.<name>=<host_path>:<container_path>[:rw]   extra bind mounts (ro default)
#   env.<name>=<VARIABLE_NAME>                       host variables to pass through
#
# NOTE: no "set -e" here - the callers decide their own error handling.

CONFIG_DIR="${CLAUDE_DOCKERIZED_CONFIG_DIR:-$HOME/.config/claude-dockerized}"
CONFIG_FILE="${CLAUDE_DOCKERIZED_CONFIG_FILE:-$CONFIG_DIR/config}"

# Host-side Claude Code state directory. Deliberately NOT ~/.claude: a container
# running with --dangerously-skip-permissions can write anything it can reach,
# and your host credentials and session history are not something the sandbox
# needs write access to. Use a separate login for the container.
STATE_DIR="${CLAUDE_DOCKER_STATE:-$HOME/.claude-dockerized}"

: "${RED:=\033[0;31m}"
: "${GREEN:=\033[0;32m}"
: "${YELLOW:=\033[1;33m}"
: "${BLUE:=\033[0;34m}"
: "${NC:=\033[0m}"

config_info()    { echo -e "${BLUE}ℹ${NC} $1"; }
config_success() { echo -e "${GREEN}✓${NC} $1"; }
config_warning() { echo -e "${YELLOW}⚠${NC} $1" >&2; }
config_error()   { echo -e "${RED}✗${NC} $1" >&2; }

# ============================================
# SETTINGS REGISTRY
# ============================================
# One line per setting: name|default|kind|comment written to the config file.
# The shell variable holding a setting is its upper-cased name, e.g.
# matt_pocock_skills_support -> MATT_POCOCK_SKILLS_SUPPORT.
# Kinds: bool (true/false), port (1-65535), string (anything, may be empty).
SETTINGS_REGISTRY=(
    "ssh_agent_support|false|bool|Forward the host SSH agent socket (git over SSH without sharing keys)"
    "firewall_support|false|bool|Default-deny egress with the allowlist in allowed-domains.txt (bridge network, NET_ADMIN)"
    "docker_socket_support|false|bool|Mount /var/run/docker.sock for Testcontainers - host-root equivalent, read the README first"
    "matt_pocock_skills_support|false|bool|Matt Pocock's agent skills (grill-me, tdd, to-spec, triage, ...) in ~/.claude/skills"
    "openspec_support|false|bool|OpenSpec spec-driven development: 'openspec init --tools claude' per project, /opsx:* commands"
    "graphify_support|false|bool|graphify code knowledge graph: project skill, CLAUDE.md section, hooks, graphify-out/"
    "pumlsrv_support|false|bool|Start the pumlsrv PlantUML server in the container (port 8380, use with pumlcli)"
    "llm_interceptor_support|false|bool|Route traffic through a host-side 'lli watch' (mitmproxy) and trust its CA"
    "llm_interceptor_port|9090|port|Port the host-side 'lli watch' proxy listens on"
    "llm_interceptor_capture_local|false|bool|Also proxy loopback, so a local model server is captured too"
    "local_model_support|false|bool|Point Claude Code at a local Anthropic-compatible server (llama-server, ollama, LM Studio)"
    "local_model_base_url|http://127.0.0.1:8080|string|Base URL of the local server (llama-server :8080, ollama :11434, LM Studio :1234)"
    "local_model||string|Default model id; empty = first model the server lists"
)

declare -a CUSTOM_MOUNTS=()       # "host_path:container_path[:mode]"
declare -a CUSTOM_ENV_VARS=()     # "VARIABLE_NAME"
declare -a DOCKER_MOUNT_ARGS=()   # -v args from CUSTOM_MOUNTS + SSH agent
declare -a DOCKER_ENV_ARGS=()     # -e args from CUSTOM_ENV_VARS + SSH agent
declare -a DOCKER_COMMON_ARGS=()  # args shared by every container this tool starts
declare -a VOLUME_ARGS=()         # project + state mounts (build_project_volume_args)
CONTAINER_WORKDIR=""

setting_field() { # setting_field <registry line> <index 1-4>
    local IFS='|'
    # shellcheck disable=SC2206  # word splitting on | is the point
    local fields=($1)
    echo "${fields[$(($2 - 1))]}"
}

setting_var() { echo "$1" | tr '[:lower:]' '[:upper:]'; }

reset_settings() {
    local line name
    for line in "${SETTINGS_REGISTRY[@]}"; do
        name="$(setting_field "$line" 1)"
        printf -v "$(setting_var "$name")" '%s' "$(setting_field "$line" 2)"
    done
}

# set_setting <name> <value> - validates against the registry.
# Returns 1 for an invalid value, 2 for an unknown setting.
set_setting() {
    local name="$1" value="$2" line kind=""
    for line in "${SETTINGS_REGISTRY[@]}"; do
        if [ "$(setting_field "$line" 1)" = "$name" ]; then
            kind="$(setting_field "$line" 3)"
            break
        fi
    done
    case "$kind" in
        bool)   [[ "$value" == "true" || "$value" == "false" ]] || return 1 ;;
        port)   [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 1 ] && [ "$value" -le 65535 ] || return 1 ;;
        string) ;;
        *)      config_warning "Unknown setting in $CONFIG_FILE: setting.$name (ignored)"; return 2 ;;
    esac
    printf -v "$(setting_var "$name")" '%s' "$value"
}

reset_settings

# ============================================
# CONFIG FILE
# ============================================

config_exists() { [ -f "$CONFIG_FILE" ]; }

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    echo "${s%"${s##*[![:space:]]}"}"
}

load_config() {
    reset_settings
    CUSTOM_MOUNTS=()
    CUSTOM_ENV_VARS=()
    config_exists || return 1

    local key value rc
    while IFS='=' read -r key value || [ -n "$key" ]; do
        key="$(trim "$key")"
        value="$(trim "$value")"
        case "$key" in
            ''|'#'*) ;;
            mount.*) [ -n "$value" ] && CUSTOM_MOUNTS+=("$value") ;;
            env.*)   [ -n "$value" ] && CUSTOM_ENV_VARS+=("$value") ;;
            setting.*)
                # "|| rc=$?" keeps a caller's set -e from aborting on a bad line.
                rc=0
                set_setting "${key#setting.}" "$value" || rc=$?
                if [ "$rc" -eq 1 ]; then
                    config_warning "Invalid value for $key: '$value' (keeping default)"
                fi
                ;;
        esac
    done < "$CONFIG_FILE"
    return 0
}

# Settings plus the two environment overrides the README has always documented.
parse_config() {
    load_config || true
    [ -n "${CLAUDE_FIREWALL:-}" ] && FIREWALL_SUPPORT="$CLAUDE_FIREWALL"
    [ -n "${CLAUDE_DOCKER_SOCK:-}" ] && DOCKER_SOCKET_SUPPORT="$CLAUDE_DOCKER_SOCK"
    return 0
}

save_config() {
    mkdir -p "$CONFIG_DIR"
    local line name var i
    {
        echo "# claude-dockerized configuration"
        echo "# Written by setup.sh - edit by hand or re-run setup.sh."
        echo "# See examples/config.example for every option with a longer explanation."
        echo ""
        echo "# Settings"
        for line in "${SETTINGS_REGISTRY[@]}"; do
            name="$(setting_field "$line" 1)"
            var="$(setting_var "$name")"
            echo "# $(setting_field "$line" 4)"
            echo "setting.$name=${!var}"
        done
        echo ""
        echo "# Custom volume mounts (read-only unless :rw is appended)"
        echo "# Format: mount.<name>=<host_path>:<container_path>[:rw]"
        for i in "${!CUSTOM_MOUNTS[@]}"; do
            echo "mount.custom$((i + 1))=${CUSTOM_MOUNTS[$i]}"
        done
        echo ""
        echo "# Host environment variables to pass into the container"
        echo "# Format: env.<name>=<VARIABLE_NAME>"
        for i in "${!CUSTOM_ENV_VARS[@]}"; do
            echo "env.custom$((i + 1))=${CUSTOM_ENV_VARS[$i]}"
        done
    } > "$CONFIG_FILE"
    config_success "Saved configuration to $CONFIG_FILE"
}

print_config() {
    local line name var
    echo ""
    echo "Configuration ($CONFIG_FILE$(config_exists || echo ', not created yet'))"
    echo "  State directory: $STATE_DIR"
    for line in "${SETTINGS_REGISTRY[@]}"; do
        name="$(setting_field "$line" 1)"
        var="$(setting_var "$name")"
        printf '  %-32s %s\n' "$name" "${!var}"
    done
    echo ""
    echo "  Custom mounts:"
    [ ${#CUSTOM_MOUNTS[@]} -eq 0 ] && echo "    (none)"
    for line in "${CUSTOM_MOUNTS[@]}"; do echo "    $line"; done
    echo "  Environment variables:"
    [ ${#CUSTOM_ENV_VARS[@]} -eq 0 ] && echo "    (none)"
    for line in "${CUSTOM_ENV_VARS[@]}"; do echo "    $line"; done
    echo ""
}

# ============================================
# DOCKER ARGUMENT BUILDING
# ============================================

check_image() {
    if ! docker image inspect "$1" >/dev/null 2>&1; then
        config_error "Docker image '$1' not found. Run '$(basename "$0") build' first."
        return 1
    fi
}

# Docker container names must match [a-zA-Z0-9][a-zA-Z0-9_.-]*
sanitize_container_name() {
    local name
    name="$(printf '%s' "$1" | tr -cd '[:alnum:]._-')"
    while [[ "$name" =~ ^[^[:alnum:]] ]]; do name="${name#?}"; done
    echo "${name:-project}"
}

generate_random_suffix() { printf '%04x%04x' $RANDOM $RANDOM; }

# Container path for a project: /workspace plus the host path with $HOME
# stripped, e.g. ~/projects/acme -> /workspace/projects/acme, /opt/x -> /workspace/opt/x.
#
# Claude Code keys session history (~/.claude/projects/<path>), project trust
# and auto-memory on the working directory, so mounting every project at plain
# /workspace made them all share one history. The /workspace prefix keeps a
# project called ~/bin or ~/usr from shadowing a system directory.
compute_container_path() {
    local host_path="$1"
    if [ "$host_path" = "$HOME" ]; then
        echo "/workspace"
    elif [[ "$host_path" == "$HOME"/* ]]; then
        echo "/workspace${host_path#"$HOME"}"
    else
        echo "/workspace$host_path"
    fi
}

# A git worktree has a .git FILE pointing at the main repository's .git
# directory, which lives outside the project mount. Mount that directory
# read-only at its real host path so the pointer resolves. Read operations
# (log, status, diff) work; commits from inside the container do not.
detect_git_worktree() {
    local project_dir="$1" common
    [ -f "$project_dir/.git" ] || return 0
    command -v git >/dev/null 2>&1 || return 0
    common="$(git -C "$project_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
    [ -d "$common/objects" ] && [ -d "$common/refs" ] && echo "$common"
}

# Rewrites a loopback URL so it reaches the host from a bridge-network
# container (firewall mode). Under --network host loopback already is the host.
host_reachable_url() {
    local url="$1"
    if [ "$FIREWALL_SUPPORT" = true ]; then
        url="$(printf '%s' "$url" | sed -E 's#^(https?://)(localhost|127\.0\.0\.1|\[::1\])([:/]|$)#\1host.docker.internal\3#')"
    fi
    echo "$url"
}

build_mount_args() {
    DOCKER_MOUNT_ARGS=()
    local mount host_path rest container_path mode
    for mount in "${CUSTOM_MOUNTS[@]}"; do
        mount="${mount//\~/$HOME}"
        host_path="${mount%%:*}"
        rest="${mount#*:}"
        container_path="${rest%:*}"
        mode="${rest##*:}"
        if [ "$mode" = "$container_path" ]; then
            mode="ro"
        elif [ "$mode" != "rw" ] && [ "$mode" != "ro" ]; then
            # The "mode" was really part of a path without one, e.g. a Windows-ish name.
            container_path="$rest"
            mode="ro"
        fi
        if [ ! -e "$host_path" ]; then
            config_warning "Custom mount source does not exist: $host_path (skipped)"
            continue
        fi
        DOCKER_MOUNT_ARGS+=(-v "$host_path:$container_path:$mode")
    done

    if [ "$SSH_AGENT_SUPPORT" = true ]; then
        if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
            DOCKER_MOUNT_ARGS+=(-v "$SSH_AUTH_SOCK:/run/host-ssh-agent.sock")
        else
            config_warning "SSH agent support enabled but SSH_AUTH_SOCK is not a socket (skipped)"
        fi
    fi
}

build_env_args() {
    DOCKER_ENV_ARGS=()
    local var_name
    for var_name in "${CUSTOM_ENV_VARS[@]}"; do
        if ! [[ "$var_name" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
            config_warning "Invalid variable name in config: $var_name (skipped)"
            continue
        fi
        if [ -n "${!var_name:-}" ]; then
            # Name only: docker reads the value from this process's environment,
            # so secrets do not show up in `ps` or in DRY_RUN output.
            export "${var_name?}"
            DOCKER_ENV_ARGS+=(-e "$var_name")
        else
            config_warning "Environment variable '$var_name' is not set on the host (skipped)"
        fi
    done

    if [ "$SSH_AGENT_SUPPORT" = true ] && [ -S "${SSH_AUTH_SOCK:-}" ]; then
        DOCKER_ENV_ARGS+=(-e "SSH_AUTH_SOCK=/run/host-ssh-agent.sock")
    fi
}

build_common_docker_args() {
    DOCKER_COMMON_ARGS=(
        --rm
        --user root                       # entrypoint drops to coder itself
        -e "HOST_UID=$(id -u)"
        -e "HOST_GID=$(id -g)"
        -e "TERM=${TERM:-xterm-256color}"
        # No new privileges, and only the capabilities the entrypoint needs to
        # remap the UID/GID, chown state dirs, trust a CA and drop to the coder
        # user. The entrypoint clears them all (setpriv --inh-caps=-all) before
        # exec'ing claude, and no-new-privileges keeps them from coming back.
        --security-opt no-new-privileges
        --cap-drop ALL
        --cap-add SETUID --cap-add SETGID
        --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER
        -e "CLAUDE_FIREWALL=$FIREWALL_SUPPORT"
        -e "MATT_POCOCK_SKILLS_SUPPORT=$MATT_POCOCK_SKILLS_SUPPORT"
        -e "OPENSPEC_SUPPORT=$OPENSPEC_SUPPORT"
        -e "GRAPHIFY_SUPPORT=$GRAPHIFY_SUPPORT"
        -e "PUMLSRV_SUPPORT=$PUMLSRV_SUPPORT"
        -e "LLM_INTERCEPTOR_SUPPORT=$LLM_INTERCEPTOR_SUPPORT"
        -e "LOCAL_MODEL_SUPPORT=$LOCAL_MODEL_SUPPORT"
    )

    # Terminal identification, so the TUI can use true colour, kitty
    # notifications and friends. All conditional.
    local var
    for var in TERM_PROGRAM TERM_PROGRAM_VERSION KITTY_WINDOW_ID COLORTERM; do
        [ -n "${!var:-}" ] && DOCKER_COMMON_ARGS+=(-e "$var=${!var}")
    done

    if [ "$FIREWALL_SUPPORT" = true ]; then
        DOCKER_COMMON_ARGS+=(--cap-add NET_ADMIN --cap-add NET_RAW)
        # Lets a bridge-network container reach host services (lli, a local
        # model server) under a stable name. The firewall keeps the bridge
        # subnet reachable, so these work as long as the service listens on
        # the docker bridge rather than 127.0.0.1 only.
        if [ "$LLM_INTERCEPTOR_SUPPORT" = true ] || [ "$LOCAL_MODEL_SUPPORT" = true ]; then
            DOCKER_COMMON_ARGS+=(--add-host host.docker.internal:host-gateway)
        fi
    else
        # Browser OAuth callback comes back to localhost; host networking is the
        # simplest way to make that land. Mutually exclusive with the firewall.
        DOCKER_COMMON_ARGS+=(--network host)
    fi

    if [ "$LLM_INTERCEPTOR_SUPPORT" = true ]; then
        local proxy_host="127.0.0.1"
        [ "$FIREWALL_SUPPORT" = true ] && proxy_host="host.docker.internal"
        DOCKER_COMMON_ARGS+=(
            -e "LLM_INTERCEPTOR_PROXY=http://$proxy_host:$LLM_INTERCEPTOR_PORT"
            -e "LLM_INTERCEPTOR_CAPTURE_LOCAL=$LLM_INTERCEPTOR_CAPTURE_LOCAL"
        )
        [ -n "${LLM_INTERCEPTOR_NO_PROXY:-}" ] &&
            DOCKER_COMMON_ARGS+=(-e "LLM_INTERCEPTOR_NO_PROXY=$LLM_INTERCEPTOR_NO_PROXY")
        if [ -f "$HOME/.mitmproxy/mitmproxy-ca-cert.pem" ]; then
            # Only the public certificate. The directory also holds the CA's
            # private key, which the sandbox has no business reading.
            DOCKER_COMMON_ARGS+=(-v "$HOME/.mitmproxy/mitmproxy-ca-cert.pem:/run/mitmproxy-ca-cert.pem:ro")
        else
            config_warning "LLM interception enabled but $HOME/.mitmproxy/mitmproxy-ca-cert.pem is missing"
            config_info "Run 'lli watch' once on the host to generate it, then relaunch"
        fi
    fi

    if [ "$LOCAL_MODEL_SUPPORT" = true ]; then
        DOCKER_COMMON_ARGS+=(
            -e "ANTHROPIC_BASE_URL=$(host_reachable_url "$LOCAL_MODEL_BASE_URL")"
            -e "LOCAL_MODEL=$LOCAL_MODEL"
        )
        # Local servers accept any token, but Claude Code needs one to skip the
        # login screen. A real one can come from the host.
        if [ -n "${CLAUDE_LOCAL_MODEL_TOKEN:-}" ]; then
            export ANTHROPIC_AUTH_TOKEN="$CLAUDE_LOCAL_MODEL_TOKEN"
            DOCKER_COMMON_ARGS+=(-e ANTHROPIC_AUTH_TOKEN)
        else
            DOCKER_COMMON_ARGS+=(-e "ANTHROPIC_AUTH_TOKEN=local")
        fi
    else
        # Pass a token through instead of interactive login, if you have one.
        [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && DOCKER_COMMON_ARGS+=(-e CLAUDE_CODE_OAUTH_TOKEN)
        [ -n "${ANTHROPIC_API_KEY:-}" ] && DOCKER_COMMON_ARGS+=(-e ANTHROPIC_API_KEY)
    fi

    if [ "$DOCKER_SOCKET_SUPPORT" = true ]; then
        if [ -S /var/run/docker.sock ]; then
            DOCKER_COMMON_ARGS+=(-v /var/run/docker.sock:/var/run/docker.sock)
        else
            config_warning "Docker socket support enabled but /var/run/docker.sock is missing"
        fi
    fi

    mkdir -p "$STATE_DIR"
    DOCKER_COMMON_ARGS+=(-v "$STATE_DIR:/home/coder/.claude:rw")
}

# Project mount plus git worktree support. Sets VOLUME_ARGS and CONTAINER_WORKDIR.
build_project_volume_args() {
    local project_dir="$1" git_common_dir
    CONTAINER_WORKDIR="$(compute_container_path "$project_dir")"
    VOLUME_ARGS=(
        -v "$project_dir:$CONTAINER_WORKDIR:rw"
        --workdir "$CONTAINER_WORKDIR"
        -e "CLAUDE_WORKDIR=$CONTAINER_WORKDIR"
    )
    git_common_dir="$(detect_git_worktree "$project_dir")"
    if [ -n "$git_common_dir" ]; then
        config_info "Git worktree detected - mounting $git_common_dir read-only"
        VOLUME_ARGS+=(-v "$git_common_dir:$git_common_dir:ro")
    fi
}

# Everything a container needs, for callers that do not mount a project.
build_all_args() {
    parse_config
    build_mount_args
    build_env_args
    build_common_docker_args
}

# ============================================
# INTERACTIVE PROMPTS (setup.sh)
# ============================================

# prompt_bool <setting> <question> [explanation lines...]
prompt_bool() {
    local name="$1" question="$2" var answer
    shift 2
    var="$(setting_var "$name")"
    echo ""
    if [ "${!var}" = true ]; then
        read -r -p "$question [currently enabled] (Y/n): " answer
        [[ "$answer" =~ ^[Nn]$ ]] && printf -v "$var" '%s' false
    else
        local line
        for line in "$@"; do echo "  $line"; done
        read -r -p "$question (y/N): " answer
        [[ "$answer" =~ ^[Yy]$ ]] && printf -v "$var" '%s' true
    fi
    if [ "${!var}" = true ]; then config_success "$name enabled"; else config_info "$name disabled"; fi
}

# prompt_value <setting> <question>
prompt_value() {
    local name="$1" question="$2" var answer
    var="$(setting_var "$name")"
    read -r -p "$question [${!var}]: " answer
    [ -z "$answer" ] && return 0
    set_setting "$name" "$answer" || config_warning "Invalid value '$answer' - keeping ${!var}"
}

prompt_features() {
    prompt_bool ssh_agent_support "Enable SSH agent forwarding?" \
        "Mounts \$SSH_AUTH_SOCK so git over SSH works without copying keys." \
        "The agent can then use your keys for as long as the session runs."

    prompt_bool firewall_support "Enable the egress firewall?" \
        "Default-deny outbound traffic except allowed-domains.txt. Uses a bridge" \
        "network instead of --network host; browser login then needs the paste-code flow."

    prompt_bool docker_socket_support "Mount the Docker socket (Testcontainers)?" \
        "WARNING: equivalent to giving the agent root on the host. See README."

    prompt_bool matt_pocock_skills_support "Enable Matt Pocock's agent skills?" \
        "grill-me, tdd, code-review, to-spec, to-tickets, triage, ... synced into" \
        "\$HOME/.claude/skills in the container on every launch. Run /setup-matt-pocock-skills once per repo."

    prompt_bool openspec_support "Enable OpenSpec (spec-driven development)?" \
        "Runs 'openspec init --tools claude' in new projects and 'openspec update'" \
        "on every launch. Adds openspec/ and .claude/{skills,commands} to the project."

    prompt_bool graphify_support "Enable graphify (code knowledge graph)?" \
        "Registers the graphify skill, a CLAUDE.md section and PreToolUse hooks in" \
        "the project and builds/refreshes graphify-out/ on every launch."

    prompt_bool pumlsrv_support "Start the pumlsrv PlantUML server?" \
        "Background server on port 8380 for pumlcli. Under --network host the port" \
        "is the host's, so two containers at once collide."

    prompt_bool llm_interceptor_support "Enable LLM traffic interception (llm-interceptor)?" \
        "Routes traffic through 'lli watch' running on the HOST and trusts its" \
        "mitmproxy CA inside the container. Install: uv tool install llm-interceptor"
    if [ "$LLM_INTERCEPTOR_SUPPORT" = true ]; then
        prompt_value llm_interceptor_port "Proxy port"
        prompt_bool llm_interceptor_capture_local "Capture traffic to local models on loopback too?" \
            "Stops exempting loopback from the proxy. lli then also needs a matching" \
            "glob: lli watch --include '*127.0.0.1*' --include '*localhost*'"
        [ -f "$HOME/.mitmproxy/mitmproxy-ca-cert.pem" ] ||
            config_warning "No CA at ~/.mitmproxy/mitmproxy-ca-cert.pem yet - run 'lli watch' once on the host"
    fi

    prompt_bool local_model_support "Use a local model server instead of Anthropic?" \
        "Any server speaking the Anthropic Messages API: llama-server, ollama (>= 0.14)," \
        "LM Studio, LiteLLM. Its /v1/models list becomes the /model picker."
    if [ "$LOCAL_MODEL_SUPPORT" = true ]; then
        prompt_value local_model_base_url "Base URL"
        prompt_value local_model "Default model id (empty = first one listed)"
    fi
}

prompt_custom_mounts() {
    local host_path container_path rw answer
    echo ""
    config_info "Custom volume mounts (read-only by default). Empty input finishes."
    if [ -f "$HOME/.gitconfig" ] && [[ ! " ${CUSTOM_MOUNTS[*]} " == *"/.gitconfig:"* ]]; then
        read -r -p "Mount ~/.gitconfig read-only (commit name/email)? (Y/n): " answer
        # shellcheck disable=SC2088  # stored literally, expanded at run time
        [[ "$answer" =~ ^[Nn]$ ]] || CUSTOM_MOUNTS+=("~/.gitconfig:/home/coder/.gitconfig")
    fi
    while true; do
        read -r -p "Host path: " host_path
        [ -z "$host_path" ] && break
        [ -e "${host_path/#\~/$HOME}" ] || config_warning "Path does not exist (yet): $host_path"
        read -r -p "Container path [/home/coder/$(basename "$host_path")]: " container_path
        container_path="${container_path:-/home/coder/$(basename "$host_path")}"
        read -r -p "Read-write? (y/N): " rw
        if [[ "$rw" =~ ^[Yy]$ ]]; then
            CUSTOM_MOUNTS+=("$host_path:$container_path:rw")
        else
            CUSTOM_MOUNTS+=("$host_path:$container_path")
        fi
        config_success "Added mount: $host_path -> $container_path"
    done
}

prompt_env_vars() {
    local var_name
    echo ""
    config_info "Host environment variables to pass in (e.g. CONTEXT7_API_KEY). Empty input finishes."
    while true; do
        read -r -p "Variable name: " var_name
        [ -z "$var_name" ] && break
        if ! [[ "$var_name" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
            config_error "Invalid name: $var_name (uppercase letters, digits, underscores)"
            continue
        fi
        [ -n "${!var_name:-}" ] || config_warning "$var_name is not set in this shell; it is skipped until it is"
        CUSTOM_ENV_VARS+=("$var_name")
    done
}

interactive_config_setup() {
    local mode
    if config_exists; then
        echo ""
        config_info "Configuration exists at $CONFIG_FILE"
        PS3="Choose an option: "
        select mode in "Update (keep current values as defaults)" "Start over" "Skip"; do
            [ -n "$mode" ] && break
        done
        case "$mode" in
            Skip*) config_info "Keeping existing configuration"; return 0 ;;
            Update*) load_config ;;
            *) reset_settings; CUSTOM_MOUNTS=(); CUSTOM_ENV_VARS=() ;;
        esac
    fi
    prompt_features
    prompt_custom_mounts
    prompt_env_vars
    save_config
    print_config
}
