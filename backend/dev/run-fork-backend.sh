#!/bin/sh
# Start the service against a local BSC fork using the supplied UXUY configuration.
set -eu
cd "$(dirname "$0")/.."
exec cargo run --offline -p uxuy-backend -- "${1:-config.fork.toml}"
