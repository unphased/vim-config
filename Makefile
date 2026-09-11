HERDR ?= herdr
HERDR_COPY_PANE_ID_DIR := $(CURDIR)/herdr-plugins/copy-pane-id

.PHONY: all test install-herdr-plugins

all: test

test:
	zsh -n zprofile
	zsh -n zshrc zsh/herdr-machine-background.zsh test-herdr-machine-background.zsh
	sh -n herdr-focus.sh ssh-server-security-check.sh ghostty-quickdash.sh ghostty-quickdash-ssh-log.sh ghostty-quickdash-ssh-active.sh
	sh -n linux-vt-install.sh linux-vt-startup.sh linux-vt-font-select.sh test-linux-vt.sh
	bash -n git-lg-full.sh test-herdr-copy-pane-id-plugin.sh
	./test-linux-vt.sh
	zsh test-herdr-machine-background.zsh
	./test-herdr-copy-pane-id-plugin.sh

install-herdr-plugins:
	$(HERDR) plugin link "$(HERDR_COPY_PANE_ID_DIR)"
