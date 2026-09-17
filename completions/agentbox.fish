# fish completion for Agentbox. Static by design: do not execute agentbox here.

# Root and lifecycle positions are closed grammars, so suppress file candidates
# only there. Payload positions retain fish's ordinary file completion.
function __agentbox_in_global_prefix
    set -l words (commandline -opc)
    set -e words[1]
    set -l seen_no_update 0
    set -l seen_workspace_only 0
    for word in $words
        switch $word
            case --no-update
                test $seen_no_update -eq 0; or return 1
                set seen_no_update 1
            case --workspace-only
                test $seen_workspace_only -eq 0; or return 1
                set seen_workspace_only 1
            case '*'
                return 1
        end
    end
    return 0
end

function __agentbox_has_global
    set -l words (commandline -opc)
    set -e words[1]
    test (count $words) -gt 0; and __agentbox_in_global_prefix
end

function __agentbox_is_lifecycle -a expected
    set -l words (commandline -opc)
    set -e words[1]
    test (count $words) -gt 0; and test "$words[1]" = "$expected"
end

function __agentbox_in_closed_command
    set -l words (commandline -opc)
    set -e words[1]
    set -l index 1
    set -l seen_no_update 0
    set -l seen_workspace_only 0
    while test $index -le (count $words)
        switch $words[$index]
            case --no-update
                test $seen_no_update -eq 0; or return 1
                set seen_no_update 1
                set index (math $index + 1)
            case --workspace-only
                test $seen_workspace_only -eq 0; or return 1
                set seen_workspace_only 1
                set index (math $index + 1)
            case '*'
                break
        end
    end
    test $index -le (count $words); or return 1
    contains -- "$words[$index]" setup update rollback doctor info help -h --help --version
end

function __agentbox_is_report_lifecycle
    __agentbox_is_lifecycle doctor; or __agentbox_is_lifecycle info
end

complete -c agentbox -f -n '__agentbox_in_global_prefix'
complete -c agentbox -f -n '__agentbox_in_closed_command'

complete -c agentbox -n '__agentbox_in_global_prefix' -a claude -d 'Run Claude Code'
complete -c agentbox -n '__agentbox_in_global_prefix' -a clauded -d 'Run Claude Code without permission prompts'
complete -c agentbox -n '__agentbox_in_global_prefix' -a codex -d 'Run Codex without approval prompts or its sandbox'
complete -c agentbox -n '__fish_is_first_arg' -a setup -d 'Prepare the installed pinned release'
complete -c agentbox -n '__fish_is_first_arg' -a update -d 'Update the Agentbox Homebrew package'
complete -c agentbox -n '__fish_is_first_arg' -a rollback -d 'Select the immediately previous managed release'
complete -c agentbox -n '__fish_is_first_arg' -a doctor -d 'Check installation and managed-state integrity'
complete -c agentbox -n '__fish_is_first_arg' -a info -d 'Show installed and active release information'
complete -c agentbox -n '__agentbox_in_global_prefix' -a help -d 'Show Agentbox help'
complete -c agentbox -n '__agentbox_in_global_prefix; and not __fish_seen_argument -l no-update' -l no-update -d 'Skip lazy installed-release reconciliation'
complete -c agentbox -n '__agentbox_in_global_prefix; and not __fish_seen_argument -l workspace-only' -l workspace-only -d 'Limit host filesystem access to the current workspace'
complete -c agentbox -n '__agentbox_in_global_prefix' -s h -d 'Show Agentbox help'
complete -c agentbox -n '__agentbox_in_global_prefix' -l help -d 'Show Agentbox help'
complete -c agentbox -n '__agentbox_in_global_prefix' -l version -d 'Show the Agentbox version'
complete -c agentbox -n '__agentbox_has_global' -a \-\- -d 'Pass all following arguments to Claude'

complete -c agentbox -n '__agentbox_is_report_lifecycle; and not __fish_seen_argument -l json' -l json -d 'Emit stable JSON'
complete -c agentbox -n '__agentbox_is_lifecycle setup; and not __fish_seen_argument -l reset-selector' -l reset-selector -d 'Replace invalid or held selection with the installed release'
complete -c agentbox -n '__agentbox_is_lifecycle rollback; and not __fish_seen_argument -l accept-vendor-state-risk' -l accept-vendor-state-risk -d 'Acknowledge that vendor state is not rolled back'
