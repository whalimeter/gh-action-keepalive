# Keepalive Workflows

Workflows will be automatically disabled by GitHub after 60 days of inactivity
on the default branch. This action is an **attempt** to keep alive all workflows
of the repository in which it is run at regular intervals. The action toggles
off, then on all active workflows in the repository that it is run in. This is
an **attempt** to reset the activity workflow timer and bypass the 60 days
restriction.

## Usage

In most cases, you simply have to arrange for creating a workflow that will run
at regular intervals, e.g. once a week, and run this action as in the following
basic example.

```yaml
name: keepalive

on:
  schedule:
    # Run every sunday at 1:27 UTC
    - cron: '27 1 * * SUN'

jobs:
  keepalive:
    runs-on: ubuntu-latest
    steps:
      - name: keepalive
        uses: efrecon/gh-action-keepalive@main
```

You can also run the action as an extra step in an action that would already be
running from time to time.

This action has good defaults, consult the [action.yml](./action.yml) for a
complete list of inputs and their usage.
