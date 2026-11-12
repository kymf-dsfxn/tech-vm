#!/bin/bash
function git_gc () {
    git gc --aggressive
    #git gc
}

if [[ "$1" = "--all" ]]
then
	if [ ! -d ./.git ]
	then 
for dir in */
do
    dir=${dir%*/}
    cd $dir
    pwd

    git_gc
    cd ..
done
    else 
       git_gc
    fi
else 
  
  git_gc

fi

