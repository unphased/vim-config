.PHONY: all test

all: test

test:
	zsh -n zprofile
	zsh -n zshrc
	sh -n ssh-server-security-check.sh ghostty-quickdash.sh ghostty-quickdash-ssh-log.sh ghostty-quickdash-ssh-active.sh
	sh -n linux-vt-install.sh linux-vt-startup.sh linux-vt-font-select.sh test-linux-vt.sh
	./test-linux-vt.sh
