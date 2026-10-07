#!/bin/bash
function git_list_branches () {
    current_branch=$(git branch --show-current)
    echo "CurrentBranch-> ${current_branch}"
    echo "--------------------------------"
    git branch -vva
    echo "--------------------------------"
    echo 

}
if [[ "$1" = "--all" ]]
then
	if [ ! -d ./.git ]
	then 
for dir in */
do
    dir=${dir%*/}
    cd $dir
    echo "--------------------------------"
    pwd
    git_list_branches

    cd ..
done
    else 
       git_list_branches
    fi
else 
  
  git_list_branches

fi

