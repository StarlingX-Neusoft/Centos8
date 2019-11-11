#!/bin/bash
# getrepo - Get the list of starlingx and stx-staging repos
# getrepo.sh [ <manifest-file> [<remote-name>] ... ]

IN_FILE=${1:-default.xml}
[[ $# -gt 1 ]] && shift
REMOTES=$*

# Extract the list of repo names from a repo manifest for the given remote
# get_repo <manifest-file> <git-remote-name>
function get_repos {
    local manifest=$1
    local remote=$2
    for i in $(xmllint --xpath '//project[@remote="'$remote'"]/@name' $manifest); do
        echo $i
    done | sed -e 's/^name="//' -e 's/"$//'
}

for r in $REMOTES; do
    remote=$(xmllint --xpath 'string(manifest/remote[@name="'$r'"]/@fetch)' $IN_FILE)
    repos=$(
        for i in $(get_repos $IN_FILE $r); do
            echo $remote/$i
        done
    )
    echo $repos
done
