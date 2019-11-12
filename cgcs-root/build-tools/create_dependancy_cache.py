#!/usr/bin/python2

#
# Copyright (c) 2018 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#

#
# Create a RPM dependency cache frpm the RPMS found in
# 1) $MY_REPO/cgcs-centos-repo
# 2) $MY_WORKSPACE/$BUILD_TYPE/rpmbuild/
#
# Cache files are written to $MY_REPO/cgcs-tis-repo/dependancy-cache
# unless an alternate path is supplied.
#
# The cache is a set of files that are easily digested by 
# common shell script tools.  Each file has format
#   <rpm-name>;<comma-seperated-list-of-rpm-names>
#
# The files created are:
#   RPM-direct-descendants       RPMS that have a direct Requires on X
#   RPM-transitive-descendants   RPMS that have a possibly indirect need for X
#
#   RPM-direct-requires          RPMS directly Required by X
#   RPM-transitive-requires      RPMS possibly indirectly Required by X
#
#   SRPM-direct-descendants      SRPMS whos RPMS have a direct Requires on RPMS built by X
#   SRPM-transitive-descendants  SRPMS whos RPMS have a possibly indirect need for RPMS built by X
#
#   SRPM-direct-requires         SRPMS whos RPMS satisfy a direct BuildRequires of X
#   SRPM-transitive-requires     SRPMS whos RPMS satisfy an indirect BuildRequires of X
#
#   SRPM-direct-requires-rpm      RPMS that satisfy a direct BuildRequires of X
#   SRPM-transitive-requires-rpm  RPMS that satisfy an indirect BuildRequires of X
#
#   rpm-to-srpm                   Map RPM back to the SRPM that created it
#   srpm-to-rpm                   Map a SRPM to the set of RPMS it builds
#

import xml.etree.ElementTree as ET
import fnmatch
import os
import gzip
import sys
import string
from optparse import OptionParser

ns = { 'root': 'http://linux.duke.edu/metadata/common',
       'filelists': 'http://linux.duke.edu/metadata/filelists',
       'rpm': 'http://linux.duke.edu/metadata/rpm' }

build_types=['std', 'rt']
rpm_types=['RPM', 'SRPM']
default_arch = 'x86_64'
default_arch_list = [ 'x86_64', 'noarch' ]
default_arch_by_type = {'RPM': [ 'x86_64', 'noarch' ],
                        'SRPM': [ 'src' ]
                       }

repodata_dir="/export/jenkins/mirrors"
if not os.path.isdir(repodata_dir):
    repodata_dir="/import/mirrors"
    if not os.path.isdir(repodata_dir):
        print("ERROR: directory not found %s" % repodata_dir)
        sys.exit(1)

publish_cache_dir="%s/cgcs-tis-repo/dependancy-cache" % os.environ['MY_REPO']
centos_repo_dir="%s/cgcs-centos-repo" % os.environ['MY_REPO']

workspace_repo_dirs={}
for rt in rpm_types:
    workspace_repo_dirs[rt]={}
    for bt in build_types:
        workspace_repo_dirs[rt][bt]="%s/%s/rpmbuild/%sS" % (os.environ['MY_WORKSPACE'], bt, rt)

if not os.path.isdir(os.environ['MY_REPO']):
    print("ERROR: directory not found MY_REPO=%s" % os.environ['MY_REPO'])
    sys.exit(1)

if not os.path.isdir(centos_repo_dir):
    print("ERROR: directory not found %s" % centos_repo_dir)
    sys.exit(1)

bin_rpm_mirror_roots = ["%s/Binary" % centos_repo_dir]
src_rpm_mirror_roots = ["%s/Source" % centos_repo_dir]

for bt in build_types:
    bin_rpm_mirror_roots.append(workspace_repo_dirs['RPM'][bt])
    src_rpm_mirror_roots.append(workspace_repo_dirs['SRPM'][bt])

parser = OptionParser('create_dependancy_cache')
parser.add_option('-c', '--cache_dir', action='store', type='string',
    dest='cache_dir', help='set cache directory')
parser.add_option('-t', '--third_party_repo_dir', action='store',
    type='string', dest='third_party_repo_dir',
    help='set third party directory')
(options, args) = parser.parse_args()

if options.cache_dir:
    publish_cache_dir = options.cache_dir

if options.third_party_repo_dir:
    third_party_repo_dir = options.third_party_repo_dir
    bin_rpm_mirror_roots.append(third_party_repo_dir)
    src_rpm_mirror_roots.append(third_party_repo_dir)
    if not os.path.isdir(third_party_repo_dir):
        print("ERROR: directory not found %s" % third_party_repo_dir)
        sys.exit(1)

# Create directory if required
if not os.path.isdir(publish_cache_dir):
    print("Creating directory: %s" % publish_cache_dir)
    os.makedirs(publish_cache_dir, 0o755)

# The Main data structure
pkg_data={}

for rpm_type in rpm_types:
    pkg_data[rpm_type]={}

    # map provided_name -> pkg_name
    pkg_data[rpm_type]['providers']={}

    # map pkg_name -> required_names ... could be a pkg, capability or file
    pkg_data[rpm_type]['requires']={}

    # map file_name -> pkg_name
    pkg_data[rpm_type]['file_owners']={}

    # map pkg_name -> file_name
    pkg_data[rpm_type]['files']={}

    # map pkg_name -> required_pkg_names ... only pkg names, and only direct requirement
    pkg_data[rpm_type]['pkg_direct_requires']={}

    # map pkg_name -> required_pkg_names ... only pkg names, but this is the transitive list of all requirements
    pkg_data[rpm_type]['pkg_transitive_requires']={}

    # map pkg_name -> descendant_pkgs ... only packages the directly require this package
    pkg_data[rpm_type]['pkg_direct_descendants']={}

    # map pkg_name -> descendant_pkgs ... packages that have a transitive requiremant on this package
    pkg_data[rpm_type]['pkg_transitive_descendants']={}

    # Map package name to a source rpm file name
    pkg_data[rpm_type]['sourcerpm']={}
    pkg_data[rpm_type]['binrpm']={}

    # Map file name to package name
    pkg_data[rpm_type]['fn_to_name']={}

pkg_data['SRPM']['pkg_direct_requires_rpm']={}
pkg_data['SRPM']['pkg_transitive_requires_rpm']={}


# Return a list of file paths, starting in 'dir', matching 'pattern'
#    dir= directory to search under
#    pattern= search for file or directory matching pattern, wildcards allowed
#    recursive_depth= how many levels of directory before giving up
def file_search(dir, pattern, recursive_depth=0):
    match_list = []
    new_depth = recursive_depth - 1
    # print "file_search(%s,%s,%s)" % (dir, pattern, recursive_depth)
    for file in os.listdir(dir):
        path = "%s/%s" % (dir, file)
        if fnmatch.fnmatch(file, pattern):
            print(path)
            match_list.append(path)
        elif (recursive_depth > 0) and os.path.isdir(path):
            sub_list = []
            sub_list = file_search(path, pattern, recursive_depth=new_depth)
            match_list.extend(sub_list)
    return match_list

# Return the list of .../repodate/*primary.xml.gz files
#    rpm_type= 'RPM' or 'SRPM'
#    arch= e.g. x86_64, only relevant of rpm_type=='RPM'
def get_repo_primary_data_list(rpm_type='RPM', arch_list=default_arch_list):
    rpm_repodata_roots = []
    repodata_list = []

    if rpm_type == 'RPM':
        for d in bin_rpm_mirror_roots:
            if os.path.isdir(d):
                sub_list = file_search(d, 'repodata', 25)
                rpm_repodata_roots.extend(sub_list)
    elif rpm_type == 'SRPM':
        for d in src_rpm_mirror_roots:
            if os.path.isdir(d):
                sub_list = file_search(d, 'repodata', 5)
                rpm_repodata_roots.extend(sub_list)
    else:
        print("invalid rpm_type '%s', valid types are %s" % (rpm_type, str(rpm_types)))
        return repodata_list

    for d in rpm_repodata_roots:
        sub_list = file_search(d, '*primary.xml.gz', 2)
        repodata_list.extend(sub_list)
   
    return repodata_list


# Return the list of .../repodate/*filelists.xml.gz files
#    rpm_type= 'RPM' or 'SRPM'
#    arch= e.g. x86_64, only relevant of rpm_type=='RPM'
def get_repo_filelists_data_list(rpm_type='RPM', arch_list=default_arch_list):
    rpm_repodata_roots = []
    repodata_list = []

    if rpm_type == 'RPM':
        for d in bin_rpm_mirror_roots:
            if os.path.isdir(d):
                sub_list = file_search(d, 'repodata', 25)
                rpm_repodata_roots.extend(sub_list)
    elif rpm_type == 'SRPM':
        for d in src_rpm_mirror_roots:
            if os.path.isdir(d):
                sub_list = file_search(d, 'repodata', 5)
                rpm_repodata_roots.extend(sub_list)
    else:
        print "invalid rpm_type '%s', valid types are %s" % (rpm_type, str(rpm_types))
        return repodata_list

    for d in rpm_repodata_roots:
       sub_list = file_search(d, '*filelists.xml.gz', 2)
       repodata_list.extend(sub_list)

    return repodata_list



# Process a list of repodata files (*filelists.xml.gz) and extract package data.
# Data is saved to the global 'pkg_data'.
def read_data_from_repodata_filelists_list(repodata_list, rpm_type='RPM', arch=default_arch):
    for repodata_path in repodata_list:
        read_data_from_filelists_xml_gz(repodata_path, rpm_type=rpm_type, arch=arch)

# Process a single repodata file (*filelists.xml.gz) and extract package data.
# Data is saved to the global 'pkg_data'.
def read_data_from_filelists_xml_gz(repodata_path, rpm_type='RPM', arch=default_arch):
    # print "repodata_path=%s" % repodata_path
    infile = gzip.open(repodata_path)
    root = ET.parse(infile).getroot()
    for pkg in root.findall('filelists:package', ns):
        name=pkg.get('name')
        pkg_arch=pkg.get('arch')

        version=""
        release=""

        if arch is not None:
            if pkg_arch is None:
                continue
            if pkg_arch != arch:
                continue

        v=pkg.find('filelists:version', ns)
        if v is not None:
            version=v.get('ver')
            release=v.get('rel')
        else:
            print("%s: %s.%s has no 'filelists:version'" % (repodata_path, name, pkg_arch))

        # print "%s  %s  %s  %s  " % (name, pkg_arch, version,  release)

        for f in pkg.findall('filelists:file', ns):
            fn=f.text
            # print "   fn=%s -> plg=%s" % (fn, name)
            if not name in pkg_data[rpm_type]['files']:
                pkg_data[rpm_type]['files'][name]=[]
            pkg_data[rpm_type]['files'][name].append(fn)
            if not fn in pkg_data[rpm_type]['file_owners']:
                pkg_data[rpm_type]['file_owners'][fn]=[]
            pkg_data[rpm_type]['file_owners'][fn]=name





# Process a list of repodata files (*primary.xml.gz) and extract package data.
# Data is saved to the global 'pkg_data'.
def read_data_from_repodata_primary_list(repodata_list, rpm_type='RPM', arch=default_arch):
    for repodata_path in repodata_list:
        read_data_from_primary_xml_gz(repodata_path, rpm_type=rpm_type, arch=arch)

# Process a single repodata file (*primary.xml.gz) and extract package data.
# Data is saved to the global 'pkg_data'.
def read_data_from_primary_xml_gz(repodata_path, rpm_type='RPM', arch=default_arch):
    # print "repodata_path=%s" % repodata_path
    infile = gzip.open(repodata_path)
    root = ET.parse(infile).getroot()
    for pkg in root.findall('root:package', ns):
        name=pkg.find('root:name', ns).text
        pkg_arch=pkg.find('root:arch', ns).text
        version=""
        release=""
        license=""
        sourcerpm=""

        if arch is not None:
            if pkg_arch is None:
                continue
            if pkg_arch != arch:
                continue

        pkg_data[rpm_type]['providers'][name]=name
        pkg_data[rpm_type]['files'][name]=[]
        pkg_data[rpm_type]['requires'][name] = []
        pkg_data[rpm_type]['requires'][name].append(name)

        url=pkg.find('root:url', ns).text
        v=pkg.find('root:version', ns)
        if v is not None:
            version=v.get('ver')
            release=v.get('rel')
        else:
            print("%s: %s.%s has no 'root:version'" % (repodata_path, name, pkg_arch))

        fn="%s-%s-%s.%s.rpm" % (name, version, release, arch)
        pkg_data[rpm_type]['fn_to_name'][fn]=name

        # SAL print "%s  %s  %s  %s  " % (name, pkg_arch, version,  release)
        print("%s  %s  %s  %s  " % (name, pkg_arch, version,  release))
        f=pkg.find('root:format', ns)
        if f is not None:
            license=f.find('rpm:license', ns).text
            sourcerpm=f.find('rpm:sourcerpm', ns).text
            if sourcerpm != "":
                pkg_data[rpm_type]['sourcerpm'][name] = sourcerpm
            # SAL print "--- requires ---"
            print("--- requires ---")
            r=f.find('rpm:requires', ns)
            if r is not None:
                for rr in r.findall('rpm:entry', ns):
                    required_name=rr.get('name')
                    # SAL print "    %s" % required_name
                    print "    %s" % required_name
                    pkg_data[rpm_type]['requires'][name].append(required_name)
            else:
                print("%s: %s.%s has no 'rpm:requires'" % (repodata_path, name, pkg_arch))
            # print "--- provides ---"
            p=f.find('rpm:provides', ns)
            if p is not None:
                for pp in p.findall('rpm:entry', ns):
                    provided_name=pp.get('name')
                    # print "    %s" % provided_name
                    if name == "kernel-rt" and provided_name in pkg_data[rpm_type]['providers'] and pkg_data[rpm_type]['providers'][provided_name] == "kernel":
                        continue
                    if name.startswith('kernel-rt'):
                        alt_name=string.replace(name, 'kernel-rt', 'kernel')
                        if provided_name in pkg_data[rpm_type]['providers'] and pkg_data[rpm_type]['providers'][provided_name] == alt_name:
                            continue
                    pkg_data[rpm_type]['providers'][provided_name]=name
            else:
                print("%s: %s.%s has no 'rpm:provides'" % (repodata_path, name, pkg_arch))
            # print "--- files ---"
            for fn in f.findall('root:file', ns):
               file_name=fn.text
               # print "    %s" % file_name
               pkg_data[rpm_type]['files'][name].append(file_name)
               if name == "kernel-rt" and file_name in pkg_data[rpm_type]['file_owners'] and pkg_data[rpm_type]['file_owners'][file_name] == "kernel":
                   continue
               if name.startswith('kernel-rt'):
                   alt_name=string.replace(name, 'kernel-rt', 'kernel')
                   if provided_name in pkg_data[rpm_type]['file_owners'] and pkg_data[rpm_type]['file_owners'][file_name] == alt_name:
                       continue
               pkg_data[rpm_type]['file_owners'][file_name]=name
        else:
            print("%s: %s.%s has no 'root:format'" % (repodata_path, name, pkg_arch))
        # print "%s  %s  %s  %s  %s" % (name, pkg_arch, version,  release, license)
    infile.close
    
def calulate_all_direct_requires_and_descendants(rpm_type='RPM'):
    # print "calulate_all_direct_requires_and_descendants rpm_type=%s" % rpm_type
    for name in pkg_data[rpm_type]['requires']:
        calulate_pkg_direct_requires_and_descendants(name, rpm_type=rpm_type)

def calulate_pkg_direct_requires_and_descendants(name, rpm_type='RPM'):
    print("%s needs:" % name)
    if not rpm_type in pkg_data:
        print("Error: unknown rpm_type '%s'" % rpm_type)
        return

    if not name in pkg_data[rpm_type]['requires']:
        print("Note: No requires data for '%s'" % name)
        return

    for req in pkg_data[rpm_type]['requires'][name]:
        pro = '???'
        if rpm_type == 'RPM':
            if req in pkg_data[rpm_type]['providers']:
                pro = pkg_data[rpm_type]['providers'][req]
            elif req in pkg_data[rpm_type]['file_owners']:
                pro = pkg_data[rpm_type]['file_owners'][req]
            else:
                pro = '???'
                print("package %s has unresolved requirement '%s'" % (name, req))
        else:
            #  i.e. rpm_type == 'SRPM'
            rpm_pro = '???'
            if req in pkg_data['RPM']['providers']:
                rpm_pro = pkg_data['RPM']['providers'][req]
            elif req in pkg_data['RPM']['file_owners']:
                rpm_pro = pkg_data['RPM']['file_owners'][req]
            else:
                rpm_pro = '???'
                print("package %s has unresolved requirement '%s'" % (name, req))

            if rpm_pro is not None and rpm_pro != '???':
                if not name in pkg_data[rpm_type]['pkg_direct_requires_rpm']:
                    pkg_data[rpm_type]['pkg_direct_requires_rpm'][name] = []
                if not rpm_pro in pkg_data[rpm_type]['pkg_direct_requires_rpm'][name]:
                    pkg_data[rpm_type]['pkg_direct_requires_rpm'][name].append(rpm_pro)

                if rpm_pro in pkg_data['RPM']['sourcerpm']:
                    fn = pkg_data['RPM']['sourcerpm'][rpm_pro]
                    if fn in pkg_data['SRPM']['fn_to_name']:
                        pro = pkg_data['SRPM']['fn_to_name'][fn]
                    else:
                        pro = '???'
                        print("package %s requires srpm file name %s" % (name,fn))
                else:
                    pro = '???'
                    print("package %s requires rpm %s, but that rpm has no known srpm" % (name,rpm_pro))

        if pro is not None and pro != '???':
            if not name in pkg_data[rpm_type]['pkg_direct_requires']:
                pkg_data[rpm_type]['pkg_direct_requires'][name] = []
            if not pro in pkg_data[rpm_type]['pkg_direct_requires'][name]:
                pkg_data[rpm_type]['pkg_direct_requires'][name].append(pro)
            if not pro in pkg_data[rpm_type]['pkg_direct_descendants']:
                pkg_data[rpm_type]['pkg_direct_descendants'][pro] = []
            if not name in pkg_data[rpm_type]['pkg_direct_descendants'][pro]:
                pkg_data[rpm_type]['pkg_direct_descendants'][pro].append(name)

        print("    %s -> %s" % (req, pro))



def calulate_all_transitive_requires(rpm_type='RPM'):
    for name in pkg_data[rpm_type]['pkg_direct_requires']:
        calulate_pkg_transitive_requires(name, rpm_type=rpm_type)

def calulate_pkg_transitive_requires(name, rpm_type='RPM'):
    if not rpm_type in pkg_data:
        print("Error: unknown rpm_type '%s'" % rpm_type)
        return

    if not name in pkg_data[rpm_type]['pkg_direct_requires']:
        print("Note: No direct_requires data for '%s'" % name)
        return

    pkg_data[rpm_type]['pkg_transitive_requires'][name]=[]
    if rpm_type != 'RPM':
        pkg_data[rpm_type]['pkg_transitive_requires_rpm'][name]=[]
    unresolved = []
    unresolved.append(name)

    while unresolved:
        n = unresolved.pop(0)
        # print "%s: remove %s" % (name, n)
        if rpm_type == 'RPM':
            direct_requires='pkg_direct_requires'
            transitive_requires='pkg_transitive_requires'
        else:
            direct_requires='pkg_direct_requires_rpm'
            transitive_requires='pkg_transitive_requires_rpm'
        if n in pkg_data[rpm_type][direct_requires]:
            for r in pkg_data[rpm_type][direct_requires][n]:
                if r != name:
                    if not r in pkg_data[rpm_type][transitive_requires][name]:
                        pkg_data[rpm_type][transitive_requires][name].append(r)
                        if r in pkg_data['RPM']['pkg_transitive_requires']:
                            for r2 in pkg_data['RPM']['pkg_transitive_requires'][r]:
                                if r2 != name:
                                    if not r2 in pkg_data[rpm_type][transitive_requires][name]:
                                        pkg_data[rpm_type][transitive_requires][name].append(r2)
                        else:
                            if rpm_type == 'RPM':
                                unresolved.append(r)
                            else:
                                print("WARNING: calulate_pkg_transitive_requires: can't append rpm to SRPM list, name=%s, r=%s" % (name, r))
                            # print "%s: add %s" % (name, r)
    if rpm_type != 'RPM':
        for r in pkg_data[rpm_type]['pkg_transitive_requires_rpm'][name]:
            if r in pkg_data['RPM']['sourcerpm']:
                fn = pkg_data['RPM']['sourcerpm'][r]
                if fn in pkg_data['SRPM']['fn_to_name']:
                    s = pkg_data['SRPM']['fn_to_name'][fn]
                    pkg_data[rpm_type]['pkg_transitive_requires'][name].append(s)
                else:
                    print("package %s requires srpm file name %s, but srpm name is not known" % (name, fn))
            else:
                print("package %s requires rpm %s, but that rpm has no known srpm" % (name, r))

def calulate_all_transitive_descendants(rpm_type='RPM'):
    for name in pkg_data[rpm_type]['pkg_direct_descendants']:
        calulate_pkg_transitive_descendants(name, rpm_type=rpm_type)

def calulate_pkg_transitive_descendants(name, rpm_type='RPM'):
    if not rpm_type in pkg_data:
        print("Error: unknown rpm_type '%s'" % rpm_type)
        return

    if not name in pkg_data[rpm_type]['pkg_direct_descendants']:
        print("Note: No direct_requires data for '%s'" % name)
        return

    pkg_data[rpm_type]['pkg_transitive_descendants'][name]=[]
    unresolved = []
    unresolved.append(name)

    while unresolved:
        n = unresolved.pop(0)
        # print "%s: remove %s" % (name, n)
        if n in pkg_data[rpm_type]['pkg_direct_descendants']:
            for r in pkg_data[rpm_type]['pkg_direct_descendants'][n]:
                if r != name:
                    if not r in pkg_data[rpm_type]['pkg_transitive_descendants'][name]:
                        pkg_data[rpm_type]['pkg_transitive_descendants'][name].append(r)
                        if r in pkg_data[rpm_type]['pkg_transitive_descendants']:
                            for n2 in pkg_data[rpm_type]['pkg_transitive_descendants'][r]:
                                if n2 != name:
                                    if not n2 in pkg_data[rpm_type]['pkg_transitive_descendants'][name]:
                                        pkg_data[rpm_type]['pkg_transitive_descendants'][name].append(n2)
                        else:
                            unresolved.append(r)
                            # print "%s: add %s" % (name, r)

def create_dest_rpm_data():
    for name in sorted(pkg_data['RPM']['sourcerpm']):
        fn=pkg_data['RPM']['sourcerpm'][name]
        if fn in pkg_data['SRPM']['fn_to_name']:
            sname = pkg_data['SRPM']['fn_to_name'][fn]
            if not sname in pkg_data['SRPM']['binrpm']:
                pkg_data['SRPM']['binrpm'][sname]=[]
            pkg_data['SRPM']['binrpm'][sname].append(name)

def create_cache(cache_dir):
    for rpm_type in rpm_types:
        print("")
        print("==== %s ====" % rpm_type)
        print("")
        rpm_repodata_primary_list = get_repo_primary_data_list(rpm_type=rpm_type, arch_list=default_arch_by_type[rpm_type])
        for arch in default_arch_by_type[rpm_type]:
            read_data_from_repodata_primary_list(rpm_repodata_primary_list, rpm_type=rpm_type, arch=arch)
        rpm_repodata_filelists_list = get_repo_filelists_data_list(rpm_type=rpm_type, arch_list=default_arch_by_type[rpm_type])
        for arch in default_arch_by_type[rpm_type]:
            read_data_from_repodata_filelists_list(rpm_repodata_filelists_list, rpm_type=rpm_type, arch=arch)
        calulate_all_direct_requires_and_descendants(rpm_type=rpm_type)
        calulate_all_transitive_requires(rpm_type=rpm_type)
        calulate_all_transitive_descendants(rpm_type=rpm_type)

        cache_name="%s/%s-direct-requires" % (cache_dir, rpm_type)
        f=open(cache_name, "w")
        for name in sorted(pkg_data[rpm_type]['pkg_direct_requires']):
            print("%s needs %s" % (name, pkg_data[rpm_type]['pkg_direct_requires'][name]))
            f.write("%s;" % name)
            first=True
            for req in sorted(pkg_data[rpm_type]['pkg_direct_requires'][name]):
                if first:
                    first=False
                    f.write("%s" % req)
                else:
                    f.write(",%s" % req)
            f.write("\n")
        f.close()

        cache_name="%s/%s-direct-descendants" % (cache_dir, rpm_type)
        f=open(cache_name, "w")
        for name in sorted(pkg_data[rpm_type]['pkg_direct_descendants']):
            print("%s informs %s" % (name, pkg_data[rpm_type]['pkg_direct_descendants'][name]))
            f.write("%s;" % name)
            first=True
            for req in sorted(pkg_data[rpm_type]['pkg_direct_descendants'][name]):
                if first:
                    first=False
                    f.write("%s" % req)
                else:
                    f.write(",%s" % req)
            f.write("\n")
        f.close()

        cache_name="%s/%s-transitive-requires" % (cache_dir, rpm_type)
        f=open(cache_name, "w")
        for name in sorted(pkg_data[rpm_type]['pkg_transitive_requires']):
            f.write("%s;" % name)
            first=True
            for req in sorted(pkg_data[rpm_type]['pkg_transitive_requires'][name]):
                if first:
                    first=False
                    f.write("%s" % req)
                else:
                    f.write(",%s" % req)
            f.write("\n")
        f.close()

        cache_name="%s/%s-transitive-descendants" % (cache_dir, rpm_type)
        f=open(cache_name, "w")
        for name in sorted(pkg_data[rpm_type]['pkg_transitive_descendants']):
            f.write("%s;" % name)
            first=True
            for req in sorted(pkg_data[rpm_type]['pkg_transitive_descendants'][name]):
                if first:
                    first=False
                    f.write("%s" % req)
                else:
                    f.write(",%s" % req)
            f.write("\n")
        f.close()

        if rpm_type != 'RPM':
            cache_name="%s/%s-direct-requires-rpm" % (cache_dir, rpm_type)
            f=open(cache_name, "w")
            for name in sorted(pkg_data[rpm_type]['pkg_direct_requires_rpm']):
                print("%s needs rpm %s" % (name, pkg_data[rpm_type]['pkg_direct_requires_rpm'][name]))
                f.write("%s;" % name)
                first=True
                for req in sorted(pkg_data[rpm_type]['pkg_direct_requires_rpm'][name]):
                    if first:
                        first=False
                        f.write("%s" % req)
                    else:
                        f.write(",%s" % req)
                f.write("\n")
            f.close()

            cache_name="%s/%s-transitive-requires-rpm" % (cache_dir, rpm_type)
            f=open(cache_name, "w")
            for name in sorted(pkg_data[rpm_type]['pkg_transitive_requires_rpm']):
                f.write("%s;" % name)
                first=True
                for req in sorted(pkg_data[rpm_type]['pkg_transitive_requires_rpm'][name]):
                    if first:
                        first=False
                        f.write("%s" % req)
                    else:
                        f.write(",%s" % req)
                f.write("\n")
            f.close()

    cache_name="%s/rpm-to-srpm" % cache_dir
    f=open(cache_name, "w")
    for name in sorted(pkg_data['RPM']['sourcerpm']):
        f.write("%s;" % name)
        fn=pkg_data['RPM']['sourcerpm'][name]
        if fn in pkg_data['SRPM']['fn_to_name']:
            sname = pkg_data['SRPM']['fn_to_name'][fn]
            f.write("%s" % sname)
        f.write("\n")
    f.close()

    create_dest_rpm_data()
    cache_name="%s/srpm-to-rpm" % cache_dir
    f=open(cache_name, "w")
    for name in sorted(pkg_data['SRPM']['binrpm']):
        f.write("%s;" % name)
        first=True
        for bname in sorted(pkg_data['SRPM']['binrpm'][name]):
            if first:
                first=False
                f.write("%s" % bname)
            else:
                f.write(",%s" % bname)
        f.write("\n")
    f.close()


    
def test():
    for rpm_type in rpm_types:
        print("")
        print("==== %s ====" % rpm_type)
        print("")
        rpm_repodata_primary_list = get_repo_primary_data_list(rpm_type=rpm_type, arch_list=default_arch_by_type[rpm_type])
        for arch in default_arch_by_type[rpm_type]:
            read_data_from_repodata_primary_list(rpm_repodata_primary_list, rpm_type=rpm_type, arch=arch)
        rpm_repodata_filelists_list = get_repo_filelists_data_list(rpm_type=rpm_type, arch_list=default_arch_by_type[rpm_type])
        for arch in default_arch_by_type[rpm_type]:
            read_data_from_repodata_filelists_list(rpm_repodata_filelists_list, rpm_type=rpm_type, arch=arch)
        calulate_all_direct_requires_and_descendants(rpm_type=rpm_type)
        calulate_all_transitive_requires(rpm_type=rpm_type)
        calulate_all_transitive_descendants(rpm_type=rpm_type)

        for name in pkg_data[rpm_type]['pkg_direct_requires']:
            print("%s needs %s" % (name, pkg_data[rpm_type]['pkg_direct_requires'][name]))

        for name in pkg_data[rpm_type]['pkg_direct_descendants']:
            print("%s informs %s" % (name, pkg_data[rpm_type]['pkg_direct_descendants'][name]))

        for name in pkg_data[rpm_type]['pkg_transitive_requires']:
            print("%s needs %s" % (name, pkg_data[rpm_type]['pkg_transitive_requires'][name]))
            print("")
     
        for name in pkg_data[rpm_type]['pkg_transitive_descendants']:
            print("%s informs %s" % (name, pkg_data[rpm_type]['pkg_transitive_descendants'][name]))
            print("")


if os.path.isdir(publish_cache_dir):
   create_cache(publish_cache_dir)
else:
   print("ERROR: Directory not found '%s" % publish_cache_dir)
