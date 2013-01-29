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
#   bpm load
#   bpm vocabularies
# 
#   bpm help
#

BPM=${BASH_SOURCE:-$0}
BPM_HOME=$(cd $(dirname "$BPM") &>/dev/null; pwd)
BPM_TMPDIR=${BPM_TMPDIR:-$(d="${TMPDIR:-/tmp}/bpm-$USER"; mkdir -p "$d"; echo "$d")}
bpm() {
    local Cmd=$1; shift
    local exitcode=0

    msg() { echo bpm: "$@"; }
    error() { msg "$@" >&2; return 1; }
    if ${BPM_LOADED:-false}; then
        info() { msg "$@"; }
    else
        info() { :; }
    fi

    local bpm_hr1="================================================================================"
    local bpm_hr2="--------------------------------------------------------------------------------"

    bpm_list() {
        local where=$1; shift
        (
        mkdir -p "$BPM_HOME"/"$where"
        cd "$BPM_HOME"/"$where" &>/dev/null
        [ $# -gt 0 ] || set -- *
        eval command ls "$@" 2>/dev/null
        )
    }

    bpm_is() {
        local t=$1; shift
        local p=$1; shift
        local negative_msg=${1:-}
        local positive_msg=${2:-}
        if [ -e "$BPM_HOME"/$t/"$p" -o -L "$BPM_HOME"/$t/"$p" ]; then
            [ -z "$positive_msg" ] || error "$p: $positive_msg"
        else
            [ -n "$positive_msg" ] || error "$p: ${negative_msg:-No such bash plug-in}"
        fi
    }

    bpm_info() {
        local p=$1
        local t="$p bash plug-in"
        echo "$t"
        echo "${bpm_hr1:0:${#t}}"
        sed <"$BPM_HOME"/plugin/"$p" -n '
        \@^#!/.*bash@, /^###*$/ {
            /^# / s/^# //p
            /^###*$/ q
        }
        '
    }

    bpm_load1() {
        local bash_plugin=$1; shift
        bash_plugin_load() { :; }
        bash_plugin_login() { :; }
        # source the plug-in
        info "loading $bash_plugin"
        . "$BPM_HOME"/plugin/"$bash_plugin"
        # and load it
        bash_plugin_load
        # and load more for login shells
        ! shopt -q login_shell || bash_plugin_login
        unset bash_plugin_{load,login}
    }
    bpm_load() {
        local p=
        for p; do bpm_load1 "$p"; done
    }

    bpm_list_enabled_by_deps() {
        (
        cd "$BPM_HOME"/enabled &>/dev/null
        local latest=$(command ls -tdL . * | head -n 1)
        # echo $latest >&2
        deps="$BPM_TMPDIR"/enabled.deps
        if [ "$deps" -nt $latest ]; then
            cat "$deps"
        else
            info "computing dependencies..." >&2
            # analyze the "# Requires: " lines to order by dependencies
            tmp=$(mktemp -d "$BPM_TMPDIR"/enabled.deps.XXXXXX)
            trap 'rm -rf "$tmp"' EXIT
            command ls | tee "$tmp"/more >"$tmp"/seen
            while [ -s "$tmp"/more ]; do
                # cat "$tmp"/more >&2; echo >&2
                local ps=$(cat "$tmp"/more; : >"$tmp"/more)
                for p in $ps; do
                    local pf="$BPM_HOME"/plugin/"$p"
                    [ -e "$pf" ] || { error "$p: Dangling plugin enabled"; continue; }
                    for dep in $(sed -n '/^# Requires: / s/^# Requires: *//p' <"$pf"); do
                        if ! grep -q "$(printf '^%q$' "$dep")" "$tmp"/seen; then
                            bpm_is plugin "$dep" "Unknown plug-in required by $p" || continue
                            echo "$dep" >>"$tmp"/more
                            echo "$dep" >>"$tmp"/seen
                        fi
                        echo "$dep $p"
                    done
                    echo "$p" '*'
                done
            done | tsort | grep -v '^*$' |
            tee "$deps"
        fi
        )
    }

    case $Cmd in
        find)
            bpm_list plugin "$@" || bpm_list plugin "${@/%/*}"
            ;;

        ls)
            bpm_list enabled "$@" || bpm_list enabled "${@/%/*}"
            ;;

        info)
            local first_info=true
            local p=
            for p; do
                bpm_is plugin "$p" || continue
                $first_info || { echo "$bpm_hr2"; echo; }; first_info=false
                bpm_info "$p"
            done
            ;;

        enable|on)
            (
            mkdir -p "$BPM_HOME"/enabled
            cd "$BPM_HOME"/enabled &>/dev/null
            for p; do
                bpm_is plugin "$p" || continue
                bpm_is enabled "$p" "" "Already enabled" || continue
                ln -sfn ../plugin/"$p"
                msg "$p: Enabled"
            done
            )
            ;;

        disable|off)
            (
            mkdir -p "$BPM_HOME"/enabled
            cd "$BPM_HOME"/enabled &>/dev/null
            for p; do
                bpm_is enabled "$p" "Not enabled" || continue
                unlink "$p"
                msg "$p: Disabled"
            done
            )
            ;;

        vocabularies) # load only vocabularies
            bpm_load $(bpm_list plugin bpm.\*)
            ;;

        load) # load all plug-ins
            bpm_load $(bpm_list_enabled_by_deps)
            BPM_LOADED=true
            ;;

        help|*)
            # usage
            sed -n '2,/^#$/ s/^# //p' <"$BPM"
            exitcode=2
            ;;
    esac
    unset msg error info  bpm_is bpm_info bpm_list bpm_list_enabled_by_deps bpm_load bpm_load1
    return $exitcode
}

# bpm autocompletion
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
                [ "$BPM_TMPDIR"/enabled.all -nt "$BPM_TMPDIR"/enabled.deps ] || sort "$BPM_TMPDIR"/enabled.deps >"$BPM_TMPDIR"/enabled.all
                COMPREPLY=($(compgen -W "$(bpm find | comm -23 - "$BPM_TMPDIR"/enabled.all)" -- "$cur"))
                ;;
            ls|disable|off)
                COMPREPLY=($(compgen -W "$(bpm ls)" -- "$cur"))
                ;;
        esac
    else
        COMPREPLY=($(compgen -W "ls find info enable on disable off vocabularies load help" -- "$cur"))
    fi
}
complete -F __bpmcomp bpm

# pass arguments to bpm if any
[ $# -eq 0 ] || bpm "$@"
