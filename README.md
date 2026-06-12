vim-config
==========

My personal vim configuration.

Note that in favor of not having my home folder be itself a git repository 
(which is probably fine but kind of too much git for comfort), I placed the 
.vimrc in here (i.e. so when cloned it will become `~/.vim/.vimrc`) and a good 
way to set it up is 

2. (if you do not already have a `~/.vim` dir) `git clone 
   git@github.com:unphased/vim-config ~/.vim`  
3. back `~/.vimrc` up if it exists. Then delete it.
4. `cd ~ && ln -s .vim/.vimrc .vimrc`  

Linux virtual terminal setup is tracked here too:

```
~/.vim/linux-vt-install.sh
```

That script links the VT palette/setup files into `~/.config` and adds guarded
Bash/Zsh hooks so the root-level setup script only runs when `TERM=linux`.

The installer also sets up the boot-time VT setup service by default. It
applies the user files first, then asks sudo only for the systemd unit:

```
~/.vim/linux-vt-install.sh
```

Use `--force` only if an existing local `~/.config/tty-pastel` file should be
replaced by the tracked symlink.
Use `--no-systemd` only when the system unit should be left untouched.
The systemd install syncs a root-owned runtime copy into `/etc/linux-vt` so the
unit does not execute scripts directly from the home directory.

Windows and Windows Terminal
----------------------------

Git Bash normally maps the Windows profile directory to its Unix-style home:

```
C:\Users\<user>  ==  /c/Users/<user>  ==  ~
```

That is expected for current Git for Windows. Clone this repository from Git
Bash with:

```
git clone -c core.symlinks=true git@github.com:unphased/vim-config ~/.vim
```

Windows symlinks work on NTFS/ReFS, but Git for Windows does not enable them by
default. Enable Windows Developer Mode before cloning so Git can create this
repository's `nvim/after` and `nvim/colors` links without an elevated shell.
Git Bash's `ln -s` is not a reliable way to create native Windows links; use
`cmd.exe /c mklink` when a native link must be created manually.

Windows Terminal owns its `settings.json` under `%LOCALAPPDATA%`; it is not
looked up from the Git Bash home directory. The exact Store-package paths are:

```
Stable:  %LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json
Preview: %LOCALAPPDATA%\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json
Canary:  %LOCALAPPDATA%\Packages\Microsoft.WindowsTerminalCanary_8wekyb3d8bbwe\LocalState\settings.json
```

An unpackaged installation uses:

```
%LOCALAPPDATA%\Microsoft\Windows Terminal\settings.json
```

Start Windows Terminal once, then apply the portable settings from PowerShell:

```
& "$HOME\.vim\windowsTerminal\install.ps1"
```

If more than one Terminal edition is installed, select one explicitly:

```
& "$HOME\.vim\windowsTerminal\install.ps1" -Edition Stable
```

The installer backs up the live file and merges
`windowsTerminal/portable-settings.json` into it. It deliberately preserves
the machine's generated profiles and unrelated key bindings. The older
`windowsTerminal/settings.json`, `windowsTerminalPreview.settings.json`, and
`default_windowsTerminalSettings.json` files remain historical snapshots; do
not copy them wholesale onto a current installation.
