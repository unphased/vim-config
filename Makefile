.PHONY: all test

all: test

test:
	zsh -n zprofile
	zsh -n zshrc zsh/herdr-machine-background.zsh test-herdr-machine-background.zsh
	sh -n herdr-focus.sh ssh-server-security-check.sh ghostty-quickdash.sh ghostty-quickdash-ssh-log.sh ghostty-quickdash-ssh-active.sh
	sh -n linux-vt-install.sh linux-vt-startup.sh linux-vt-font-select.sh test-linux-vt.sh
	bash -n git-lg-full.sh
	./test-linux-vt.sh
	zsh test-herdr-machine-background.zsh
