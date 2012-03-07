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

warn() { for m; do echo "$m"; done 1>&2 ; }
die() { warn "$@"; exit 1; }

test -d $DIR_TO_USE || die "Not a directory: '$DIR_TO_USE'"

init_and_config_hggit() {
    # assume in directory already
    # and allow to be initialized already
    hg init &>/dev/null || :
    # enable hggit and set rtree
    echo >>.hg/hgrc "[extensions]"
    echo >>.hg/hgrc "hggit="
    echo >>.hg/hgrc "[git]"
    echo >>.hg/hgrc "intree=1"
    hg help hggit | grep -q "^hg: unknown command" &&
        die "hggit not installed"
    return 0
}


#   - create an hg RoR (repository of record)
HG_ROR=$DIR_TO_USE/01-hg_RoR
if ! test -d $HG_ROR; then
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
fi

#   - clone & convert to git
git_conversion_01=$DIR_TO_USE/02_git_conversion
if ! test -d $git_conversion_01; then
    mkdir $git_conversion_01
    cd $git_conversion_01
    hg clone $HG_ROR in_01
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
    git clone in_01/.git out_02
fi

#   - push to bare git (simulate push to github)
GITHUB_MASTER=$DIR_TO_USE/03_github_master
if ! test -d $GITHUB_MASTER; then
    mkdir $GITHUB_MASTER
    cd $GITHUB_MASTER
    git init --bare
    # now push to that
    cd $git_conversion_01/in_01
    git remote add github $GITHUB_MASTER
    git push --all github
fi

#   - clone 2x (for fork on github & clone to dev pc)
git_clones=$DIR_TO_USE/04_git_clones
DEV_GIT=$git_clones/clone_on_pc
if ! test -d $git_clones/; then
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

fi

# Note: the remaining steps are not "one time" operations, and will be
#       re-executed every time the script is run

#   - make git commit to 2nd clone
cd $DEV_GIT
git rev-list --all >$git_clones/rev_list_pre_commit
date >> file_1
git commit -a -m "commit change on developer's pc"
# save off some state for later comparison
git rev-list --all >$git_clones/rev_list_post_commit
# verify that we did change the repo:
cmp $git_clones/rev_list_pre_commit $git_clones/rev_list_post_commit &&
    die "git commit didn't change repository"
#   - convert to hg & push to RoR
hg gimport
hg push hgror

# Now we can start checking for problems. All of the following should be
# smooth (no errors, no odd messages):
#   - process in hg clone
cd $git_conversion_01/in_01
hg pull -u
hg bookmark -f -r default master
hg gexport
#   - push to mock github
git push --all github

#   - pull to 1st git clone
cd $git_clones/fork_on_github
git fetch

#   - pull to 2nd git clone
cd $DEV_GIT
git pull
#   - verify no new nodes created
git rev-list --all >$git_clones/rev_list_post_pull
# the rev lists had better not have changed
cmp $git_clones/rev_list_post_commit $git_clones/rev_list_post_pull ||
    die "round trip failed!"
