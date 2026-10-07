#!/bin/bash

function git_prune () {
    git branch -vv
    git fetch -p && git branch --format='%(refname:short) %(upstream:track)' | awk '$2=="[gone]"{print $1}' | xargs -r git branch -d;
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
    git_prune
    cd ..
done
    else 
       git_prune
    fi
else 
  
  git_prune

fi

