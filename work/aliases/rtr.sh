sourcertrsetup () {
  CURRENTSHELL="$(ps -o cmd= -p $$ | sed -e 's/^-//' -e 's:.*/::' )"
  WORKSPACE="$(catkin locate)/$1"
  SETUPSCRIPT="$WORKSPACE/setup.$CURRENTSHELL"
  echo sourcing "$SETUPSCRIPT"
  source "$SETUPSCRIPT"
}

sourcertrsetupfoxy() {
  CURRENTSHELL="$(ps -o cmd= -p $$ | sed -e 's/^-//' -e 's:.*/::' )"
  echo "sourcing /opt/ros/foxy/setup.$CURRENTSHELL"
  source "/opt/ros/foxy/setup.$CURRENTSHELL"
  if [ -f "install/setup.$CURRENTSHELL" ]; then
    echo "sourcing install/setup.$CURRENTSHELL"
    source "install/setup.$CURRENTSHELL"
  fi
}

if lsb_release -a 2>&1 | grep -q bionic; then
  alias rtr='sourcertrsetup devel'
  alias rtrins='sourcertrsetup install'
fi
if lsb_release -a 2>&1 | grep -q focal; then
  alias rtr='sourcertrsetupfoxy'
fi
