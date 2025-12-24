# echo Hi from ~/.zprofile

# Note, the following is insufficient to set homebrew env vars in the proper spots.
eval "$(/opt/homebrew/bin/brew shellenv)"

export PATH="/opt/homebrew/opt/node@16/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/opt/homebrew/opt/python@3/Frameworks/Python.framework/Versions/Current/bin:$PATH"

source ~/.sensitive_app_access_tokens.sh

export PATH="$HOME/go/bin:$PATH"
