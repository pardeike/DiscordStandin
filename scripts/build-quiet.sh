#!/bin/zsh

set -u

script_dir=${0:A:h}
project_dir=${script_dir:h}
cd "$project_dir" || exit 1
mkdir -p .build/logs || exit 1
build_log=$(mktemp "$project_dir/.build/logs/workflow.XXXXXX") || exit 1

case "${1:-}" in
    "") target=install ;;
    --verify) target=test ;;
    *) print -u2 -r -- "Usage: $0 [--verify]"; exit 2 ;;
esac

make "$target" >"$build_log" 2>&1 &
build_pid=$!
trap 'kill -TERM "$build_pid" 2>/dev/null; wait "$build_pid" 2>/dev/null; print -u2 -r -- "Cancelled. Log: $build_log"; exit 130' INT TERM

if wait "$build_pid"; then
    print -r -- "ok"
    exit 0
fi

print -u2 -r -- "DiscordStandin $target failed. Recent diagnostics:"
tail -n 35 "$build_log" >&2
print -u2 -r -- "Full log: $build_log"
exit 1
