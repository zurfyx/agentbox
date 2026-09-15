# fish completion for Agentbox. Static by design: do not execute agentbox here.

# Root and lifecycle positions are closed grammars, so suppress file candidates
# only there. Payload positions retain fish's ordinary file completion.
complete -c agentbox -f -n '__fish_is_first_arg'
complete -c agentbox -f -n '__fish_seen_subcommand_from setup update rollback doctor info help'

complete -c agentbox -n '__fish_is_first_arg' -a claude -d 'Run Claude Code'
complete -c agentbox -n '__fish_is_first_arg' -a clauded -d 'Run Claude Code without permission prompts'
complete -c agentbox -n '__fish_is_first_arg' -a codex -d 'Run Codex without approval prompts or its sandbox'
complete -c agentbox -n '__fish_is_first_arg; and not __fish_seen_argument -l no-update' -a setup -d 'Prepare the installed pinned release'
complete -c agentbox -n '__fish_is_first_arg; and not __fish_seen_argument -l no-update' -a update -d 'Update the Agentbox Homebrew package'
complete -c agentbox -n '__fish_is_first_arg; and not __fish_seen_argument -l no-update' -a rollback -d 'Select the immediately previous managed release'
complete -c agentbox -n '__fish_is_first_arg; and not __fish_seen_argument -l no-update' -a doctor -d 'Check installation and managed-state integrity'
complete -c agentbox -n '__fish_is_first_arg; and not __fish_seen_argument -l no-update' -a info -d 'Show installed and active release information'
complete -c agentbox -n '__fish_is_first_arg; and not __fish_seen_argument -l no-update' -a help -d 'Show Agentbox help'
complete -c agentbox -n '__fish_is_first_arg; and not __fish_seen_argument -l no-update' -l no-update -d 'Skip lazy installed-release reconciliation'
complete -c agentbox -n '__fish_is_first_arg; and not __fish_seen_argument -l no-update' -l help -d 'Show Agentbox help'
complete -c agentbox -n '__fish_is_first_arg; and not __fish_seen_argument -l no-update' -l version -d 'Show the Agentbox version'
complete -c agentbox -n '__fish_is_first_arg; and __fish_seen_argument -l no-update' -a \-\- -d 'Pass all following arguments to Claude'

complete -c agentbox -n '__fish_seen_subcommand_from doctor info; and not __fish_seen_argument -l json' -l json -d 'Emit stable JSON'
complete -c agentbox -n '__fish_seen_subcommand_from setup; and not __fish_seen_argument -l reset-selector' -l reset-selector -d 'Replace invalid or held selection with the installed release'
complete -c agentbox -n '__fish_seen_subcommand_from rollback; and not __fish_seen_argument -l accept-vendor-state-risk' -l accept-vendor-state-risk -d 'Acknowledge that vendor state is not rolled back'
