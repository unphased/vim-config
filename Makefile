.PHONY: all test

all: test

test:
	zsh -n zprofile
	zsh -n zshrc
	sh -n ssh-server-security-check.sh
