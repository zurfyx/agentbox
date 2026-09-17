# Bash completion for Agentbox. Static by design: do not execute agentbox here.

_agentbox_add_matches() {
  local candidate current=$1
  shift
  for candidate in "$@"; do
    case "$candidate" in
      "$current"*) COMPREPLY[${#COMPREPLY[@]}]=$candidate ;;
    esac
  done
}

_agentbox_complete() {
  local current=${COMP_WORDS[COMP_CWORD]}
  local first=${COMP_WORDS[1]-}
  local lifecycle index word seen_no_update=0 seen_workspace_only=0
  COMPREPLY=()

  # Agentbox owns only the closed prefix of global flags. Once a selector,
  # separator, lifecycle command, or Claude payload has appeared, completion
  # belongs to that command/vendor and ordinary filename fallback remains on.
  for ((index = 1; index < COMP_CWORD; index++)); do
    word=${COMP_WORDS[index]}
    case "$word" in
      --no-update)
        ((seen_no_update == 0)) || return 0
        seen_no_update=1
        ;;
      --workspace-only)
        ((seen_workspace_only == 0)) || return 0
        seen_workspace_only=1
        ;;
      *) break ;;
    esac
  done

  if ((index == COMP_CWORD)); then
    _agentbox_add_matches "$current" claude clauded codex
    ((seen_no_update == 0)) && _agentbox_add_matches "$current" --no-update
    ((seen_workspace_only == 0)) && _agentbox_add_matches "$current" --workspace-only
    if ((index == 1)); then
      _agentbox_add_matches "$current" setup update rollback doctor info
    else
      _agentbox_add_matches "$current" --
    fi
    _agentbox_add_matches "$current" help -h --help --version
    return 0
  fi

  first=${COMP_WORDS[index]}
  [[ $first == claude || $first == clauded || $first == codex || $first == -- ]] && return 0
  if ((index != 1)); then
    case "$first" in
      setup | update | rollback | doctor | info | help | -h | --help | --version) COMPREPLY=("") ;;
    esac
    return 0
  fi

  case "$first" in
    doctor | info) lifecycle=report ;;
    setup) lifecycle=setup ;;
    rollback) lifecycle=rollback ;;
    update) lifecycle=closed ;;
    help | -h | --help | --version) lifecycle=closed ;;
    *) return 0 ;;
  esac

  # A blank candidate prevents Bash's registered filename fallback on strict
  # lifecycle branches when there is nothing valid to offer.
  case "$lifecycle" in
    report)
      local seen_json=0
      for ((index = 2; index < COMP_CWORD; index++)); do
        word=${COMP_WORDS[index]}
        [[ $word == --json ]] && seen_json=1
      done
      ((seen_json == 0)) && _agentbox_add_matches "$current" --json
      ;;
    setup)
      [[ ${COMP_WORDS[2]-} != --reset-selector ]] && _agentbox_add_matches "$current" --reset-selector
      ;;
    rollback)
      [[ ${COMP_WORDS[2]-} != --accept-vendor-state-risk ]] && _agentbox_add_matches "$current" --accept-vendor-state-risk
      ;;
  esac
  ((${#COMPREPLY[@]} == 0)) && COMPREPLY=("")
}

complete -o default -F _agentbox_complete agentbox
