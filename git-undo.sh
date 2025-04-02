#!/bin/bash

function git-undo() {
    if [ "$1" = "drop" ]; then
        git reset --hard HEAD~${2:-1}
    elif [ "$1" = "revert" ]; then
        git revert --no-commit HEAD~${2:-1}..HEAD
        git commit -m "Reverts the last ${2:-1} commit(s)"
    else
        echo "Usage: git-undo [drop|revert] [number of commits]"
        # Indicate failure for incorrect usage
        return 1
    fi
}

# Call the function with all script arguments
git-undo "$@"
