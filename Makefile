HERDR ?= herdr
HERDR_CONFIG_DIR ?= $(HOME)/.config/herdr

.PHONY: all test bootstrap-herdr install-herdr-config install-herdr-plugins

all: test

test:
	zsh -n zprofile
	zsh -n zshrc zsh/herdr-machine-background.zsh nvim/shell/nvim-bgcolor.zsh test-herdr-machine-background.zsh test-nvim-bgcolor-hook.zsh
	sh -n herdr-focus.sh herdr-session-context.sh ssh-server-security-check.sh ghostty-quickdash.sh ghostty-quickdash-ssh-log.sh ghostty-quickdash-ssh-active.sh herdr-plugins/copy-pane-id/move-pane-new-workspace.sh herdr-plugins/move-pane-new-tab/move-pane-new-tab.sh
	bash -n herdr-claude-statusline.sh test-herdr-claude-statusline.sh
	sh -n linux-vt-install.sh linux-vt-startup.sh linux-vt-font-select.sh test-linux-vt.sh
	bash -n git-lg-full.sh test-git-lg-full.sh test-herdr-copy-pane-id-plugin.sh test-herdr-focus.sh test-herdr-move-pane-new-tab-plugin.sh test-herdr-plugin-install.sh test-herdr-session-context.sh herdr-plugins/install.sh
	./test-linux-vt.sh
	zsh test-herdr-machine-background.zsh
	zsh test-nvim-bgcolor-hook.zsh
	./test-git-lg-full.sh
	./test-herdr-copy-pane-id-plugin.sh
	./test-herdr-focus.sh
	./test-herdr-move-pane-new-tab-plugin.sh
	./test-herdr-plugin-install.sh
	./test-herdr-session-context.sh
	./test-herdr-claude-statusline.sh
	sh test-herdr-reveal-location.sh
	sh test-nvim-reveal.sh
	$(MAKE) -C herdr-plugins/pane-load test

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
