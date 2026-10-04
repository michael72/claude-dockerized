#!/usr/bin/env bash
# First-time setup: configuration file, shell completions, global command.
# Safe to re-run; every step checks what is already there.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=config-lib.sh
source "$HERE/config-lib.sh"

echo -e "${BLUE}claude-dockerized setup${NC}"
echo "======================="

mkdir -p "$STATE_DIR"
config_success "State directory: $STATE_DIR (mounted as ~/.claude in the container)"

interactive_config_setup

# --- Shell completions -------------------------------------------------------
# rc_add <rc file> <marker comment> <line>
rc_add() {
    local rc="$1" marker="$2" line="$3"
    if grep -qF "$line" "$rc" 2>/dev/null; then
        config_success "Already in $rc"
    else
        printf '\n%s\n%s\n' "$marker" "$line" >> "$rc"
        config_success "Added to $rc (open a new shell or: source $rc)"
    fi
}

echo ""
echo -e "${BLUE}Shell completions${NC}"
read -r -p "Install completions? 1) bash  2) zsh  3) both  [Enter] skip: " choice
if [ "$choice" = 1 ] || [ "$choice" = 3 ]; then
    rc_add "$HOME/.bashrc" "# claude-dockerized completion" \
        "[ -f \"$HERE/completions/bash.sh\" ] && source \"$HERE/completions/bash.sh\""
fi
if [ "$choice" = 2 ] || [ "$choice" = 3 ]; then
    rc_add "$HOME/.zshrc" "# claude-dockerized completion" \
        "[ -f \"$HERE/completions/zsh.sh\" ] && source \"$HERE/completions/zsh.sh\""
fi

# --- Global command ----------------------------------------------------------
echo ""
echo -e "${BLUE}Global installation${NC}"
INSTALL_DIR="$HOME/.local/bin"
LINK="$INSTALL_DIR/claude-dockerized"
TARGET="$HERE/claude-dockerized.sh"

if [ -L "$LINK" ] && [ "$(readlink -f "$LINK")" = "$(readlink -f "$TARGET")" ]; then
    config_success "Already installed: $LINK"
else
    read -r -p "Install 'claude-dockerized' into $INSTALL_DIR? (y/N): " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        mkdir -p "$INSTALL_DIR"
        if [ -e "$LINK" ] && [ ! -L "$LINK" ]; then
            config_warning "$LINK exists and is not a symlink - left alone"
        else
            ln -sfn "$TARGET" "$LINK"
            config_success "Linked $LINK -> $TARGET"
        fi
    fi
fi
if ! tr ':' '\n' <<<"$PATH" | grep -qx "$INSTALL_DIR"; then
    config_warning "$INSTALL_DIR is not in PATH - add: export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

echo ""
echo -e "${GREEN}Setup complete.${NC} Next:"
echo "  claude-dockerized build            # build the image"
echo "  claude-dockerized auth             # sign in once (skip for local models)"
echo "  claude-dockerized run ~/projects/x # or just 'claude-dockerized' in the project"
if [ "$LOCAL_MODEL_SUPPORT" = true ]; then
    echo "  claude-dockerized models           # check the local server answers"
fi
