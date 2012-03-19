#!/bin/bash -e -u

# demonstrate how git handles simultaneous commits

# Roughly, we'll:
#   - create a git RoR (repository of record)
#   - add server side hooks to aid simultanaity
#   - clone twice
#
# To show modes, repeat changes for each of:
#   - compatible changes
#   - conflicting changes
# each change is:
#   - add changes to each repository
#   - push at same time
#   - pull back to each

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

log() {
    local time_stamp="$(date +%s)"
    for m ; do
        echo "$time_stamp:$$:$m"
    done
}


add_pre_receive_hook() {
    local git_dir="$1"
    local hook_file="${2:-pre-receive}"
    test -d $git_dir/hooks || die "not called with .git dir"
    pushd $git_dir/hooks &>/dev/null
    test -f $hook_file && warn "overwriting hook file: $hook_file"
    cat >$hook_file <<'EOF'
#!/bin/bash

# give a delay window to increase the odds of simultanaity

prog_dir=$(cd $(dirname "$0"); /bin/pwd)
SEMAPHORE_FILE=$prog_dir/semaphore

log() {
    local time_stamp="$(date +%s)"
    for m ; do
        echo "$time_stamp:$$:$m"
    done
}

if test -f $SEMAPHORE_FILE; then
    rm $SEMAPHORE_FILE
    WAIT_SECONDS=1
    log "second committer, waiting $WAIT_SECONDS"
else
    touch $SEMAPHORE_FILE
    WAIT_SECONDS=10
    log "first committer, waiting $WAIT_SECONDS"
fi

sleep $WAIT_SECONDS
exit 0
EOF
    # verify no variable expansion occurred
    grep -q '\$0' $hook_file || die "Expansion in $hook_file"
    chmod +x $hook_file
    popd &>/dev/null
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
    } >>$DEBUG_OUT 2>&1
    step_end
#   - add server side hooks to guarantee simultanaity
    step_start "Add server side hooks to aid simultanaity"
    {
        # deploy hook
        add_pre_receive_hook "$PWD/.git"
        # make git think this is bare, so it can receive pushes without
        # complaint. IRL, this would be bare, and intial push would come
        # from clone
        git config --bool core.bare true
    } >>$DEBUG_OUT 2>&1
    step_end
fi

#   - clone twice
GIT_CLONES=$DIR_TO_USE/02-git_clones
if ! test -d $GIT_CLONES; then
    step_start "Clone twice"
    {
    mkdir $GIT_CLONES
    cd $GIT_CLONES
    git clone git+ssh://localhost/$GIT_ROR clone_01
    git clone git+ssh://localhost/$GIT_ROR clone_02
    } >>$DEBUG_OUT 2>&1
    step_end
fi

make_and_push_changes () {
    # add changes to each repo, using the file name passed in for that
    # repo.
    # returns: globals push_error_count & pull_error_count
    local file_to_change
    local repo

    cd $GIT_CLONES
    
    step_start "Add changes to each repository"
    {
    for repo in clone_*; do
        cd $repo
        file_to_change="$1" ; shift
        log "Changing $file_to_change in $repo" >> $file_to_change
        git add $file_to_change
        git commit -m "Changing $file_to_change in $repo"
        cd -
    done
    } >>$DEBUG_OUT 2>&1
    step_end
    step_start "Push at same time"
    {
    local -a my_pids
    for repo in clone_*; do
        cd $repo
        git push >>$GIT_CLONES/log_for_$repo 2>&1 &
        my_pids[${#my_pids[*]}]=$!
        cd -
    done
    # wait for all pushes to complete - we don't care about order, just
    # exit status, so go one by one
    push_error_count=0
    for pid in ${my_pids[*]}; do
        local -i ec=0
        wait $pid || ec=$?
        if test $ec -ne 0; then
            warn "push failure: pid $pid exited with status $ec"
            : $((push_error_count++))
        fi
    done
    } >>$DEBUG_OUT 2>&1
    step_end
    step_start "Pull back to each"
    {
    pull_error_count=0
    for repo in clone_*; do
        cd $repo
        local -i ec=0
        git pull || ec=$?
        if test $ec -ne 0; then
            warn "pull failure: pid $pid exited with status $ec"
            : $((pull_error_count++))
        fi
        cd -
    done
    } >>$DEBUG_OUT 2>&1
    step_end
}

# Note: the remaining steps are not "one time" operations, and will be
#       re-executed every time the script is run
echo -e "\nThe following steps represent a commit cycle:"
step_start "Compatible changes"
{
# each repo changes a different file
make_and_push_changes file_1 file_2
} >>$DEBUG_OUT 2>&1
# we expect one push failure (locked repo), and zero pull errors
if test "$push_error_count" -ne 1 -o "$pull_error_count" -ne 0; then 
    die "FAIL: push errors $push_error_count (s/b 1)" \
        "      pull errors $pull_error_count (s/b 0)"
else
    echo -n "... detected expected error"
fi
step_end
# complete the missed push/pull
git --git-dir $GIT_CLONES/clone_01/.git push &>/dev/null
git --git-dir $GIT_CLONES/clone_01/.git pull &>/dev/null
step_start "Conflicting changes"
{
# each repo changes the same file
make_and_push_changes file_1 file_1
} >>$DEBUG_OUT 2>&1
# we expect one push failure (locked repo), and one pull failure (merge
# fail)
if test "$push_error_count" -ne 1 -o "$pull_error_count" -ne 1; then 
    die "FAIL: push errors $push_error_count (s/b 1)" \
        "      pull errors $pull_error_count (s/b 1)"
else
    echo -n "... detected expected errors"
fi
step_end
# clone_01 is broken at this point

echo "Scenario completed successfully."
exit 0
