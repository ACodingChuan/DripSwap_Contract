#!/usr/bin/env bash
set -e
DIR="$(pwd)"
osascript <<OSA
tell application "Terminal"
  do script "cd \"$DIR\"; anvil --port 8545 --chain-id 11155111 --block-time 600"
  do script "cd \"$DIR\"; anvil --port 8546 --chain-id 534351  --block-time 600"
  activate
end tell
OSA
