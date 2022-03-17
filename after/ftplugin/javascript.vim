" How the hell is this necessary...
setlocal iskeyword-=.

" We used to have this to make it easier to work with class strings in js code, however... prettier 
" broke the assumption that we could just put a space to make -- operator separated from the token. 
" It's just too bad, really.
" setlocal iskeyword+=-
