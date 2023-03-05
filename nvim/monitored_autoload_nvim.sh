#!/bin/bash

# nvim config develop mode with automatic forced reload

# Set trap to clean children
trap "trap - SIGTERM && kill -- -$$" SIGINT SIGTERM EXIT

echo init new instance... >> .nvim_autoload_monitor.log

MYDIR=${0%/*}

# TODO debounce me, because fswatch is made of jank
watchexec -w $MYDIR/init.lua -w $MYDIR/lua/plugins.lua -w $MYDIR/lua/heirline_conf/heirline.lua -- 'echo "$WATCHEXEC_WRITTEN_PATH"' | while read -r file; do
  if [ -z $file ]; then continue; fi
  echo "$file changed, supposedly" >> .nvim_autoload_monitor.log
  pid=$(cat .nvim_autoload_monitor.pid)
  echo "firing USR1 at $pid" >> .nvim_autoload_monitor.log
  kill -USR1 "$pid"
  sleep 1
  # if the process is still alive, kill it
  if kill -0 "$pid" 2>/dev/null; then
    echo "killing $pid with TERM" >> .nvim_autoload_monitor.log
    kill -TERM "$pid"
  fi
done &

# optional utility
RED="[31m"
BLUE="[34m"
YELLOW="[33m"
GREEN="[32m"
MAGENTA="[35m"
CYAN="[36m"
WHITE="[37m"
BLACK="[30m"
INVERTED="[7m"
BOLD="[1m"
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
  ':lua local file = io.open(".nvim_autoload_monitor.pid", "w"); io.output(file); io.write(vim.loop.os_getpid()); io.close(file);'
  '-c'
  ':autocmd VimLeave * :lua log("Manual vim close"); os.remove(".nvim_autoload_monitor.pid"); log("completed", ".nvim_autoload_monitor.completed")'
  '-c'
  ':autocmd Signal SIGUSR1 :lua log("quit in response to USR1"); log(string.format("SIGUSR1 autocmd dying=%d exiting=%s", vim.v.dying, vim.inspect(vim.v.exiting)), ".nvim_autoload_monitor.log"); os.remove(".nvim_autoload_monitor.pid"); vim.cmd(":mksess! auto_sesh") vim.cmd(":qa!")'
)

if [ -f .nvim_autoload_monitor.pid ]; then
  >&2 echo "nvim_autoload_monitor already running! Aborting nvim launch"
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
