echo Hi from ~/.zprofile

# Note, the following is insufficient to set homebrew env vars in the proper spots.
eval "$(/opt/homebrew/bin/brew shellenv)"
export PATH="/opt/homebrew/opt/node@16/bin:/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"
