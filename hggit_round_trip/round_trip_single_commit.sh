#!/bin/bash -e -u

# demonstrate simple round trip case

# Roughly, we'll:
#   - create an hg RoR (repository of record)
#   - clone & convert to git
#   - push to bare git (simulate push to github)
#   - clone 2x (for fork on github & clone to dev pc)
#   - hook up 2nd git clone with ability to push to hg 
#   - make git commit to 2nd clone
#   - convert to hg & push to RoR
# Now we can start checking for problems. All of the following should be
# smooth (no errors, no odd messages):
#   - process in hg clone
#   - push to mock github
#   - pull to 1st git clone
#   - pull to 2nd git clone
#   - verify no new nodes created

# Simple, right? Start with the boilerplate

DIR_TO_USE=${DIR_TO_USE:-$PWD}
DEBUG_OUT=${DEBUG_OUT:-/dev/null}

warn() { for m; do echo "$m"; done 1>&2 ; }
die() { warn "$@"; exit 1; }

# validate arguments from environment
test -d $DIR_TO_USE ||
    die "Not a directory: '$DIR_TO_USE'"
test "$DEBUG_OUT" != "${DEBUG_OUT#/}" ||
    die "DEBUG_OUT must be an absolute path"

init_and_config_hggit() {
    # assume in directory already
    # and allow to be initialized already
    hg init &>/dev/null || :
    # enable hggit and set rtree
    echo >>.hg/hgrc "[extensions]"
    echo >>.hg/hgrc "hggit="
    echo >>.hg/hgrc "[git]"
    echo >>.hg/hgrc "intree=0"
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
HG_ROR=$DIR_TO_USE/01-hg_RoR
if ! test -d $HG_ROR; then
    echo "The following steps would be done one time only by releng:"
    step_start "Creating an hg RoR (repository of record)"
    {
    mkdir $HG_ROR
    cd $HG_ROR
    init_and_config_hggit
    # create some files - no variation in content
    echo "file 1" > file_1
    hg add file_1
    hg commit -m "added file 1"
    echo "file 1" >> file_1
    echo "file 2" > file_2
    hg add file_2
    hg commit -m "added file 2"
    for i in 1 2; do echo "$i$i$i$i" >> file_$i; done
    hg commit -m "final mods"
    } >>$DEBUG_OUT 2>&1
    step_end
fi

#   - clone & convert to git
git_conversion_01=$DIR_TO_USE/02_git_conversion
if ! test -d $git_conversion_01; then
    step_start "Clone & convert to git"
    {
    mkdir $git_conversion_01
    cd $git_conversion_01
    hg clone --noupdate $HG_ROR in_01
    mkdir out_01
    cd out_01
    git init --bare
    cd -
    cd in_01
    # must create bookmarks for all branches we care about
    init_and_config_hggit
    hg bookmark -r default master
    hg gexport
    cd -
    # now clone that bare repository to have one easier to view with
    # tools like SourceTree
    git clone in_01/.hg/git out_02
    } >>$DEBUG_OUT 2>&1
    step_end
fi

#   - push to bare git (simulate push to github)
GITHUB_MASTER=$DIR_TO_USE/03_github_master
if ! test -d $GITHUB_MASTER; then
    step_start "Push to bare git (simulate push to github)"
    {
    mkdir $GITHUB_MASTER
    cd $GITHUB_MASTER
    git init --bare
    # now push to that
    cd $git_conversion_01/in_01/.hg/git
    git remote add github $GITHUB_MASTER
    git push --all github
    } >>$DEBUG_OUT 2>&1
    step_end
fi

#   - clone 2x (for fork on github & clone to dev pc)
git_clones=$DIR_TO_USE/04_git_clones
DEV_GIT=$git_clones/clone_on_pc
if ! test -d $git_clones/; then
    echo -e "\nThe following steps would be done once by each committer:"
    step_start "Clone 2x (for fork on github & clone to dev pc)"
    {
    mkdir $git_clones/
    cd $git_clones/
    git clone --bare $GITHUB_MASTER fork_on_github
    git clone fork_on_github $DEV_GIT

#   - hook up 2nd git clone with ability to push to hg 
    # this is a hack as we're not testing the scripts
    cp -a $HG_ROR/.hg $DEV_GIT/
    cat >>$DEV_GIT/.hg/hgrc <<EOF
[paths]
hgror = $HG_ROR
EOF

    } >>$DEBUG_OUT 2>&1
    step_end
fi

# Note: the remaining steps are not "one time" operations, and will be
#       re-executed every time the script is run

#   - make git commit to 2nd clone
echo -e "\nThe following steps represent a commit cycle:"
step_start "Make git commit to 2nd clone (dev pc)"
{
cd $DEV_GIT
git rev-list --all >$git_clones/rev_list_pre_commit
date >> file_1
git commit -a -m "commit change on developer's pc"
# save off some state for later comparison
git rev-list --all >$git_clones/rev_list_post_commit
# verify that we did change the repo:
cmp $git_clones/rev_list_pre_commit $git_clones/rev_list_post_commit &&
    die "git commit didn't change repository"
} >>$DEBUG_OUT 2>&1
step_end

#   - convert to hg & push to RoR
step_start "\"super push\" - convert to hg & push to RoR from dev pc"
{
hg gimport
hg push hgror
} >>$DEBUG_OUT 2>&1
step_end

# Now we can start checking for problems. All of the following should be
# smooth (no errors, no odd messages):
#   - process in hg clone
echo -e "\nThe following steps would be done automatically to update github:"
step_start "Push to mock github from RoR"
{
cd $git_conversion_01/in_01
hg pull -u
hg bookmark -f -r default master
hg gexport
#   - push to mock github
git --git-dir .hg/git push --all github
} >>$DEBUG_OUT 2>&1
step_end

echo -e "\nThe following steps are github users updating their local repot:"
#   - pull to 1st git clone
step_start "Pull to 1st git clone (fork on github)"
{
cd $git_clones/fork_on_github
git fetch
} >>$DEBUG_OUT 2>&1
step_end

#   - pull to 2nd git clone
step_start "Pull to 2nd git clone (dev pc)"
{
cd $DEV_GIT
git pull
} >>$DEBUG_OUT 2>&1
step_end

#   - verify no new nodes created
step_start "Verify no new nodes created"
{
git rev-list --all >$git_clones/rev_list_post_pull
# the rev lists had better not have changed
cmp $git_clones/rev_list_post_commit $git_clones/rev_list_post_pull ||
    die "round trip failed!"
} >>$DEBUG_OUT 2>&1
step_end

echo "Scenario completed successfully."
exit 0
