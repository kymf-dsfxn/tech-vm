#!/bin/bash

function git_track () {
    local current_branch
    local remote_branch
    local remote_symref
    local local_branch

    current_branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    echo "Current-> ${current_branch:-detached HEAD}"

    git fetch --all --prune || return 1
    git branch -vva

    while IFS=$'\t' read -r remote_branch remote_symref
    do
        [[ -n "$remote_symref" ]] && continue
        [[ "$remote_branch" != */* ]] && continue
        [[ "$remote_branch" == */HEAD ]] && continue

        if [[ "$remote_branch" == origin/* ]]
        then
            local_branch="${remote_branch#origin/}"
        else
            local_branch="$remote_branch"
        fi

        if git show-ref --verify --quiet "refs/heads/$local_branch"
        then
            echo "Skip existing branch -> ${local_branch}"
            continue
        fi

        echo "Create tracking branch -> ${local_branch} (${remote_branch})"
        git branch --track "$local_branch" "$remote_branch" || return 1
    done < <(git for-each-ref --format='%(refname:short)%09%(symref)' refs/remotes)
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
    git_track || exit 1
    cd .. || exit 1
done
    else 
       git_track
    fi
else 
  
  git_track

fi

