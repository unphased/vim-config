#!/bin/sh
:; exec sh "$(dirname "$0")/move-pane-new-tab.sh" "$@"
@echo off
powershell.exe -NoLogo -NoProfile -File "%~dp0move-pane-new-tab.ps1" %*
exit /b %ERRORLEVEL%
