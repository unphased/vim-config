#!/bin/bash


# no file watching, files, state needed! wewt.
while [ "$?" != 55 ]; do
  echo waiting a smidge
  sleep 0.2
  nvim -c ":autocmd BufWritePost * :qa" -c ":autocmd VimLeave * :cq 55" "$@"
done

