# Manual tests

Scripts that need a live Immich and therefore cannot run in CI. The Go tests in
`internal/` cover the same code against a fake server; these exist to check the
behaviour of a real Immich, which has changed under us before.

Both read credentials from the environment and never print them:

```sh
export KIOSK_IMMICH_URL=https://immich.example.net
export KIOSK_IMMICH_API_KEY=...
```

The key needs `stack.read`, plus `person.read` and `person.statistics` for the
person queries.

Outputs go to a temporary directory and are cleaned up. Anything that needs
keeping belongs in `tests/runs/`, which is gitignored.

## stack-api-probe.sh

Measures how Immich's `withStacked` search flag actually behaves, for a given
set of people:

```sh
tests/stack-api-probe.sh <personId> [personId ...]
```

As of Immich v2.x on the filter-based search API, `withStacked` omitted and
`true` are identical and return every stack member, while `false` drops every
stacked asset including the primaries. That is why Kiosk filters stack children
itself rather than passing the flag through — see `show_stack_children`.

Run this after an Immich upgrade. If `false` starts keeping primaries, the
Kiosk-side filter can be replaced by the flag.

## stack-compare.sh

Drives Kiosk itself and counts what it puts on screen, with the stack filter off
and on:

```sh
export KIOSK_NEW_BINARY=./kiosk          # the build under test
tests/stack-compare.sh <slides> <personId> [personId ...]
```

Starts Kiosk on `KIOSK_TEST_PORT` (default 3999), asks for one slide at a time,
and reads the served asset ID out of the history form. Reports how many stack
children were served and how many stacks contributed more than one asset — both
must be zero with the filter on.

`KIOSK_OLD_BINARY` compares against a second build instead of flipping the
option on one. `KIOSK_EXTRA_QUERY` appends options to every run.
