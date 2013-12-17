#!/usr/bin/env bash
# bpm -- Bash Plug-in Manager -- http://netj.github.com/bpm
#   A modular approach to managing and sharing bashrc
# 
# Usage:
#   bpm ls [PLUGIN...]
#   bpm find [PLUGIN...]
#   bpm info PLUGIN...
# 
#   bpm enable PLUGIN...
#   bpm on PLUGIN...
# 
#   bpm disable PLUGIN...
#   bpm off PLUGIN...
# 
#   bpm help
#

################################################################################

BPM=${BASH_SOURCE:-$0}
BPM_HOME=$(cd $(dirname "$BPM") &>/dev/null; pwd)
BPM_TMPDIR=${BPM_TMPDIR:-$(
        d="${TMPDIR:-/tmp}/bpm-$USER"
        mkdir -p "$d"
        chmod go= "$d"
        echo "$d"
    )}

__bpm_msg() { echo bpm: "$@"; }
__bpm_error() { __bpm_msg "$@" >&2; return 1; }
if ${BPM_LOADED:-false}; then
    __bpm_info() { __bpm_msg "$@"; }
else
    __bpm_info() { :; }
fi

################################################################################

__bpm_list() {
    local where=$1; shift
    (
    mkdir -p "$BPM_HOME"/"$where"
    cd "$BPM_HOME"/"$where" &>/dev/null
    [[ $# -gt 0 ]] || set -- *
    eval command ls "$@" 2>/dev/null
    )
}

__bpm_is() {
    local t=$1; shift
    local p=$1; shift
    local negative_msg=${1:-}
    local positive_msg=${2:-}
    if [[ -e "$BPM_HOME"/$t/"$p" || -L "$BPM_HOME"/$t/"$p" ]]; then
        [[ -z "$positive_msg" ]] || __bpm_error "$p: $positive_msg"
    else
        [[ -n "$positive_msg" ]] || __bpm_error "$p: ${negative_msg:-No such bash plug-in}"
    fi
}

__bpm_plugin_info() {
    local p=$1
    local t="$p bash plug-in"
    local bpm_hr1="================================================================================"
    echo "$t"
    echo "${bpm_hr1:0:${#t}}"
    sed <"$BPM_HOME"/plugin/"$p" -n '
    \@^#!/.*bash@, /^###*$/ {
        /^# / s/^# //p
        /^###*$/ q
    }
    '
}

bpm() {
    local Cmd=$1; shift
    local exitcode=0

    case $Cmd in
        find)
            __bpm_list plugin "$@" || __bpm_list plugin "${@/%/*}"
            ;;

        ls)
            __bpm_list enabled "$@" || __bpm_list enabled "${@/%/*}"
            ;;

        info)
            local first_info=true
            local p=
            local bpm_hr2="--------------------------------------------------------------------------------"
            for p; do
                __bpm_is plugin "$p" || continue
                $first_info || { echo "$bpm_hr2"; echo; }; first_info=false
                __bpm_plugin_info "$p"
            done
            ;;

        enable|on)
            (
            mkdir -p "$BPM_HOME"/enabled
            cd "$BPM_HOME"/enabled &>/dev/null
            for p; do
                __bpm_is plugin "$p" || continue
                __bpm_is enabled "$p" "" "Already enabled" || continue
                ln -sfn ../plugin/"$p"
                __bpm_msg "$p: Enabled"
            done
            )
            ;;

        disable|off)
            (
            mkdir -p "$BPM_HOME"/enabled
            cd "$BPM_HOME"/enabled &>/dev/null
            for p; do
                __bpm_is enabled "$p" "Not enabled" || continue
                unlink "$p"
                __bpm_msg "$p: Disabled"
            done
            )
            ;;

        help|*)
            # usage
            sed -n '2,/^#$/ s/^# //p' <"$BPM"
            exitcode=2
            ;;
    esac
    return $exitcode
}

# set up bpm autocompletion
__bpmcomp() {
    local cur prev
    COMPREPLY=()
    _get_comp_words_by_ref cur prev
    if [[ ${#COMP_WORDS[@]} > 2 ]]; then
        case ${COMP_WORDS[1]} in
            find|info)
                COMPREPLY=($(compgen -W "$(bpm find)" -- "$cur"))
                ;;
            enable|on)
                [[ "$BPM_TMPDIR"/enabled.all -nt "$BPM_TMPDIR"/enabled.deps ]] || { sort "$BPM_TMPDIR"/enabled.deps >"$BPM_TMPDIR"/enabled.all; chmod go= "$BPM_TMPDIR"/enabled.all; }
                COMPREPLY=($(compgen -W "$(bpm find | comm -23 - "$BPM_TMPDIR"/enabled.all)" -- "$cur"))
                ;;
            ls|disable|off)
                COMPREPLY=($(compgen -W "$(bpm ls)" -- "$cur"))
                ;;
        esac
    else
        COMPREPLY=($(compgen -W "ls find info enable on disable off help" -- "$cur"))
    fi
}
complete -F __bpmcomp bpm

################################################################################

# compile all enabled plugins
__bpm_list_enabled_by_deps() {
    (
    cd "$BPM_HOME"/enabled &>/dev/null
    local latest=$(command ls -tdL . * | head -n 1)
    # echo $latest >&2
    deps="$BPM_TMPDIR"/enabled.deps
    if [[ "$deps" -nt $latest ]]; then
        cat "$deps"
    else
        __bpm_info "computing dependencies..." >&2
        # analyze the "# Requires: " lines to order by dependencies
        tmp=$(mktemp -d "$BPM_TMPDIR"/enabled.deps.XXXXXX)
        trap 'rm -rf "$tmp"' EXIT
        { echo bpm; command ls; } | tee "$tmp"/more >"$tmp"/seen
        while [[ -s "$tmp"/more ]]; do
            # cat "$tmp"/more >&2; echo >&2
            local ps=$(cat "$tmp"/more; : >"$tmp"/more)
            for p in $ps; do
                local pf="$BPM_HOME"/plugin/"$p"
                [[ -e "$pf" ]] || { __bpm_error "$p: Dangling plugin enabled"; continue; }
                for dep in $(sed -n '/^# Requires: / s/^# Requires: *//p' <"$pf"); do
                    if ! grep -qxF "$dep" "$tmp"/seen; then
                        __bpm_is plugin "$dep" "Unknown plug-in required by $p" || continue
                        echo "$dep" >>"$tmp"/more
                        echo "$dep" >>"$tmp"/seen
                    fi
                    echo "$dep $p"
                done
                # make sure virtual plugin '*' depends on all others
                echo "$p" '*'
                # and all non-bpm plugins depend on the core bpm plugin
                [[ $p = bpm.* || $p = bpm ]] || echo 'bpm' "$p"
            done
        done | tsort | grep -v '^[*]$' |
        tee "$deps"
    fi
    chmod go= "$deps"
    )
}

__bpm_compile() {
    local script=$1; shift
    {
        echo '#!/usr/bin/env bash'
        echo '# bash plugins compiled by bpm (https://github.com/netj/bpm)'
        echo
    } >"$script"
    mkdir -p "$BPM_TMPDIR"/compiled
    local bash_plugin=
    for bash_plugin; do
        local compiled="$BPM_TMPDIR"/compiled/"$bash_plugin"
        local src="$BPM_HOME"/plugin/"$bash_plugin"
        if [[ "$src" -nt "$compiled" || "$BPM" -nt "$compiled" ]]; then
            __bpm_info "compiling $bash_plugin" >&2
            (
            set -e
            unset -f bash_plugin_load bash_plugin_login
            # load the plugin
            . "$src"
            # and generate code
            {
                echo "# $bash_plugin"
                echo '__bpm_load1() {'
                echo 'local bash_plugin='\'"$bash_plugin"\'''
                # parts for all shells
                if type bash_plugin_load &>/dev/null; then
                    type bash_plugin_load | tail -n +3
                fi
                # parts for interactive login shells
                if type bash_plugin_login &>/dev/null; then
                    echo 'if ! [[ ${-//i/} = $- ]] && shopt -q login_shell; then'
                    type bash_plugin_login | tail -n +3
                    echo 'fi'
                fi
                echo '}'
                echo '__bpm_load1'
            } >"$compiled"
            ) || rm -f "$compiled"
        fi
        ! [[ -s "$compiled" ]] || cat "$compiled" >>"$script"
    done
    {
        echo
        echo 'unset -f __bpm_load1'
    } >>"$script"
}

__bpm_compile_enabled() {
    local script="$BPM_TMPDIR"/compiled.enabled.sh
    if [[ "$script" -ot "$BPM_HOME"/plugin ||
          "$script" -ot "$BPM_HOME"/enabled ||
          "$script" -ot "$BPM" ]]; then
        __bpm_info "updating $script" >&2
        __bpm_compile "$script" $(__bpm_list_enabled_by_deps)
    fi
    echo "$script"
}

__bpm_compiled=$(__bpm_compile_enabled)
unset -f __bpm_compile __bpm_compile_enabled __bpm_list_enabled_by_deps

# prepare environment to source the compiled plugin load script
unset -f builtin declare source
__bpm_loader_declared_variables() {
    declare -p | sh -c '
        declare() {
            printf "%s\t%s\t%s\n" "$1" "${2%%=*}" \
# XXX not considering values changes of variables
# "${2//[
#]/\\n}"
        }
        builtin source /dev/stdin
    ' | sort
}
__bpm_loader_hijack_source() {
: ${__bpm_loader_tmpdir:=$(mkdir -p "$BPM_TMPDIR"/loader.$$ && echo "$BPM_TMPDIR"/loader.$$)}
source() {
    # track which variables have changed during source
    __bpm_loader_declared_variables >"$__bpm_loader_tmpdir"/vars.before
    __bpm_loader_preserve_changed_vars() {
        declare -p $(__bpm_loader_declared_variables |
            comm -13 "$__bpm_loader_tmpdir"/vars.before - |
            cut -f2) >"$__bpm_loader_tmpdir"/vars.sourced
    }
    __bpm_loader_source() {
        unset -f source .  # pause hijacking uses of source/.
        trap __bpm_loader_preserve_changed_vars RETURN
        builtin source "$@"
    }
    __bpm_loader_source "$@"
    trap - RETURN
    # declare all changed variables as global
    declare() { builtin declare -g "$@" 2>/dev/null; }
    builtin source "$__bpm_loader_tmpdir"/vars.sourced
    unset -f declare \
        __bpm_loader_source \
        __bpm_loader_preserve_changed_vars \
        #
    __bpm_loader_hijack_source  # resume hijacking uses of source/.
}
.() { source "$@"; }
}
__bpm_loader_hijack_source

# then source the plugins
builtin source "$__bpm_compiled"
BPM_LOADED=true

# and restore the environment
rm -rf -- "$__bpm_loader_tmpdir"
unset -v __bpm_compiled __bpm_loader_tmpdir
unset -f __bpm_loader_declared_variables __bpm_loader_hijack_source source .

################################################################################

# finally, pass any arguments to bpm if given to the script
[[ $# -eq 0 ]] || bpm "$@"
