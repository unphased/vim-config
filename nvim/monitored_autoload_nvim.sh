#!/bin/bash

# nvim config develop mode with automatic forced reload

# Set trap to clean children
trap "trap - SIGTERM && kill -- -$$" SIGINT SIGTERM EXIT

echo init new instance... >> .nvim_autoload_monitor.log

MYDIR=${0%/*}

# Run everything from scripts own dir, this is where the state dotfiles will live
pushd "$MYDIR" || ( echo "failed to pushdir to $MYDIR" && exit 2 )

watchexec --exts lua -- 'echo "$WATCHEXEC_WRITTEN_PATH"' | while read -r file; do
  if [ -z $file ]; then continue; fi
  if grep "$file" nvim_config_monitor_refresh_files.txt; then
    echo "$file changed, supposedly, and matched nvim_config_monitor_refresh_files.txt" >> .nvim_autoload_monitor.log
    pid=$(cat .nvim_autoload_monitor.pid)
    echo "firing USR1 at $pid" >> .nvim_autoload_monitor.log
    kill -USR1 "$pid"
    sleep 1
    # if the process is still alive, kill it
    if kill -0 "$pid" 2>/dev/null; then
      echo "killing $pid with TERM" >> .nvim_autoload_monitor.log
      kill -TERM "$pid"
    fi
  fi
done &

# optional utility
BLACK="[30m"
RESET="[0m"

execute () {
  CTR=1
  >&2 echo "Executing the following:"
  for arg in "$@"; do
    >&2 printf "$BLACK"'$'"%s=$RESET%s " $CTR "$arg"
    (( CTR ++ ))
  done
  >&2 echo "" # new line
  "$@"
}

rm -f .nvim_autoload_monitor.completed
echo "Cleared completed sentinel file, launching controlled nvim..." >> .nvim_autoload_monitor.log

# Prep the custom behavior to run nvim with
NVIM_ARGS=(
  '-c'
  ':lua write_to_file(vim.loop.os_getpid(), ".nvim_autoload_monitor.pid")'
  '-c'
  ':autocmd VimLeave * :lua log("Manual vim close"); os.remove(".nvim_autoload_monitor.pid"); write_to_file("completed", ".nvim_autoload_monitor.completed")'
  '-c'
  ':autocmd Signal SIGUSR1 :lua log("quit in response to USR1"); write_to_file(string.format("SIGUSR1 autocmd dying=%d exiting=%s", vim.v.dying, vim.inspect(vim.v.exiting)), ".nvim_autoload_monitor.log"); os.remove(".nvim_autoload_monitor.pid"); vim.cmd(":mksess! auto_sesh") vim.cmd(":qa")'
)

if [ -f .nvim_autoload_monitor.pid ]; then
  >&2 echo "nvim_autoload_monitor already running! Found it here: $(pwd) Aborting nvim launch"
  exit 1
fi
# initial launch passes given args
nvim "$@" "${NVIM_ARGS[@]}"

while true; do
  if [ ! -f .nvim_autoload_monitor.completed ]; then
    # use pid sentinel as a lockfile as well. only allow one process instance with this treatment 

    # TODO Deal with what happens when we chdir inside... just need to hardcode sesh file location.
    nvim -S auto_sesh "${NVIM_ARGS[@]}"
  else
    echo "Neovim dev mode automation completed due to manual user exit. Exiting loop. The terminated job message you may see next should be for the fswatch control loop getting killed. Have a nice day!"
    exit 0
  fi
done
