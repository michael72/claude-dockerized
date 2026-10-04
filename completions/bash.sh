#!/bin/bash
# Bash completion for claude-dockerized. Source from ~/.bashrc (setup.sh offers to).

_claude_dockerized() {
    local cur prev
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    if [ "$COMP_CWORD" -eq 1 ]; then
        mapfile -t COMPREPLY < <(compgen -W "run shell auth token models build update version config clean help" -- "$cur")
        return 0
    fi

    case "$prev" in
        run|shell|auth) mapfile -t COMPREPLY < <(compgen -d -- "$cur") ;;
        config)         mapfile -t COMPREPLY < <(compgen -W "show edit path" -- "$cur") ;;
        models)         mapfile -t COMPREPLY < <(compgen -W "--refresh --clear --default --help" -- "$cur") ;;
    esac
    return 0
}

complete -F _claude_dockerized claude-dockerized claude-dockerized.sh ./claude-dockerized.sh
