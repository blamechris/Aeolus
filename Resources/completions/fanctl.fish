function __fanctl_should_offer_completions_for_flags_or_options -a expected_commands
    set -l non_repeating_flags_or_options $argv[2..]
    set -l non_repeating_flags_or_options_absent 0
    set -l positional_index 0
    set -l commands
    __fanctl_parse_tokens
    test "$commands" = "$expected_commands"; and return $non_repeating_flags_or_options_absent
end

function __fanctl_should_offer_completions_for_positional -a expected_commands positional_index_comparison expected_positional_index
    set -l non_repeating_flags_or_options
    set -l non_repeating_flags_or_options_absent 0
    set -l positional_index 0
    set -l commands
    __fanctl_parse_tokens
    test "$commands" = "$expected_commands" -a \( "$positional_index" "$positional_index_comparison" "$expected_positional_index" \)
end

function __fanctl_parse_tokens -S
    set -l unparsed_tokens (__fanctl_tokens -pc)
    switch $unparsed_tokens[1]
    case 'fanctl'
        __fanctl_parse_subcommand 0 'version' 'h/help'
        switch $unparsed_tokens[1]
        case 'list'
            __fanctl_parse_subcommand 0 'json' 'version' 'h/help'
        case 'sensors'
            __fanctl_parse_subcommand 0 'json' 'raw-keys' 'version' 'h/help'
        case 'watch'
            __fanctl_parse_subcommand 0 'json' 'interval=' 'count=' 'version' 'h/help'
        case 'reset'
            __fanctl_parse_subcommand 0 'all' 'version' 'h/help'
        case 'dump'
            __fanctl_parse_subcommand 0 'json' 'key=' 'version' 'h/help'
        case 'help'
            __fanctl_parse_subcommand -r 1 'version'
        end
    end
end

function __fanctl_tokens
    if test (string split -m 1 -f 1 -- . "$FISH_VERSION") -gt 3
        commandline --tokens-raw $argv
    else
        commandline -o $argv
    end
end

function __fanctl_parse_subcommand -S -a positional_count
    argparse -s r -- $argv
    set -l option_specs $argv[2..]
    set -l is_repeating_positional $_flag_r
    set -el _flag_r
    set -a commands $unparsed_tokens[1]
    set positional_index 0
    while true
        set -e unparsed_tokens[1]
        argparse -sn "$commands" $option_specs -- $unparsed_tokens 2> /dev/null
        set unparsed_tokens $argv
        set positional_index (math $positional_index + 1)
        for non_repeating_flag_or_option in $non_repeating_flags_or_options
            if set -ql "_flag_$(string replace -a - _ -- $non_repeating_flag_or_option)"
                set non_repeating_flags_or_options_absent 1
                break
            end
        end
        test (count $unparsed_tokens) -eq 0 -o \( -z "$is_repeating_positional" -a "$positional_index" -gt "$positional_count" \) && break
    end
end

function __fanctl_complete_directories
    set -l token (commandline -t)
    string match -- '*/' $token
    set -l subdirs $token*/
    printf %s\n $subdirs
end

function __fanctl_custom_completion
    set -x SAP_SHELL fish
    set -x SAP_SHELL_VERSION $FISH_VERSION
    set -l tokens (__fanctl_tokens -p)
    if test -z "$(__fanctl_tokens -t)"
        set -l index (count (__fanctl_tokens -pc))
        set tokens $tokens[..$index] \'\' $tokens[(math $index + 1)..]
    end
    command $tokens[1] $argv $tokens
end

complete -c 'fanctl' -f
complete -c 'fanctl' -n '__fanctl_should_offer_completions_for_flags_or_options "fanctl" version' -l 'version' -d 'Show the version.'
complete -c 'fanctl' -n '__fanctl_should_offer_completions_for_flags_or_options "fanctl" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'fanctl' -n '__fanctl_should_offer_completions_for_positional "fanctl" -eq 1' -fa 'list' -d 'List fans with their current, minimum, and maximum speeds.'
complete -c 'fanctl' -n '__fanctl_should_offer_completions_for_positional "fanctl" -eq 1' -fa 'sensors' -d 'List every sensor this machine exposes.'
complete -c 'fanctl' -n '__fanctl_should_offer_completions_for_positional "fanctl" -eq 1' -fa 'watch' -d 'Live-updating view of fan speeds, suitable for a terminal left open.'
complete -c 'fanctl' -n '__fanctl_should_offer_completions_for_positional "fanctl" -eq 1' -fa 'reset' -d 'Return fans to automatic control.'
complete -c 'fanctl' -n '__fanctl_should_offer_completions_for_positional "fanctl" -eq 1' -fa 'dump' -d 'Dump every SMC key\'s type, attributes, and raw bytes.'
complete -c 'fanctl' -n '__fanctl_should_offer_completions_for_positional "fanctl" -eq 1' -fa 'help' -d 'Show subcommand help information.'
complete -c 'fanctl' -n '__fanctl_should_offer_completions_for_flags_or_options "fanctl list" json' -l 'json' -d 'Emit JSON instead of a table.'
complete -c 'fanctl' -n '__fanctl_should_offer_completions_for_flags_or_options "fanctl list" version' -l 'version' -d 'Show the version.'
complete -c 'fanctl' -n '__fanctl_should_offer_completions_for_flags_or_options "fanctl list" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'fanctl' -n '__fanctl_should_offer_completions_for_flags_or_options "fanctl sensors" json' -l 'json' -d 'Emit JSON instead of a table.'
complete -c 'fanctl' -n '__fanctl_should_offer_completions_for_flags_or_options "fanctl sensors" raw-keys' -l 'raw-keys' -d 'Show raw SMC keys only, without catalog labels.'
complete -c 'fanctl' -n '__fanctl_should_offer_completions_for_flags_or_options "fanctl sensors" version' -l 'version' -d 'Show the version.'
complete -c 'fanctl' -n '__fanctl_should_offer_completions_for_flags_or_options "fanctl sensors" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'fanctl' -n '__fanctl_should_offer_completions_for_flags_or_options "fanctl watch" json' -l 'json' -d 'Emit newline-delimited JSON (one object per line) instead of a redrawing table.'
complete -c 'fanctl' -n '__fanctl_should_offer_completions_for_flags_or_options "fanctl watch" interval' -l 'interval' -d 'Seconds between refreshes.' -rfka ''
complete -c 'fanctl' -n '__fanctl_should_offer_completions_for_flags_or_options "fanctl watch" count' -l 'count' -d 'Stop after this many refreshes. Runs until Ctrl-C if omitted.' -rfka ''
complete -c 'fanctl' -n '__fanctl_should_offer_completions_for_flags_or_options "fanctl watch" version' -l 'version' -d 'Show the version.'
complete -c 'fanctl' -n '__fanctl_should_offer_completions_for_flags_or_options "fanctl watch" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'fanctl' -n '__fanctl_should_offer_completions_for_flags_or_options "fanctl reset" all' -l 'all' -d 'Reset every fan and drop all leases.'
complete -c 'fanctl' -n '__fanctl_should_offer_completions_for_flags_or_options "fanctl reset" version' -l 'version' -d 'Show the version.'
complete -c 'fanctl' -n '__fanctl_should_offer_completions_for_flags_or_options "fanctl reset" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'fanctl' -n '__fanctl_should_offer_completions_for_flags_or_options "fanctl dump" json' -l 'json' -d 'Emit JSON instead of a table.'
complete -c 'fanctl' -n '__fanctl_should_offer_completions_for_flags_or_options "fanctl dump" key' -l 'key' -d 'Only show this one key (exactly four characters, e.g. VP3b).' -rfka ''
complete -c 'fanctl' -n '__fanctl_should_offer_completions_for_flags_or_options "fanctl dump" version' -l 'version' -d 'Show the version.'
complete -c 'fanctl' -n '__fanctl_should_offer_completions_for_flags_or_options "fanctl dump" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'fanctl' -n '__fanctl_should_offer_completions_for_flags_or_options "fanctl help" version' -l 'version' -d 'Show the version.'
