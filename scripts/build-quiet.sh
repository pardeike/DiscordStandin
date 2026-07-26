#!/bin/zsh

set -u

script_dir=${0:A:h}
project_dir=${script_dir:h}
build_log=$(mktemp "${TMPDIR:-/tmp}/discordstandin-build.XXXXXX")

cleanup() {
    rm -f "$build_log"
}
trap cleanup EXIT

cd "$project_dir" || exit 1

if make install >"$build_log" 2>&1; then
    print -r -- "ok"
    exit 0
fi

print -u2 -r -- "DiscordStandin build failed:"
cat "$build_log" >&2
exit 1
