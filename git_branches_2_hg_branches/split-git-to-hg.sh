#!/bin/bash -e -u

# demonstrate converting a multi-branched git rep into several single
# branched mercurial repos

# Roughly, we'll:
#   - create a git RoR (repository of record)
#   - clone & convert to hg (interim repo) & push to hg RoR 2 ways:
#       - git-branch-as-hg-bookmark
#       - git-branch-as-separate-hg-repository (aka repo branching)
#
# To show incremental operation, we'll add some changes, then reconvert
#   - add changes to git RoR
#   - update & convert to hg
#   - push to hg RoR

# Simple, right? Start with the boilerplate

# config {{{
DIR_TO_USE=${DIR_TO_USE:-$PWD}
DEBUG_OUT=${DEBUG_OUT:-/dev/null}

GIT_BRANCHES=(
    master
    stabilization
    release
    )
HG_BRANCHES=(
    hg_dev
    hg_beta
    hg_release
    )
BRANCH_COUNT=${#GIT_BRANCHES[*]}
#}}}
# boilerplate {{{
warn() { for m; do echo "$m"; done 1>&2 ; }
die() { warn "$@"; exit 1; }

# validate arguments from environment
test -d $DIR_TO_USE ||
    die "Not a directory: '$DIR_TO_USE'"
test "$DEBUG_OUT" != "${DEBUG_OUT#/}" ||
    die "DEBUG_OUT must be an absolute path"
test "${#GIT_BRANCHES[*]}" -eq "${#HG_BRANCHES[*]}" ||
    die "GIT_BRANCHES and HG_BRANCHES not same size"
#}}}
init_and_config_hggit() { #{{{
    # assume in directory already
    # and allow to be initialized already
    if ! test -d .hg; then
        hg --config extensions.hggit=/dev/null init 
    fi
    # enable hggit and set rtree
    echo >>.hg/hgrc "[extensions]"
    echo >>.hg/hgrc "hggit="
    echo >>.hg/hgrc "[git]"
    echo >>.hg/hgrc "intree=1"
    hg help hggit | grep -q "^hg: unknown command" &&
        die "hggit not installed"
    return 0
} #}}}
#loghandling {{{
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
#}}}
#   - create an hg RoR (repository of record)#{{{
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
    cd ..
    #git clone --mirror $GIT_ROR $GIT_ROR-2
    #GIT_ROR=$GIT_ROR-2
fi #}}}
#   - clone & convert to hg (interim repo)#{{{
HG_CONVERT=$DIR_TO_USE/02-conversion_to_hg
HG_MIRROR=$DIR_TO_USE/03-hg_converted
if ! test -d $HG_CONVERT; then
    echo -e "\nThe following steps would be done one time only by releng:"
    step_start "Clone & convert to hg (interim repo) & push to hg RoRs"
    {
    mkdir $HG_MIRROR
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
        git remote add -t ${GIT_BRANCHES[$i]} origin $GIT_ROR
        git pull
        # now make it an hg repot with hggit capability
        init_and_config_hggit
        # convert to hg format
        hg gimport 
        # and add the path to the (not yet created) RoR
        hg_ror_repo_name="${HG_BRANCHES[$i]}"
        echo >>.hg/hgrc "[paths]"
        echo >>.hg/hgrc "default = $HG_MIRROR/$hg_ror_repo_name"
        # create the RoR
        hg init $HG_MIRROR/$hg_ror_repo_name
        #### move to the branch name
        ###hg --cwd $HG_MIRROR/$hg_ror_repo_name branch $hg_ror_repo_name
        # push to the RoR
        hg push
        cd -
    done
    } >>$DEBUG_OUT 2>&1
    step_end
    step_start "convert to single hg instance"
    {
        git clone $GIT_ROR converged
        cd converged
        git branch -a |
        while read branch junk ; do
            if test "${branch%HEAD}" != "$branch" \
                 -o "${branch#remote}" == "$branch"; then
                continue
            fi
            ec=0
            git branch --track --force ${branch##*/} $branch &>$DEBUG_OUT || ec=$?
            if test $ec -eq 0 -o $ec -eq 128; then
                # success or branch exists
                :
            else
                die "Unexpected result from branch: $ec"
            fi
        done
        init_and_config_hggit
        hg gimport
        echo >>.hg/hgrc "[paths]"
        echo >>.hg/hgrc "default = $HG_MIRROR/converged"
        # create the RoR
        hg init $HG_MIRROR/converged
        hg outgoing --quiet --bookmarks |
        while read branch hash junk ; do
            hg push --force --bookmark $branch
        done
        cd -

    } >>$DEBUG_OUT 2>&1
    step_end
fi #}}}

#every run{{{
# Note: the remaining steps are not "one time" operations, and will be
#       re-executed every time the script is run
echo -e "\nThe following steps represent one or more commit cycle:"
step_start "Add changes to git RoR"
{
    cd $GIT_ROR
    commits=$(( ($RANDOM % $BRANCH_COUNT) + 1))
    echo -n " ($commits) " >>/dev/tty
    for ((i=1; i <= commits; i++ )); do
        branch=${GIT_BRANCHES[$RANDOM % $BRANCH_COUNT]}
        git checkout $branch
        echo "$branch changed at $(date)" >>file_2
        git commit -a -m "commit change to $branch @ $(date)"
    done
} >>$DEBUG_OUT 2>&1
step_end

old_debug=$DEBUG_OUT
#DEBUG_OUT=/dev/stderr
step_start "Update & convert to hg"
{
    # do the converged repo
    cd $HG_CONVERT/converged
    git pull --force
    # see if any branches added
    git branch -a |
    while read branch junk ; do
        if test "${branch%HEAD}" != "$branch" \
             -o "${branch#remote}" == "$branch"; then
            continue
        fi
        ec=0
        git branch --force --track ${branch##*/} $branch &>$DEBUG_OUT || ec=$?
        if test $ec -eq 0 -o $ec -eq 128; then
            # success or branch exists
            :
        else
            die "Unexpected result from branch: $ec"
        fi
    done
    hg gimport
    # now see if any new bookmarks to push
    hg outgoing --quiet --bookmarks |
    while read branch hash junk ; do
        hg push --force --bookmark $branch
    done
    cd -

    # not sure which branch got updated, so do them all
    for branch in ${GIT_BRANCHES[*]}; do
        cd $HG_CONVERT/$branch-hggit
        git pull
        hg gimport
        cd -
    done
} >>$DEBUG_OUT 2>&1
step_end
DEBUG_OUT=$old_debug

step_start "Push to hg RoR"
{
    # push the converged
    cd $HG_CONVERT/converged
    hg push
    cd -

    # not sure which branch got updated, so do them all
    for branch in ${GIT_BRANCHES[*]}; do
        cd $HG_CONVERT/$branch-hggit
        hg push
    done
} >>$DEBUG_OUT 2>&1
step_end

step_start "Show equality"
{
    # TODO - check for exact commit message
    cd $HG_CONVERT/converged
    git branch -v 
    for b in $(git branch); do
        [[ $b == * ]] && continue
        git log --oneline -n1 $b 
    done
    hg bookmarks 
    for b in $(hg bookmarks); do
        [[ $b != ${b/:/} ]] && continue
        hg log -l 1 -r $b --template "{node|short} {desc|firstline}\n" 
    done
    cd -
} >>$DEBUG_OUT 2>&1
step_end


echo "Scenario completed successfully."
exit 0 #}}}
