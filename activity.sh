#!/bin/sh

# If editing from Windows. Choose LF as line-ending

set -eu

# Set this to 1 for more verbosity (on stderr)
ACTIVITY_VERBOSE=${ACTIVITY_VERBOSE:-0}

# Entrypoint of the GitHub API
ACTIVITY_GHAPI=${ACTIVITY_GHAPI:-"https://api.github.com/"}

# Personal Access Token
ACTIVITY_TOKEN=${ACTIVITY_TOKEN:-""}

# Git Branch to operate on, empty means default GitHub branch
ACTIVITY_BRANCH=${ACTIVITY_BRANCH:-""}

# Time since last commit to trigger fake activity (41 days in seconds by
# default)
ACTIVITY_TIMEOUT=${ACTIVITY_TIMEOUT:-"3542400"}

# Where workflow files are located within a repository
ACTIVITY_WORKFLOWS_DIR=${ACTIVITY_WORKFLOWS_DIR:-".github/workflows"}

# Path to file to actualise whenever activity needs to be generated onto the
# repository and no workflow is passed as a parameter.
ACTIVITY_LIVENESS_PATH=${ACTIVITY_LIVENESS_PATH:-".github/.github_liveness.txt"}

# Activity marker to add/use within activity marker file to keep track of
# changes
ACTIVITY_MARKER=${ACTIVITY_MARKER:-"Last GitHub activity at:"}

# user and email of commit author
ACTIVITY_AUTHOR_NAME=${ACTIVITY_AUTHOR_NAME:-"github-actions"}
ACTIVITY_AUTHOR_EMAIL=${ACTIVITY_AUTHOR_EMAIL:-"github-actions@github.com"}

# This uses the comments behind the options to show the help. Not extremly
# correct, but effective and simple.
usage() {
  echo "$0 keeps alive the github repository passed as 2nd argument (empty for current). 1st arg is name of workflow to use for marker, or empty." && \
    grep "[[:space:]].)\ #" "$0" |
    sed 's/#//' |
    sed -r 's/([a-z])\)/-\1/'
  exit "${1:-0}"
}

while getopts "t:s:m:l:vfh-" opt; do
  case "$opt" in
    t) # Personal access token
      ACTIVITY_TOKEN=$OPTARG;;
    m) # Time since last activity to trigger fake commit (in seconds)
      ACTIVITY_TIMEOUT=$OPTARG;;
    l) # Path to file to create/update with marker when activity needs to be recorded and no workflow is passed as an argument
      ACTIVITY_LIVENESS_PATH=$OPTARG;;
    v) # Turn on verbosity
      ACTIVITY_VERBOSE=1;;
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
  if [ "$ACTIVITY_VERBOSE" = "1" ]; then
    printf %s\\n "$1" >&2
  fi
}

_warn() { printf %s\\n "$1" >&2; }
_error() { _warn "$1" && exit 1; }

# curl wrapper around the GH API. This automatically inserts the authorization
# token and the path to the API
ghapi() {
  _api=$1; shift
  curl -sSL \
    -H "Authorization: token ${ACTIVITY_TOKEN}" \
    -H "Accept: application/vnd.github.v3+json" \
    "$@" \
    "${ACTIVITY_GHAPI%/}/repos/${_api}"
}


json_int_field() {
  grep -E "^\\s*\"${1}\"\\s*:" | sed -E "s/\\s*\"${1}\"\\s*:\\s*([0-9]+)\\s*,/\\1/${2:-}"
}

json_str_field() {
  grep -E "^\\s*\"${1}\"\\s*:" | sed -E "s/\\s*\"${1}\"\\s*:\\s*\"([^\"]+)\"\\s*,/\\1/${2:-}"
}

branch() {
  if [ -z "$ACTIVITY_BRANCH" ]; then
    _verbose "Detecting default branch for $1 at GitHub"
    ghapi "$1" | json_str_field "default_branch" | head -n 1
  else
    printf %s\\n "$ACTIVITY_BRANCH"
  fi
}

branch_exists() { git branch --quiet --no-color --format '%(refname:short)' | grep -q "${1:-"main"}"; }

workflow_name() {
  grep -E '^name:' "$1" |
    sed -E \
      -e 's/^name:\s*//' \
      -e 's/^"//' \
      -e 's/"$//' \
      -e "s/^'//" \
      -e "s/'\$//"
}

workflow_path() {
  if [ -z "$1" ]; then
    # Empty? Return the path to the liveness activity marker file, making sure
    # we have a directory and the file exists.
    mkdir -p "$(dirname "$ACTIVITY_LIVENESS_PATH")"
    touch "$ACTIVITY_LIVENESS_PATH"
    printf %s\\n "$ACTIVITY_LIVENESS_PATH"
  elif printf %s\\n "$1" | grep -Eq '\.ya?ml$'; then
    if printf %s\\n "$1" | grep -Fq "$ACTIVITY_WORKFLOWS_DIR"; then
      printf %s\\n "$1"
    else
      printf %s/%s\\n "${ACTIVITY_WORKFLOWS_DIR%/}" "$1"
    fi
  else
    find "$ACTIVITY_WORKFLOWS_DIR" -name '*.yml' -o -name '*.yaml' | while IFS=$(printf \\n) read -r path; do
      if [ "$(workflow_name "$path")" = "$1" ]; then
        printf %s\\n "$path"
        break
      fi
    done
  fi
}

workflow_mark() {
  marker=$(printf '# %s %s\n' "$ACTIVITY_MARKER" "$(date -Iseconds)")
  if grep -Eq "^#+\\s+${ACTIVITY_MARKER}" "$1"; then
    sed -i -E -e "s/^#+\\s+${ACTIVITY_MARKER}.*/${marker}/g" "$1"
  else
    printf '%s\n' "$marker" >> "$1"
  fi
  _verbose "Marked workflow at $1 with current ISO date"
}

# Work only on a single repo
if [ "$#" -eq "0" ] || [ "$#" -gt "2" ]; then
  usage
fi

# Get workflow name
ACTIVITY_WORKFLOW=$1

# When no repository is provided, take a good guess at the current one.
if [ "$#" -eq "1" ]; then
  ACTIVITY_REPO=$(git config --get remote.origin.url | sed -e 's/^git@.*:\([[:graph:]]*\).git/\1/')
  _verbose "Defaulting to current repo: $ACTIVITY_REPO"
else
  ACTIVITY_REPO=$2
fi

# Refuse to continue when binaray dependencies missing
for dep in curl git; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    _error "This script requires $dep installed on the host"
  fi
done

# We need a way to talk to GH when no default activity branch is specified.
if [ -z "$ACTIVITY_TOKEN" ] && [ -z "$ACTIVITY_BRANCH" ]; then
  _error "No authorization token provided"
fi

# Detect default branch for repository and the one that we are at.
branch_default=$(branch "$ACTIVITY_REPO")
branch_current=$(git rev-parse --abbrev-ref HEAD)
_verbose "Default branch: $branch_default, currently on: $branch_current"

# Detect number of seconds since latest commit onto the default branch
if branch_exists "$branch_default"; then
  date_activity=$(date -d "$(git log -1 --format=%cd --date=iso-strict "$branch_default")" +%s)
else
  date_activity=0;  # no branch? => never active!
fi
date_now=$(date +%s)
elapsed=$(( date_now - date_activity ))

# If too long has elapsed, generate a commit onto the workflow file that
# actually called this action.
exit_code=0
if [ "$elapsed" -gt "$ACTIVITY_TIMEOUT" ]; then
  _verbose "No activity for ${elapsed}s. (> ${ACTIVITY_TIMEOUT}s.)"

  # Change to the default branch as this is where activity detection happens at
  # github.
  if [ "$branch_current" != "$branch_default" ]; then
    if branch_exists "$branch_default"; then
      git switch "$branch_default"
    else
      git switch --create "$branch_default"
    fi
  fi
  exit

  # Resolve workflow id or path to its location on disk. This is the file that
  # we will be pushing a commit onto.
  ACTIVITY_WORKFLOW=$(workflow_path "$ACTIVITY_WORKFLOW")
  if [ -z "$ACTIVITY_WORKFLOW" ] || ! [ -f "$ACTIVITY_WORKFLOW" ]; then
    _warn "Cannot find workflow $1 (looked in $ACTIVITY_WORKFLOWS_DIR)"
    exit_code=1
  else
    # Initialise git and make sure we have all changes
    git config user.name "$ACTIVITY_AUTHOR_NAME"
    git config user.email "$ACTIVITY_AUTHOR_EMAIL"
    git pull -f

    # Add/change marker on the workflow file
    workflow_mark "$ACTIVITY_WORKFLOW"

    # Push the change to git, so to GitHub
    git add "$ACTIVITY_WORKFLOW"
    git commit -m "Forced activity to bypass GH workflows liveness toggling"
    git push
    _verbose "Pushed change to git remote"
  fi

  # Change back to the branch that was current if relevant
  if [ "$branch_current" != "$branch_default" ]; then
    git switch "$branch_current"
  fi
fi

exit "$exit_code"
