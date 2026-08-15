.PHONY: all test

all: test

test:
	zsh -n zprofile
	zsh -n zshrc
	sh -n ssh-server-security-check.sh
	sh -n linux-vt-install.sh linux-vt-startup.sh linux-vt-font-select.sh test-linux-vt.sh
	./test-linux-vt.sh
