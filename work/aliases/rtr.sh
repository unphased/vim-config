sourcertrsetup () {
  CURRENTSHELL="$(ps -o cmd= -p $$ | sed -e 's/^-//' -e 's:.*/::' )"
  WORKSPACE="$(catkin locate)/$1"
  SETUPSCRIPT="$WORKSPACE/setup.$CURRENTSHELL"
  echo sourcing "$SETUPSCRIPT"
  source "$SETUPSCRIPT"
}

sourcertrsetupfoxy() {
  echo sourcing /opt/ros/foxy/setup.sh
  source /opt/ros/foxy/setup.sh
  CURRENTSHELL="$(ps -o cmd= -p $$ | sed -e 's/^-//' -e 's:.*/::' )"
  if [ -f "install/setup.$CURRENTSHELL" ]; then
    echo "sourcing install/setup.$CURRENTSHELL"
    source install/setup.$CURRENTSHELL
  fi
}

if lsb_release -a 2>&1 | grep -q bionic; then
  alias rtr='sourcertrsetup devel'
  alias rtrins='sourcertrsetup install'
fi
if lsb_release -a 2>&1 | grep -q focal; then
  alias rtr='sourcertrsetupfoxy'
fi
