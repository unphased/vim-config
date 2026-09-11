HERDR ?= herdr
HERDR_CONFIG_DIR ?= $(HOME)/.config/herdr

.PHONY: all test bootstrap-herdr install-herdr-config install-herdr-plugins

all: test

test:
	zsh -n zprofile
	zsh -n zshrc zsh/herdr-machine-background.zsh test-herdr-machine-background.zsh
	sh -n herdr-focus.sh herdr-session-context.sh ssh-server-security-check.sh ghostty-quickdash.sh ghostty-quickdash-ssh-log.sh ghostty-quickdash-ssh-active.sh herdr-plugins/copy-pane-id/move-pane-new-workspace.sh herdr-plugins/copy-pane-id/move-pane-new-tab.sh
	sh -n linux-vt-install.sh linux-vt-startup.sh linux-vt-font-select.sh test-linux-vt.sh
	bash -n git-lg-full.sh test-herdr-copy-pane-id-plugin.sh test-herdr-plugin-install.sh test-herdr-session-context.sh herdr-plugins/install.sh
	./test-linux-vt.sh
	zsh test-herdr-machine-background.zsh
	./test-herdr-copy-pane-id-plugin.sh
	./test-herdr-plugin-install.sh
	./test-herdr-session-context.sh

bootstrap-herdr: install-herdr-plugins

install-herdr-config:
	@mkdir -p "$(HERDR_CONFIG_DIR)"
	@if [ ! -e "$(HERDR_CONFIG_DIR)/config.toml" ] && [ ! -L "$(HERDR_CONFIG_DIR)/config.toml" ]; then \
		ln -s "$(CURDIR)/herdr.toml" "$(HERDR_CONFIG_DIR)/config.toml"; \
	else \
		echo "keeping existing $(HERDR_CONFIG_DIR)/config.toml"; \
	fi

install-herdr-plugins: install-herdr-config
	HERDR="$(HERDR)" ./herdr-plugins/install.sh
