#!/usr/bin/env sh
set -eu

printf '%s\n' "$*" > "$YJL_FAKE_ARGS"
printf 'INF Your quick Tunnel has been created! Visit it at https://unit-test.trycloudflare.com\n'
