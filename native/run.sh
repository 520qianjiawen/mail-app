#!/bin/bash
set -euo pipefail
native_root="$(cd "$(dirname "$0")" && pwd)"
native_app="$(bash "$native_root/build.sh" | tail -n 1)"
exec "$native_app/Contents/MacOS/Mail Lite"
