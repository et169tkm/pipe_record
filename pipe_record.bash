#!/bin/bash
#
# Template to write better bash scripts. More info: http://kvz.io
# Version 0.0.1
#
# Usage:
#  LOG_LEVEL=7 ./template.sh first_arg second_arg
#
# Licensed under MIT
# Copyright (c) 2013 Kevin van Zonneveld
# http://twitter.com/kvz
#

### Configuration
#####################################################################

# Environment variables
[ -z "${LOG_LEVEL}" ] && LOG_LEVEL="3" # 7 = debug -> 0 = emergency

# Commandline options. This defines the usage page, and is used to parse cli opts & defaults from.
# the parsing is unforgiving so be precise in your syntax:
read -r -d '' usage <<-'EOF'
  -d   [arg] Duration (in seconds)
  -n   [arg] Output file name (a number will be appended at the end)
  -x         Enables debug mode
  -h         This page
  -c   [arg] Channel cr1 or cr2 (default: cr2)
EOF

# Set magic variables for current FILE & DIR
__FILE__="$(test -L "$0" && readlink "$0" || echo "$0")"
__DIR__="$(cd "$(dirname "${__FILE__}")"; echo $(pwd);)"


### Functions
#####################################################################

function _fmt ()      {
  color_ok="\x1b[32m"
  color_bad="\x1b[31m"

  color="${color_bad}"
  if [ "${1}" = "debug" ] || [ "${1}" = "info" ] || [ "${1}" = "notice" ]; then
    color="${color_ok}"
  fi

  color_reset="\x1b[0m"
  if [ "${TERM}" != "xterm" ] || [ -t 1 ]; then
    # Don't use colors on pipes or non-recognized terminals
    color=""
    color_reset=""
  fi
  echo -e "$(date -u +"%Y-%m-%d %H:%M:%S UTC") ${color}$(printf "[%9s]" ${1})${color_reset}";
}
function emergency () { echo "$(_fmt emergency) ${@}" || true; exit 1; }
function alert ()     { [ "${LOG_LEVEL}" -ge 1 ] && echo "$(_fmt alert) ${@}" || true; }
function critical ()  { [ "${LOG_LEVEL}" -ge 2 ] && echo "$(_fmt critical) ${@}" || true; }
function error ()     { [ "${LOG_LEVEL}" -ge 3 ] && echo "$(_fmt error) ${@}" || true; }
function warning ()   { [ "${LOG_LEVEL}" -ge 4 ] && echo "$(_fmt warning) ${@}" || true; }
function notice ()    { [ "${LOG_LEVEL}" -ge 5 ] && echo "$(_fmt notice) ${@}" || true; }
function info ()      { [ "${LOG_LEVEL}" -ge 6 ] && echo "$(_fmt info) ${@}" || true; }
function debug ()     { [ "${LOG_LEVEL}" -ge 7 ] && echo "$(_fmt debug) ${@}" || true; }

function help () {
  echo ""
  echo " ${@}"
  echo ""
  echo " ${usage}"
  echo ""
  exit 1
}

function cleanup_before_exit () {
  info "Cleaning up. Done"
  cleanup_after_recording
}
trap cleanup_before_exit EXIT


### Parse commandline options
#####################################################################

# Translate usage string -> getopts arguments, and set $arg_<flag> defaults
while read line; do
  opt="$(echo "${line}" |awk '{print $1}' |sed -e 's#^-##')"
  if ! echo "${line}" |egrep '\[.*\]' >/dev/null 2>&1; then
    init="0" # it's a flag. init with 0
  else
    opt="${opt}:" # add : if opt has arg
    init=""  # it has an arg. init with ""
  fi
  opts="${opts}${opt}"

  varname="arg_${opt:0:1}"
  if ! echo "${line}" |egrep '\. Default=' >/dev/null 2>&1; then
    eval "${varname}=\"${init}\""
  else
    match="$(echo "${line}" |sed 's#^.*Default=\(\)##g')"
    eval "${varname}=\"${match}\""
  fi
done <<< "${usage}"

# Reset in case getopts has been used previously in the shell.
OPTIND=1

# Overwrite $arg_<flag> defaults with the actual CLI options
while getopts "${opts}" opt; do
  line="$(echo "${usage}" |grep "\-${opt}")"


  [ "${opt}" = "?" ] && help "Invalid use of script: ${@} "
  varname="arg_${opt:0:1}"
  default="${!varname}"

  value="${OPTARG}"
  if [ -z "${OPTARG}" ] && [ "${default}" = "0" ]; then
    value="1"
  fi

  eval "${varname}=\"${value}\""
  debug "cli arg ${varname} = ($default) -> ${!varname}"
done

shift $((OPTIND-1))

[ "$1" = "--" ] && shift


### Switches
#####################################################################

# debug mode
if [ "${arg_x}" = "1" ]; then
  set -x
  LOG_LEVEL="7"
fi

# help mode
if [ "${arg_h}" = "1" ]; then
  help "Help using ${0}"
fi


### Validation
#####################################################################

[ -z "${LOG_LEVEL}" ] && emergency "Cannot continue without loglevel. "

# check duration
duration=`echo "$arg_d" | egrep '^[0-9]{1,}$'`
[ -z "${duration}" ]    && help     "Duration must be an integer (of seconds), received \"$duration\""
[ -z "${arg_n}" ]       && help     "Programme name must not be empty"


### Runtime
#####################################################################

# Exit on error. Append ||true if you expect an error.
# set -e is safer than #!/bin/bash -e because that is nutralised if
# someone runs your script like `bash yourscript.sh`
set -e

# Bash will remember & return the highest exitcode in a chain of pipes.
# This way you can catch the error in case mysqldump fails in `mysqldump |gzip`
set -o pipefail

# debug "Info useful to developers for debugging the application, not useful during operations."
# info "Normal operational messages - may be harvested for reporting, measuring throughput, etc. - no action required."
# notice "Events that are unusual but not error conditions - might be summarized in an email to developers or admins to spot potential problems - no immediate action required."
# warning "Warning messages, not an error, but indication that an error will occur if action is not taken, e.g. file system 85% full - each item must be resolved within a given time. This is a debug message"
# error "Non-urgent failures, these should be relayed to developers or admins; each item must be resolved within a given time."
# critical "Should be corrected immediately, but indicates failure in a primary system, an example is a loss of a backup ISP connection."
# alert "Should be corrected immediately, therefore notify staff who can fix the problem. An example would be the loss of a primary ISP connection."
# emergency "A \"panic\" condition usually affecting multiple apps/servers/sites. At this level it would usually notify all tech staff on call."


### Eric's code starts here
####################################################################
pid_file_name='ffmpeg-'`date +%N`'.pid'
loop_pid=-1

function cleanup_after_recording {
    if [ $loop_pid -ge 0 ]; then
        debug "Killing loop ($loop_pid)"
        kill $loop_pid
    fi
    
    if [ -f "$pid_file_name" ]; then
        local pid=`cat "$pid_file_name"`
        rm "$pid_file_name"
        debug "Killing ffmpeg ($pid)"
        kill $pid
    fi
}

function record {
    local URL_CR1=''
    local URL_CR2=''

    local fileno=0
    local name=$1
    local duration=$2 
    local output_file=""
    local url=$URL_CR2

    if [ ${arg_c} == "cr1" ]; then
        url=$URL_CR1
    fi
    if [ ${arg_c} == "cr2" ]; then
        url=$URL_CR2
    fi


    alert "Start recording \"$name\" (duration: $duration)"
    debug "pid_file_name: $pid_file_name"
    debug "fileno: $fileno"
    while true; do
        fileno=$(( fileno+1 ))
        output_file="$name-$fileno.ogg"
        debug "output_file: $output_file"
        alert "Recording to $output_file"
        ( ffmpeg -y -i "$url" -f wav - 2>>"${name}.ffmpeg.log" & echo $! > $pid_file_name) | oggenc -q 1 -o "$output_file" - 2>>"${name}.oggenc.log"
        mv "$output_file" recordings/ || true # or true to avoid the entire script from stopping

        if [ $fileno -ge 0 ]; then
            sleep 1
            alert "ffmpeg ended prematurely, going to sleep for 10 seconds"
            sleep 9
        fi
    done &
    loop_pid=$!

    # kill ffmpeg after the specified duration
    sleep $duration

    alert "time's up, killing recorder"
    exit 0
}

record ${arg_n} ${duration}

