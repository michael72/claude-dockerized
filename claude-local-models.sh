#!/bin/bash
# claude-local-models - list a local model server's models and keep the
# Claude Code /model picker in sync with them. Installed in the image as
# /usr/local/bin/claude-local-models and run as the coder user.
#
#   claude-local-models             list the models (default marked with *)
#   claude-local-models --refresh   write them into the /model picker
#   claude-local-models --clear     remove the picker entries written by --refresh
#   claude-local-models --default   print the model a session should start on
#
# Why this exists: Claude Code's own gateway discovery
# (CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY) keeps only ids containing
# "claude" or "anthropic", so qwen3-coder, gpt-oss, devstral & co. never show
# up. The modelPicker setting takes arbitrary ids, but only from user or
# managed settings, so --refresh writes it to $CLAUDE_CONFIG_DIR/settings.json
# (the container's own state directory, ~/.claude-dockerized on the host).
set -euo pipefail

BASE_URL="${ANTHROPIC_BASE_URL:-}"
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CONFIG_DIR/settings.json"
# Exact copy of the last modelPicker this script wrote. Lets --refresh and
# --clear tell their own entries from a picker you configured by hand.
MARKER="$CONFIG_DIR/.claude-dockerized-model-picker.json"

die() { echo "claude-local-models: $*" >&2; exit 1; }

[ -n "$BASE_URL" ] || die "ANTHROPIC_BASE_URL is not set (enable setting.local_model_support)"
BASE_URL="${BASE_URL%/}"

# Prints one model id per line. Anthropic- and OpenAI-style servers
# (llama-server, LM Studio, LiteLLM, ollama >= 0.14) answer /v1/models with
# {"data":[{"id":...}]}; older ollama only has /api/tags.
fetch_models() {
    local auth=() body
    [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $ANTHROPIC_AUTH_TOKEN")
    if body="$(curl -fsS --max-time 5 "${auth[@]}" "$BASE_URL/v1/models?limit=1000" 2>/dev/null)" &&
        jq -e '.data | length > 0' >/dev/null 2>&1 <<<"$body"; then
        jq -r '.data[].id' <<<"$body"
        return 0
    fi
    if body="$(curl -fsS --max-time 5 "${auth[@]}" "$BASE_URL/api/tags" 2>/dev/null)" &&
        jq -e '.models | length > 0' >/dev/null 2>&1 <<<"$body"; then
        jq -r '.models[].name' <<<"$body"
        return 0
    fi
    return 1
}

default_model() { # default_model <ids>
    if [ -n "${LOCAL_MODEL:-}" ]; then echo "$LOCAL_MODEL"; else head -n 1 <<<"$1"; fi
}

current_picker() {
    [ -f "$SETTINGS" ] || { echo null; return; }
    jq -c '.modelPicker // null' "$SETTINGS" 2>/dev/null || die "$SETTINGS is not valid JSON - not touching it"
}

picker_is_ours() {
    local current
    current="$(current_picker)"
    [ "$current" = null ] && return 0
    [ -f "$MARKER" ] && [ "$current" = "$(jq -c . "$MARKER" 2>/dev/null)" ]
}

write_settings() { # write_settings <jq filter> [jq args...]
    local filter="$1" tmp
    shift
    mkdir -p "$CONFIG_DIR"
    [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
    tmp="$(mktemp "$SETTINGS.XXXXXX")"
    if jq "$@" "$filter" "$SETTINGS" > "$tmp"; then
        mv "$tmp" "$SETTINGS"
    else
        rm -f "$tmp"
        die "could not update $SETTINGS"
    fi
}

refresh() {
    local ids picker
    ids="$(fetch_models)" || die "no models from $BASE_URL (is the server running and reachable?)"
    if ! picker_is_ours; then
        echo "claude-local-models: $SETTINGS has a modelPicker you configured - leaving it alone" >&2
        return 0
    fi
    # replaceBuiltInOptions hides the Claude models, which a local server
    # cannot answer anyway.
    picker="$(jq -R . <<<"$ids" | jq -sc --arg url "$BASE_URL" '{
        replaceBuiltInOptions: true,
        options: map({model: ., label: ., description: ("Local model at " + $url)})
    }')"
    # shellcheck disable=SC2016  # $picker is a jq variable
    write_settings '.modelPicker = $picker' --argjson picker "$picker"
    printf '%s\n' "$picker" > "$MARKER"
    echo "claude-local-models: /model picker now lists $(wc -l <<<"$ids") model(s) from $BASE_URL"
}

clear_picker() {
    if [ ! -f "$MARKER" ]; then
        return 0
    fi
    if picker_is_ours && [ "$(current_picker)" != null ]; then
        write_settings 'del(.modelPicker)'
        echo "claude-local-models: removed the local models from the /model picker"
    fi
    rm -f "$MARKER"
}

case "${1:-}" in
    --refresh) refresh ;;
    --clear)   clear_picker ;;
    --default)
        ids="$(fetch_models)" || ids=""
        default_model "$ids"
        ;;
    ""|--list)
        ids="$(fetch_models)" || die "no models from $BASE_URL (is the server running and reachable?)"
        default="$(default_model "$ids")"
        echo "Models at $BASE_URL:"
        while read -r id; do
            if [ "$id" = "$default" ]; then echo "  * $id"; else echo "    $id"; fi
        done <<<"$ids"
        ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) die "unknown option: $1 (try --help)" ;;
esac
