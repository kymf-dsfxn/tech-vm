#!/bin/bash

function git_release_commits_check () {
    #git shortlog remotes/origin/master..remotes/origin/develop
    git log --pretty=format:"%h%x09%an%x09%ad%x09%s" remotes/origin/main..remotes/origin/develop
    echo ""
    echo
}

if [[ "$1" = "--all" ]]
then
	if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1
	then 
for dir in */
do
    dir=${dir%*/}

    if ! git -C "$dir" rev-parse --is-inside-work-tree > /dev/null 2>&1
    then
        continue
    fi

    cd "$dir" || exit 1
    pwd
    git_release_commits_check || exit 1
    cd .. || exit 1
done
    else 
       git_release_commits_check
    fi
else 
  
  git_release_commits_check

fi
