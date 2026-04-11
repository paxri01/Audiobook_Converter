#compdef ccab
# zsh completion for ccab

_ccab()
{
    local context state state_descr line
    typeset -A opt_args

    _arguments -s \
        '-c[Combine multiple audio files into one before processing]' \
        '-h[Display help message]' \
        '-m[Move final files to genre directory]:mode:(1 2 3 4 5 6)' \
        '-t[Convert using pre-extracted metadata from directory]:metadata directory:_files -/' \
        '-u[Update existing .info file from a fresh book.html]' \
        '-v[Interactively verify/edit metadata before encoding]' \
        '-x[Extract and search metadata only (no conversion)]' \
        '--check[Check all required dependencies]' \
        ':audiobook directory:_files -/'
}

_ccab "$@"
