
" This is to address how vars are declared without the dollar but must be
" referenced with one. I often want to search vars and not finding one or the
" other due to dollar being part of the name is just bad
setlocal iskeyword+=-
setlocal iskeyword-=$
