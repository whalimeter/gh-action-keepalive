#!/bin/sh

# If editing from Windows. Choose LF as line-ending


set -eu


# Set this to 1 for more verbosity (on stderr)
KEEPALIVE_VERBOSE=${KEEPALIVE_VERBOSE:-0}

# Entrypoint of the GitHub API
KEEPALIVE_GHAPI=${KEEPALIVE_GHAPI:-"https://api.github.com/"}

# Personal Access Token
KEEPALIVE_TOKEN=${KEEPALIVE_TOKEN:-""}

# Number of seconds to sleep between activity toggle.
KEEPALIVE_SLEEP=${KEEPALIVE_SLEEP:-"1"}

# This uses the comments behind the options to show the help. Not extremly
# correct, but effective and simple.
usage() {
  echo "$0 keeps alive all workflows of repositories passed as arguments" && \
    grep "[[:space:]].)\ #" "$0" |
    sed 's/#//' |
    sed -r 's/([a-z])\)/-\1/'
  exit "${1:-0}"
}

while getopts "t:s:vh-" opt; do
  case "$opt" in
    t) # Personal access token
      KEEPALIVE_TOKEN=$OPTARG;;
    s) # Number of seconds to wait between activity toggle
      KEEPALIVE_SLEEP=$OPTARG;;
    v) # Turn on verbosity
      KEEPALIVE_VERBOSE=1;;
    h) # Print help and exit
      usage;;
    -)
      break;;
    *)
      usage 1;;
  esac
done
shift $((OPTIND-1))


_verbose() {
  if [ "$KEEPALIVE_VERBOSE" = "1" ]; then
    printf %s\\n "$1" >&2
  fi
}

_error() {
  printf %s\\n "$1" >&2
}


# curl wrapper around the GH API. This automatically inserts the authorization
# token and the path to the API
ghapi() {
  _api=$1; shift
  curl -sSL \
    -H "Authorization: token ${KEEPALIVE_TOKEN}" \
    -H "Accept: application/vnd.github.v3+json" \
    "$@" \
    "${KEEPALIVE_GHAPI%/}/repos/${_api}"
}


json_int_field() {
  grep -E "^\\s*\"${1}\"\\s*:" | sed -E "s/\\s*\"${1}\"\\s*:\\s*([0-9]+)\\s*,/\\1/${2:-}"
}

json_str_field() {
  grep -E "^\\s*\"${1}\"\\s*:" | sed -E "s/\\s*\"${1}\"\\s*:\\s*\"([^\"]+)\"\\s*,/\\1/${2:-}"
}

if ! command -v curl >/dev/null 2>&1; then
  _error "This script requires curl installed on the host"
  exit
fi

if [ -z "$KEEPALIVE_TOKEN" ]; then
  _error "No authorization token provided"
  exit
fi

if [ "$#" = "0" ]; then
  usage
fi

for r in "$@"; do
  for id in $(ghapi "${r}/actions/workflows" | json_int_field "id" "g"); do
    state=$(ghapi "${r}/actions/workflows/$id" | json_str_field "state")
    if [ "$state" = "active" ]; then
      _verbose "Toggling off/on workflow $id, sleeping ${KEEPALIVE_SLEEP}s."
      ghapi "${r}/actions/workflows/${id}/disable" -X PUT
      if [ -n "$KEEPALIVE_SLEEP" ]; then
        sleep "$KEEPALIVE_SLEEP"
      fi
      ghapi "${r}/actions/workflows/${id}/enable" -X PUT
    else
      _verbose "Skipping workflow $id, not active"
    fi
  done
done
