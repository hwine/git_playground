#!/bin/bash -e -u

# demonstrate splitting multi-branched git rep into several single
# branched mercurial repos

# Roughly, we'll:
#   - create a git RoR (repository of record)
#   - clone & convert to hg (interim repo) & push to hg RoR
#
# To show incremental operation, we'll add some changes, then reconvert
#   - add changes to git RoR
#   - update & convert to hg
#   - push to hg RoR

# Simple, right? Start with the boilerplate

DIR_TO_USE=${DIR_TO_USE:-$PWD}
DEBUG_OUT=${DEBUG_OUT:-/dev/null}

GIT_BRANCHES=(
    master
    stabilization
    release
    )
HG_REPOS=(
    hg-dev
    hg-beta
    hg-release
    )
BRANCH_COUNT=${#GIT_BRANCHES[*]}

warn() { for m; do echo "$m"; done 1>&2 ; }
die() { warn "$@"; exit 1; }

# validate arguments from environment
test -d $DIR_TO_USE ||
    die "Not a directory: '$DIR_TO_USE'"
test "$DEBUG_OUT" != "${DEBUG_OUT#/}" ||
    die "DEBUG_OUT must be an absolute path"
test "${#GIT_BRANCHES[*]}" -eq "${#HG_REPOS[*]}" ||
    die "GIT_BRANCHES and HG_REPOS not same size"

init_and_config_hggit() {
    # assume in directory already
    # and allow to be initialized already
    if ! test -d .hg; then
        hg init 
    fi
    # enable hggit and set rtree
    echo >>.hg/hgrc "[extensions]"
    echo >>.hg/hgrc "hggit="
    echo >>.hg/hgrc "[git]"
    echo >>.hg/hgrc "intree=1"
    hg help hggit | grep -q "^hg: unknown command" &&
        die "hggit not installed"
    return 0
}

step_start() {
    step_name=
    echo -n "    $@"
    if test "$DEBUG_OUT" != "/dev/null"; then
        step_name="$1"
        echo "$@ START">>$DEBUG_OUT
    fi
}

step_end() {
    echo " DONE"
    if test "$DEBUG_OUT" != "/dev/null"; then
        echo "$step_name END" >>$DEBUG_OUT
    fi
}


#   - create an hg RoR (repository of record)
GIT_ROR=$DIR_TO_USE/01-git_RoR
if ! test -d $GIT_ROR; then
    echo "The following step would already be done by the project team:"
    step_start "Creating a git RoR (repository of record)"
    {
    mkdir $GIT_ROR
    cd $GIT_ROR
    git init
    # create some files - no variation in content
    echo "file 1" > file_1
    git add file_1
    git commit -m "added file 1"
    echo "file 1" >> file_1
    echo "file 2" > file_2
    git add file_1 file_2
    git commit -m "added file 2"
    # now create content on other branches
    lastbranch=
    for branch in ${GIT_BRANCHES[@]}; do
        git branch $branch $lastbranch || :
        git checkout $branch
        for i in 1 2; do echo "$i$i$i$i on $branch" >> file_$i; done
        git commit -a -m "mods on branch $branch"
        lastbranch="$branch"
    done
    } >>$DEBUG_OUT 2>&1
    step_end
fi

#   - clone & convert to hg (interim repo)
HG_CONVERT=$DIR_TO_USE/02-conversion_to_hg
HG_ROR=$DIR_TO_USE/03-repositories_of_record
if ! test -d $HG_CONVERT; then
    echo -e "\nThe following steps would be done one time only by releng:"
    step_start "Clone & convert to hg (interim repo) & push to hg RoR"
    {
    mkdir $HG_ROR
    mkdir $HG_CONVERT
    cd $HG_CONVERT
    for ((i=0; i<$BRANCH_COUNT; i++)); do
        # make the repo under the hg name
        # we need to do the hg init first, in case the hggit extension
        # is already active (the other order won't work)
        repo_name=${GIT_BRANCHES[$i]}-hggit
        hg  init  $repo_name
        git init  $repo_name
        cd $repo_name
        # point to the branch we care about as origin
        git remote add origin --track ${GIT_BRANCHES[$i]} $GIT_ROR
        git pull
        # now make it an hg repot with hggit capability
        init_and_config_hggit
        # convert to hg format
        hg gimport
        # and add the path to the (not yet created) RoR
        hg_ror_repo_name="${HG_REPOS[$i]}"
        echo >>.hg/hgrc "[paths]"
        echo >>.hg/hgrc "default = $HG_ROR/$hg_ror_repo_name"
        # create the RoR
        hg init $HG_ROR/$hg_ror_repo_name
        # push to the RoR
        hg push
        cd -
    done
    } >>$DEBUG_OUT 2>&1
    step_end
fi

# Note: the remaining steps are not "one time" operations, and will be
#       re-executed every time the script is run
echo -e "\nThe following steps represent a commit cycle:"
step_start "Add changes to git RoR"
{
    cd $GIT_ROR
    branch=${GIT_BRANCHES[$RANDOM % $BRANCH_COUNT]}
    git checkout $branch
    date >>file_2
    git commit -a -m "commit change to $branch"
} >>$DEBUG_OUT 2>&1
step_end

step_start "Update & convert to hg"
{
    # not sure which branch got updated, so do them all
    for branch in ${GIT_BRANCHES[*]}; do
        cd $HG_CONVERT/$branch-hggit
        git pull
        hg qimport
    done
} >>$DEBUG_OUT 2>&1
step_end

step_start "Push to hg RoR"
{
    # not sure which branch got updated, so do them all
    for branch in ${GIT_BRANCHES[*]}; do
        cd $HG_CONVERT/$branch-hggit
        hg push
    done
} >>$DEBUG_OUT 2>&1
step_end

echo "Scenario completed successfully."
exit 0
