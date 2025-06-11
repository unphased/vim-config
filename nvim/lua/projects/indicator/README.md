# Indicator Neovim Plugin

Indicator is a Neovim plugin designed to help manage and interact with extmarks.

## Features

*   **List Active Namespaces**: Identifies and lists all extmark namespaces that have active marks in the current buffer.
*   **Select Namespaces to Follow**: Provides a user interface (`vim.ui.select`) to choose specific extmark namespaces. The intended purpose is likely to "follow" or highlight marks from these selected namespaces, though the exact "follow" behavior post-selection is a work in progress.

## Commands

*   `:IndicatorFollow`: Opens a picker to select extmark namespaces to follow in the current window.
