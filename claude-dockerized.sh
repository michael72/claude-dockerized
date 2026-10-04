#!/usr/bin/env bash
# Wrapper around `docker run`, same shape as opencode-dockerized.sh.
set -euo pipefail

# Resolve symlinks so a link in ~/.local/bin still finds config-lib.sh.
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
IMAGE="${CLAUDE_IMAGE:-claude-dockerized:latest}"

# shellcheck source=config-lib.sh
source "$HERE/config-lib.sh"

usage() {
    cat <<EOF
Usage: $(basename "$0") [command] [args]

  run [DIR] [...]       Run Claude Code in DIR (default: \$PWD); extra args go to claude
  shell [DIR]           Drop into bash in the container instead of claude
  auth                  Run claude once interactively to sign in (state persists)
  token                 Print the command to mint a long-lived token on the host
  models [--refresh|--clear]
                        List the local model server's models; --refresh writes them
                        into the /model picker, --clear removes them again
  build                 Build the image (uses the layer cache)
  update                Rebuild with the latest Claude Code, skills and tools
  version               Show the Claude Code version in the image
  config [show|edit|path]
                        Show, edit or locate ~/.config/claude-dockerized/config
  clean                 Remove the image
  help                  Show this help

Without a command, 'run' in the current directory.

Environment:
  DRY_RUN=true          Print the docker command instead of running it
  CLAUDE_IMAGE          Image name (default: claude-dockerized:latest)
  CLAUDE_DOCKER_STATE   Host state directory (default: ~/.claude-dockerized)
  CLAUDE_FIREWALL       true/false, overrides setting.firewall_support
  CLAUDE_DOCKER_SOCK    true/false, overrides setting.docker_socket_support

First time: ./setup.sh, then '$(basename "$0") build' and '$(basename "$0") auth'.
EOF
}

# docker_exec <docker run args...> - honours DRY_RUN.
docker_exec() {
    if [ "${DRY_RUN:-false}" = "true" ]; then
        printf '%q ' docker run "$@"
        echo
        return 0
    fi
    docker run "$@"
}

# Sets TTY_ARGS. Must not be called via $(...): inside a command substitution
# stdout is a pipe, so the -t 1 test would always fail and the container would
# never get a TTY (claude then drops into --print mode).
set_tty_args() {
    if [ -t 0 ] && [ -t 1 ]; then TTY_ARGS=(-it); else TTY_ARGS=(-i); fi
}

# docker_run <project dir> <command...>
docker_run() {
    local project="$1"; shift
    if [ ! -d "$project" ]; then
        config_error "Project directory does not exist: $project"
        exit 1
    fi
    project="$(cd "$project" && pwd)"
    [ "${DRY_RUN:-false}" = "true" ] || check_image "$IMAGE" || exit 1

    build_all_args
    build_project_volume_args "$project"

    local name
    name="claude-$(sanitize_container_name "$(basename "$project")")-$(generate_random_suffix)"

    set_tty_args
    docker_exec "${TTY_ARGS[@]}" \
        --name "$name" \
        --hostname claude-sandbox \
        "${DOCKER_COMMON_ARGS[@]}" \
        "${VOLUME_ARGS[@]}" \
        "${DOCKER_MOUNT_ARGS[@]}" \
        "${DOCKER_ENV_ARGS[@]}" \
        "$IMAGE" "$@"
}

run_models() {
    parse_config
    if [ "$LOCAL_MODEL_SUPPORT" != true ]; then
        config_error "setting.local_model_support is off - enable it in $CONFIG_FILE or via ./setup.sh"
        exit 1
    fi
    [ "${DRY_RUN:-false}" = "true" ] || check_image "$IMAGE" || exit 1
    build_mount_args
    build_env_args
    build_common_docker_args
    set_tty_args
    docker_exec "${TTY_ARGS[@]}" \
        --name "claude-models-$$" \
        "${DOCKER_COMMON_ARGS[@]}" \
        "${DOCKER_ENV_ARGS[@]}" \
        "$IMAGE" claude-local-models "$@"
}

image_versions() {
    docker run --rm --entrypoint bash "$IMAGE" -lc '
        echo "claude:   $(claude --version 2>/dev/null)"
        echo "openspec: $(openspec --version 2>/dev/null || echo -)"
        echo "graphify: $(graphify --version 2>/dev/null || echo -)"
        echo "skills:   $(ls /opt/matt-pocock-skills/.claude/skills 2>/dev/null | wc -l) Matt Pocock skills staged"'
}

build_image() {
    docker build --progress=plain "$@" -t "$IMAGE" "$HERE"
    config_success "Image $IMAGE built"
}

update_image() {
    if docker image inspect "$IMAGE" >/dev/null 2>&1; then
        config_info "Before:"
        image_versions || true
    fi
    # CLAUDE_BUILD_TIME busts the cache from the Claude Code layer onwards,
    # which also refreshes the Matt Pocock skills, OpenSpec and graphify.
    build_image --build-arg "CLAUDE_BUILD_TIME=$(date +%s)"
    config_info "After:"
    image_versions
}

show_config() {
    case "${1:-show}" in
        show) parse_config; print_config ;;
        path) echo "$CONFIG_FILE" ;;
        edit)
            if ! config_exists; then
                config_warning "No config yet - running setup.sh"
                "$HERE/setup.sh"
            else
                "${EDITOR:-vi}" "$CONFIG_FILE"
            fi
            ;;
        *) config_error "Unknown config subcommand: $1"; echo "Usage: $(basename "$0") config [show|edit|path]"; exit 1 ;;
    esac
}

cmd="${1:-run}"; shift || true
case "$cmd" in
    run)
        dir="$PWD"
        if [ $# -gt 0 ] && [ -d "$1" ]; then dir="$1"; shift; fi
        docker_run "$dir" claude "$@"
        ;;
    shell)   docker_run "${1:-$PWD}" bash ;;
    auth)    docker_run "${1:-$PWD}" claude ;;
    token)   echo "On the host: claude setup-token   # then export CLAUDE_CODE_OAUTH_TOKEN=..." ;;
    models)  run_models "$@" ;;
    build)   build_image "$@" ;;
    update)  update_image ;;
    version) check_image "$IMAGE" && image_versions ;;
    config)  show_config "$@" ;;
    clean)   docker rmi "$IMAGE" ;;
    help|-h|--help) usage ;;
    *)       config_error "Unknown command: $cmd"; echo; usage; exit 1 ;;
esac
