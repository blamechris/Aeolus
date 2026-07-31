#compdef fanctl

__fanctl_complete() {
    local -ar non_empty_completions=("${@:#(|:*)}")
    local -ar empty_completions=("${(M)@:#(|:*)}")
    _describe -V '' non_empty_completions -- empty_completions -P $'\'\''
}

__fanctl_custom_complete() {
    local -a completions
    completions=("${(@f)"$("${command_name}" "${@}" "${command_line[@]}")"}")
    if [[ "${#completions[@]}" -gt 1 ]]; then
        __fanctl_complete "${completions[@]:0:-1}"
    fi
}

__fanctl_cursor_index_in_current_word() {
    if [[ -z "${QIPREFIX}${IPREFIX}${PREFIX}" ]]; then
        printf 0
    else
        printf %s "${#${(z)LBUFFER}[-1]}"
    fi
}

_fanctl() {
    emulate -RL zsh -G
    setopt extendedglob nullglob numericglobsort
    unsetopt aliases banghist

    local -xr SAP_SHELL=zsh
    local -x SAP_SHELL_VERSION
    SAP_SHELL_VERSION="$(builtin emulate zsh -c 'printf %s "${ZSH_VERSION}"')"
    local -r SAP_SHELL_VERSION

    local context state state_descr line
    local -A opt_args

    local -r command_name="${words[1]}"
    local -ar command_line=("${words[@]}")
    local -ir current_word_index="$((CURRENT - 1))"

    local -i ret=1
    local -ar arg_specs=(
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
        '(-): :->command'
        '(-)*:: :->arg'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0
    case "${state}" in
    command)
        local -ar subcommands=(
            'list:List fans with their current, minimum, and maximum speeds.'
            'sensors:List every sensor this machine exposes.'
            'watch:Live-updating view of fan speeds, suitable for a terminal left open.'
            'reset:Return fans to automatic control.'
            'dump:Dump every SMC key'\''s type, attributes, and raw bytes.'
            'help:Show subcommand help information.'
        )
        _describe -V subcommand subcommands && ret=0
        ;;
    arg)
        case "${words[1]}" in
        list|sensors|watch|reset|dump|help)
            "_fanctl_${words[1]}" && ret=0
            ;;
        esac
        ;;
    esac

    return "${ret}"
}

_fanctl_list() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON instead of a table.]'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_fanctl_sensors() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON instead of a table.]'
        '--raw-keys[Show raw SMC keys only, without catalog labels.]'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_fanctl_watch() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit newline-delimited JSON (one object per line) instead of a redrawing table.]'
        '--interval[Seconds between refreshes.]:interval:'
        '--count[Stop after this many refreshes. Runs until Ctrl-C if omitted.]:count:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_fanctl_reset() {
    local -i ret=1
    local -ar arg_specs=(
        '--all[Reset every fan and drop all leases.]'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_fanctl_dump() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON instead of a table.]'
        '--key[Only show this one key (exactly four characters, e.g. VP3b).]:key:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_fanctl_help() {
    local -i ret=1
    local -ar arg_specs=(
        '*:subcommands:'
        '--version[Show the version.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

if [[ "${funcstack[1]}" = _fanctl ]]; then
    _fanctl "${@}"
else
    compdef _fanctl fanctl
fi
