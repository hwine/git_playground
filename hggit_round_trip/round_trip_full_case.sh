#!/bin/bash -e -u

# demonstrate full round trip case

USAGE="usage: ${0##*/} [steps]
Without any steps, perform the built-in series. All commits are made in
a way to ensure no conflicts will occur.

Steps are:
    dc | dev    simulate a contributor commit
    cc | own    simulate a commit by the committer
    land-other  land the contributor's commit
    land-own    land the committer's changes to hg.m.o

Example:
    $0 dc dc land-other cc land-own
"



# Roughly, we'll:
#   - create an hg RoR (repository of record)
#   - clone & convert to git
#   - push to bare git (simulate push to github)
#   - clone 2x (for fork on github & clone to contributor pc)
#   - clone 2x (for fork on github & clone to committer pc)
#   - hook up 2nd git clone with ability to push to hg 
# Now we can mimic dev activity, using some additional scripts, so the
# order can be easily changed
#   - contributor dev cycle (commit back to fork)
#   - committer commit cycle (pull from committer, push via hg.m.o)
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
usage() { warn "$@" "$USAGE"; test $# -eq 0 ; exit $? ; }

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


do_setup_if_needed() {
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
    git_clones=$DIR_TO_USE/05_full_trip_git_clones
    COMMITTER_REPO=$git_clones/committer_pc
    CONTRIBUTOR_FORK=$git_clones/fork_on_github_for_contributer
    CONTRIBUTOR_REPO=$git_clones/contributer_pc
    if ! test -d $git_clones/; then
        echo -e "\nThe following steps would be done once by each committer:"
        step_start "Clone 2x (for fork on github & clone to committer's pc)"
        {
        mkdir $git_clones/
        cd $git_clones/
        git clone --bare $GITHUB_MASTER fork_on_github_for_committer
        git clone fork_on_github_for_committer $COMMITTER_REPO
        git --git-dir $COMMITTER_REPO/.git remote add github_master $GITHUB_MASTER
        git --git-dir $COMMITTER_REPO/.git checkout -b work_branch

    #   - hook up 2nd git clone with ability to push to hg 
        # this is a hack as we're not testing the scripts
        cp -a $HG_ROR/.hg $COMMITTER_REPO/
        cat >>$COMMITTER_REPO/.hg/hgrc <<EOF
[paths]
hgror = $HG_ROR
EOF

        } >>$DEBUG_OUT 2>&1
        step_end
        step_start "Clone 2x (for fork on github & clone to contributor's pc)"
        {
        cd $git_clones/
        git clone --bare $GITHUB_MASTER $CONTRIBUTOR_FORK
        git clone $CONTRIBUTOR_FORK $CONTRIBUTOR_REPO
        git --git-dir $CONTRIBUTOR_REPO/.git remote add github_master $GITHUB_MASTER
        git --git-dir $CONTRIBUTOR_REPO/.git checkout -b work_branch

        } >>$DEBUG_OUT 2>&1
        step_end
    fi
}

# Note: the remaining steps are not "one time" operations, and will be
#       re-executed every time the script is run

#   - make git commit to contributor's 2nd clone
declare -i contributor_commit_number=0
make_contributor_commit() {
    echo -e "\nDevelopment by a contributor:"
    step_start "Update local repo to latest (note no conflicts)"
    {
    cd $CONTRIBUTOR_REPO
    : $((contributor_commit_number++))
    git checkout work_branch
    git pull $GITHUB_MASTER master # get up to date
    } >>$DEBUG_OUT 2>&1
    step_end
    step_start "Make git commit to contributor pc"
    {
    git rev-list --all >$git_clones/rev_list_pre_commit
    date >> file_1
    git commit -a -m "commit change on contributor's pc"
    # save off some state for later comparison
    git rev-list --all >$git_clones/rev_list_post_commit
    # verify that we did change the repo:
    cmp $git_clones/rev_list_pre_commit $git_clones/rev_list_post_commit &&
        die "git commit didn't change repository"
    } >>$DEBUG_OUT 2>&1
    step_end

    #   - convert to hg & push to RoR
    step_start "push to contributor's github fork"
    {
        git push origin work_branch
    } >>$DEBUG_OUT 2>&1
    step_end
}

#   - make git commit to committer's 2nd clone
declare -i committer_commit_number=0
make_committer_commit() {
    echo -e "\nDevelopment by committer:"
    step_start "Update local repo to latest (note no conflicts)"
    {
    cd $COMMITTER_REPO
    : $((committer_commit_number++))
    git checkout work_branch
    git pull $GITHUB_MASTER master # get up to date
    } >>$DEBUG_OUT 2>&1
    step_end
    step_start "Make git commit to committer pc"
    {
    git rev-list --all >$git_clones/rev_list_pre_commit
    # make at top of file to avoid conflicts
    date > file_1.tmp
    cat file_1 >> file_1.tmp
    mv file_1.tmp file_1
    git commit -a -m "commit change on committer's pc"
    # save off some state for later comparison
    git rev-list --all >$git_clones/rev_list_post_commit
    # verify that we did change the repo:
    cmp $git_clones/rev_list_pre_commit $git_clones/rev_list_post_commit &&
        die "git commit didn't change repository"
    } >>$DEBUG_OUT 2>&1
    step_end

    #   - convert to hg & push to RoR
    step_start "push to committer's github fork"
    {
        git push
    } >>$DEBUG_OUT 2>&1
    step_end
}

super_push() {
    # this would just be one step/command for the end user in the final
    # scenario. For the demo, we're peeking behind the curtain.
    hg gimport
    hg push hgror
    # and loop it back to the github master
    cd $git_conversion_01/in_01
    hg pull -u
    hg bookmark -f -r default master
    hg gexport
    #   - push to mock github
    git --git-dir .hg/git push --all github
}

#   - make commit to RoR from committer's own repo
land_from_own_repo() {
    echo -e "\nLand own (non-conflicting) changes:"
    step_start "pull in changeset"
    {
    cd $COMMITTER_REPO
    git checkout master
    git pull github_master master
    git merge -m "commit to RoR own changes" work_branch
    } >>$DEBUG_OUT 2>&1
    step_end

    #   - convert to hg & push to RoR
    step_start "\"super push\" - convert to hg & push to RoR from dev pc"
    {
    super_push
    } >>$DEBUG_OUT 2>&1
    step_end
}

#   - make commit to RoR from contributor's repo
land_from_contributors_repo() {
    echo -e "\nLand some one else's (non-conflicting) changes:"
    step_start "pull in changeset"
    {
    cd $COMMITTER_REPO
    git checkout master
    git pull github_master master
    git pull $CONTRIBUTOR_FORK work_branch
    #git merge -m "commit to RoR contributor's changes" $CONTRIBUTOR_REPO:work_branch
    } >>$DEBUG_OUT 2>&1
    step_end

    #   - convert to hg & push to RoR
    step_start "\"super push\" - convert to hg & push to RoR from dev pc"
    {
    super_push
    } >>$DEBUG_OUT 2>&1
    step_end
}

main() {
    do_setup_if_needed
    make_contributor_commit
    make_committer_commit
    make_contributor_commit
    make_committer_commit
    make_contributor_commit
    make_committer_commit

    land_from_own_repo
    make_committer_commit
    land_from_contributors_repo
    land_from_own_repo

    echo "Scenario completed successfully."
    exit 0
}

if test $# -eq 0; then
    main
else
    do_setup_if_needed
    while test $# -gt 0; do
        case "$1" in
        dc|dev) make_contributor_commit ;;
        cc) make_committer_commit ;;
        land*own) land_from_own_repo ;;
        land*other) land_from_contributors_repo ;;
        -h | --help) usage ;;
        -*) usage "unknown option '$1'" ;;
        *) usage "unknown step '$1'" ;;
        esac
        shift
    done
fi

