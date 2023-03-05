#!/bin/bash


# nvim config develop mode with automatic forced reload

# Set trap to clean children
trap "trap - SIGTERM && kill -- -$$" SIGINT SIGTERM EXIT

echo init new instance... >> .nvim_autoload_monitor.log
# TODO debounce me because fswatch is made of jank
fswatch -0 -x init.lua | while read -d "" event; do
  echo "event received $event" >> .nvim_autoload_monitor.log
  if echo "$event" | grep "\<Updated\>"; then
    echo "Received update to watched file. reading pidfile..." >> .nvim_autoload_monitor.log
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

rm -f .nvim_autoload_monitor.completed
echo "Cleared completed sentinel file, launching controlled nvim..." >> .nvim_autoload_monitor.log
while true; do
  if [ ! -f .nvim_autoload_monitor.completed ]; then
    # use pid sentinel as a lockfile as well. only allow one process instance with this treatment 
    if [ -f .nvim_autoload_monitor.pid ]; then
      >&2 echo "nvim_autoload_monitor already running! Aborting nvim launch"
      exit 1
    fi

    nvim "$@" -c ':lua local file = io.open(".nvim_autoload_monitor.pid", "w"); io.output(file); io.write(vim.loop.os_getpid()); io.close(file);' -c ':autocmd VimLeave * :lua log("Manual vim close"); os.remove(".nvim_autoload_monitor.pid"); log("completed", ".nvim_autoload_monitor.completed")' -c ':autocmd Signal SIGUSR1 :lua log("quit in response to USR1"); log(string.format("SIGUSR1 autocmd dying=%d exiting=%s", vim.v.dying, vim.inspect(vim.v.exiting)), ".nvim_autoload_monitor.log"); os.remove(".nvim_autoload_monitor.pid"); vim.cmd(":qa!")'
  else
    echo "Neovim dev mode automation completed due to manual user exit. Exiting loop. The terminated job message you may see next should be for the fswatch control loop getting killed. Have a nice day!"
    exit 0
  fi
done
