#compdef claude-dockerized claude-dockerized.sh
# shellcheck shell=bash disable=SC2034,SC2154,SC2016
# Zsh completion for claude-dockerized. Source from ~/.zshrc (setup.sh offers to).

_claude_dockerized() {
    local -a commands
    commands=(
        'run:Run Claude Code in Docker (default: current directory)'
        'shell:Open bash in the container'
        'auth:Sign in once interactively'
        'token:Show how to mint a long-lived token on the host'
        'models:List local models (--refresh updates the /model picker)'
        'build:Build the Docker image'
        'update:Rebuild with the latest Claude Code, skills and tools'
        'version:Show versions in the image'
        'config:Show, edit or locate the config file'
        'clean:Remove the Docker image'
        'help:Show help'
    )

    _arguments -C '1: :->cmds' '*:: :->args'

    case $state in
        cmds) _describe -t commands 'claude-dockerized command' commands ;;
        args)
            case $words[1] in
                run|shell|auth) _files -/ ;;
                config) _values 'subcommand' 'show[Show configuration]' 'edit[Edit in $EDITOR]' 'path[Print config path]' ;;
                models) _values 'option' '--refresh[Write the models into the /model picker]' \
                            '--clear[Remove them from the picker]' '--default[Print the default model]' ;;
            esac
            ;;
    esac
}

compdef _claude_dockerized claude-dockerized claude-dockerized.sh
