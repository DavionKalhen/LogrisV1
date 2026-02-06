#!/bin/bash

# Simple HTTP server for the dApp
# Requires Python 3

PORT="${1:-3000}"

echo "Starting dApp server on http://localhost:$PORT"
echo "Press Ctrl+C to stop"

cd "$(dirname "$0")"
python3 -m http.server $PORT
