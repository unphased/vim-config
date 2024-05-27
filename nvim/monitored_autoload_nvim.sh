#!/bin/bash

# Use watchexec to monitor configuration files and send SIGUSR1 to Neovim upon changes
watchexec --exts lua --restart --stop-signal=USR1 -- /usr/bin/env nvim "$@"
