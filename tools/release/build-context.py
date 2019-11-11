#!/usr/bin/env python
# build-context.py
#
# Builds a summary of git repos and SHAs for a particular build based on
# manifest/default.xml and the build output script CONTEXT.sh
#
# Loads the CONTEXT.sh script from a StarlingX CenGN build and merge it with
# a default.xml manifest to build a YAML file that describes a set of
# git repositories and their specific configuration for a build.
#
# 1. Parse default.xml
#    - build an object containing the remote+repo with attributes: revision, path
# 2. Parse CONTEXT.sh
#    - Match up the path in the cd command with the path from the manifest, add
#      the SHA as an attribute
# 3. Write output:
#    <repo-url> <path-from-manifest> <SHA-from-context>

import argparse
import sys
import urllib

import xmltodict

def build_parser():
    parser = argparse.ArgumentParser(description='build-manifest')
    parser.add_argument(
        "manifest",
        metavar="<name-or-url>",
        help="Manifest file name or direct URL",
    )
    parser.add_argument(
        "--context",
        metavar="<name-or-url>",
        help="Context file name or direct URL",
    )
    parser.add_argument(
        '--remote',
        metavar="<remote-name>",
        action='append',
        dest='remotes',
        default=[],
        help='Remote to include (repeat to select multiple remotes)',
    )
    return parser

def load_manifest(name):
    # Load the manifest XML
    if "://" in name:
        # Open a URL
        fd = urllib.urlopen(name)
    else:
        # Open a file
        fd = open(name)
    doc = xmltodict.parse(fd.read())
    fd.close()
    return doc

def load_context(name):
    # Extract the workspace path and git SHA for each repo
    # (cd ./cgcs-root/stx/stx-config && git checkout -f 22a60625f169202a68b524ac0126afb1d10921cd)\n
    ctx = {}
    if "://" in name:
        # Open a URL
        fd = urllib.urlopen(name)
    else:
        # Open a file
        fd = open(name)
    line = fd.readline()
    while line:
        s = line.split(' ')
        # Strip './' from the beginning of the path if it exists
        path = s[1][2:] if s[1].startswith('./') else s[1]
        # Strip ')\n' from the end of the SHA if it exists
        # Don't forget that readline() always ends the line with \n
        commit = s[6][:-2] if s[6].endswith(')\n') else s[6][:-1]
        ctx[path] = commit
        line = fd.readline()
    fd.close()
    return ctx

if __name__ == "__main__":
    opts = build_parser().parse_args()

    manifest = load_manifest(opts.manifest)

    context = {}
    if opts.context:
        context = load_context(opts.context)

    # Map the remotes into a dict
    remotes = {}
    for r in manifest['manifest']['remote']:
        if opts.remotes == [] or r['@name'] in opts.remotes:
            remotes[r['@name']] = r['@fetch']

    # Get the repos
    for r in manifest['manifest']['project']:
        if opts.remotes == [] or r['@remote'] in opts.remotes:
            commit = ""
            if r['@path'] in context.keys():
                # If we have no context this always fails
                commit = context[r['@path']]
            print("%s/%s %s %s" % (
                remotes[r['@remote']],
                r['@name'],
                r['@path'],
                commit,
            ))
