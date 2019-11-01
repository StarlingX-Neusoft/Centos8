#!/bin/bash
# branch-repo.sh - Create new branches in a set of Git repositories
#
# branch-repo.sh [--dry-run|-n] [-b <branch>] [-t <tag>] [-s <source-branch>] [-i]
#
# --dry-run|-n      Do all work except pushing back to the remote repo.
#                   Useful to validate everything locally before pushing.
#
# -b <branch>       Name of the new branch
#
# -t <tag>          Apply a tag at the SHA passed in the input data, or HEAD
#                   of the new branch if no SHA is present
#
# -s <source-branch> The starting branch to use instead of the default 'master'.
#                    This is needed when the working branch is not named 'master'.
#                    Setting <source-branch> == <branch> makes this a tag-only
#                    operation (.gitreview updates are skipped).
#
# -i                Ignore path in input; use the last component of the repo
#                   name for the path similar to git clone's default.
#
# Read a list of repo tuples from stdin:
# <url> <local-path> <sha>
#
# For each repo:
# * create a new branch <branch> at <sha>, or at HEAD of SRC_BRANCH if no <sha>
# * tag the new branch with an initial release identifier if <tag> is set
# * update the .gitreview file to default to the new branch (Gerrit repos only)
#
# Some environment variables are available for modifying this script's behaviour
# NOTE: The command-line options override the environment variables when
# both are present.
#
# - BRANCH sets the new branch name <branch>
#
# - SRC_BRANCH sets the source branch name <source-branch>.
#
# - TAG sets the release tag <tag>.
#
# More Notes
# * The detection to use Gerrit or Github is determined by the presence of
#   'git.starlingx.io' or 'opendev.org' in the repo URL.  This may be
#   sub-optimal.  The only actual difference in execution is .gitreview
#   updates are only prepared for Gerrit repos.

set -e

# Defaults
BRANCH=${BRANCH:-""}
SRC_BRANCH=${SRC_BRANCH:-master}
TAG=${TAG:-""}

optspec="b:ins:t:-:"
while getopts "$optspec" o; do
    case "${o}" in
        # Hack in longopt support
        -)
            case "${OPTARG}" in
                dry-run)
                    DRY_RUN=1
                    ;;
                *)
                    if [[ "$OPTERR" = 1 ]] && [[ "${optspec:0:1}" != ":" ]]; then
                        echo "Unknown option --${OPTARG}" >&2
                    fi
                    ;;

            esac
            ;;
        b)
            BRANCH=${OPTARG}
            ;;
        i)
            SKIP_PATH=1
            ;;
        n)
            DRY_RUN=1
            ;;
        s)
            SRC_BRANCH=${OPTARG}
            ;;
        t)
            TAG=${OPTARG}
            ;;
    esac
done
shift $((OPTIND-1))

# See if we can build a repo list
if [[ -z $BRANCH ]]; then
    echo "ERROR: No repos to process"
    echo "Usage: $0 [--dry-run|-n] [-b <branch>] [-t <tag>] [-s <source-branch>] [-i]"
    exit 1
fi

# This is where other scripts live that we need
script_dir=$(realpath $(dirname $0))

# update_gitreview <branch>
# Based on update_gitreview() from https://github.com/openstack/releases/blob/a7db6cf156ba66d50e1955db2163506365182ee8/tools/functions#L67
function update_gitreview {
    typeset branch="$1"

    git checkout $branch
    # Remove a trailing newline, if present, to ensure consistent
    # formatting when we add the defaultbranch line next.
    typeset grcontents="$(echo -n "$(cat .gitreview | grep -v defaultbranch)")
defaultbranch=$branch"
    echo "$grcontents" > .gitreview
    git add .gitreview
    if git commit -s -m "Update .gitreview for $branch"; then
        if [[ -z $DRY_RUN ]]; then
            git review -t "create-${branch}"
        else
            echo "### skipping .gitreview submission to $branch"
        fi
    else
        echo "### no changes required for .gitreview"
    fi
}

# branch_repo <repo-uri> <path> <sha> <branch> [<tag>]
# <path> is optional but positional, pass "-" to default to the
# repo name as the path per git-clone's default
function branch_repo {
    local repo=$1
    local path=${2:-"-"}
    local sha=$3
    local branch=$4
    local tag=${5:-""}

    local repo_dir
    if [[ -n $SKIP_PATH || "$path" == "-" ]]; then
        repo_dir=${repo##*/}
    else
        repo_dir=$path
    fi

    if [[ ! -d $repo_dir ]]; then
        git clone $repo $repo_dir || true
    fi

    pushd $repo_dir >/dev/null
    git fetch origin

    if git branch -r | grep ^origin/${SRC_BRANCH}$; then
        # Get our local copy of the starting branch up-to-date with the origin
        git checkout -B $SRC_BRANCH origin/$SRC_BRANCH
    else
        # If the source branch is not in the origin just use what we have
        git checkout $SRC_BRANCH
    fi

    if ! git branch | grep ${branch}$; then
        # Create the new branch if it does not exist
        git branch $branch $sha
    fi

    if [[ -n $tag ]]; then
        # tag branch point at $sha
        git tag -s -m "Branch $branch" -f $tag $sha
    fi

    # Push the new goodness back up
    if [[ "$repo" =~ "git.starlingx.io" || "$repo" =~ "opendev.org" ]]; then
        # Do the Gerrit way

        # set up gerrit remote
        git review -s

        # push
        if [[ -z $DRY_RUN ]]; then
            git push --tags gerrit $branch
        else
            echo "### skipping push to $branch"
        fi

        if [[ "$SRC_BRANCH" != "$BRANCH" ]]; then
            # Skip .gitreview changes when only tagging
            update_gitreview $branch
        fi
    else
        # Do the Github way
        # push
        if [[ -z $DRY_RUN ]]; then
            git push --tags -u origin $branch
        else
            echo "### skipping push to $branch"
        fi
    fi

    popd >/dev/null
}


# Read the input
while read url path sha x; do
    # Default to repo name if no path supplied
    path=${path:-"-"}

    # Default to HEAD if no SHA supplied
    sha=${sha:-HEAD}

    branch_repo "$url" "$path" "$sha" "$BRANCH" "$TAG"
done
