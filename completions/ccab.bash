# bash completion for ccab
# Source this file or install to bash-completion directory

_ccab_complete()
{
    local cur prev words cword
    _init_completion || return

    case "$prev" in
        -m)
            # Move mode: 1-6
            COMPREPLY=( $(compgen -W "1 2 3 4 5 6" -- "$cur") )
            return ;;
        -t)
            # Metadata directory
            _filedir -d
            return ;;
    esac

    # Positional argument: directory
    if [[ "$cur" == /* || "$cur" == ./* || "$cur" == ../* || -z "$cur" ]]; then
        _filedir -d
        return
    fi

    # Options
    local opts="-c -h -m -t -u -v -x --check"
    COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
}

complete -F _ccab_complete ccab
