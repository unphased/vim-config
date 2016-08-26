" This is to address vim-perl's making colon a part of keyword in perl.
" I don't really need to use its crazy attempt to parse out module calls 
" to open up the files (itd be real cool if it worked, but still not worth
" making the searches fail to match on those very calls since they become
" huge words)
setlocal iskeyword-=:
setlocal iskeyword-=$

