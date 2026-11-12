#!/bin/bash

function require_clean_worktree () {
    if ! git diff --quiet || ! git diff --cached --quiet
    then
        echo "Working tree has tracked changes. Commit or stash before running this script."
        return 1
    fi

    if [[ -n "$(git ls-files --others --exclude-standard)" ]]
    then
        echo "Working tree has untracked files. Commit, stash, or clean before running this script."
        return 1
    fi
}

function git_pull () {
    local current_branch
    local local_branch
    local upstream_ref
    local upstream_branch

    current_branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    if [[ -z "$current_branch" ]]
    then
        echo "Detached HEAD is not supported for pull-all. Check out a branch first."
        return 1
    fi

    restore_branch () {
        git checkout -q "$current_branch" > /dev/null 2>&1 || true
        trap - RETURN
    }

    trap restore_branch RETURN

    echo "CurrentBranch-> ${current_branch}"
    require_clean_worktree || return 1
    echo "--------------------------------"
    git fetch --all --prune || return 1
    echo "--------------------------------"
    git branch -vva

    while IFS=$'\t' read -r local_branch upstream_ref upstream_branch
    do
        if [[ -z "$upstream_ref" ]]
        then
            echo "Skip branch without upstream -> ${local_branch}"
            continue
        fi

        if [[ "$upstream_ref" != refs/remotes/* ]]
        then
            echo "Skip branch with non-remote upstream -> ${local_branch} (${upstream_ref})"
            continue
        fi

        if ! git show-ref --verify --quiet "$upstream_ref"
        then
            echo "Skip branch with missing upstream -> ${local_branch} (${upstream_branch:-$upstream_ref})"
            continue
        fi

        if [[ "$local_branch" != "$current_branch" ]]
        then
            git checkout "$local_branch" || return 1
        fi

        if git merge-base --is-ancestor "$local_branch" "$upstream_ref"
        then
            if [[ "$(git rev-parse "$local_branch")" == "$(git rev-parse "$upstream_ref")" ]]
            then
                echo "Up to date -> ${local_branch}"
            else
                echo "Fast-forward -> ${local_branch} from ${upstream_branch:-$upstream_ref}"
                git merge --ff-only "$upstream_ref" || return 1
            fi
        else
            echo "Skip diverged branch -> ${local_branch} (${upstream_branch:-$upstream_ref})"
        fi
    done < <(git for-each-ref --format='%(refname:short)%09%(upstream)%09%(upstream:short)' refs/heads)

    echo "Return to Initial Branch -> ${current_branch}"
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
    echo "--------------------------------"
    pwd
    git_pull || exit 1
    cd .. || exit 1
done
    else 
       git_pull
    fi
else 
  
  git_pull

fi

