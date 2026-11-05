_zsqt_complete() {
    local current="${COMP_WORDS[COMP_CWORD]}"
    COMPREPLY=()
    if (( COMP_CWORD == 1 )) && [[ "$current" == -* ]]; then
        while IFS= read -r candidate; do COMPREPLY+=("$candidate"); done < <(compgen -W '--check --recover --debug --help' -- "$current")
    elif (( COMP_CWORD == 1 )) || { (( COMP_CWORD == 2 )) && [[ "${COMP_WORDS[1]}" == --check || "${COMP_WORDS[1]}" == --recover || "${COMP_WORDS[1]}" == -- ]]; }; then
        while IFS= read -r candidate; do COMPREPLY+=("$candidate"); done < <(compgen -f -- "$current")
    fi
}
complete -F _zsqt_complete zsqt
