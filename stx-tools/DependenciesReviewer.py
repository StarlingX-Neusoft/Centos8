#
# SPDX-License-Identifier: Apache-2.0
#
# Copyright (C) 2019 Intel Corporation
#

import os
import subprocess
import getpass
import sys

# Error codes
SUCCESS = 0
RPMMISMATCH = 1
FILENOTFOUND = 2
ERRORCODE = SUCCESS

# Log file
results = open("dependenciesreviewer.log", "a")

# Parametrized variables
SELECT = {"centos" : {"name":"centos",
                      "dependencies":"srpm_path",
                      "prefix": "rpms_"
                     },
         }
DISTRO = SELECT["centos"]

# Global variables
USER = getpass.getuser()
WORK = os.path.abspath("..")
REPOS = os.path.join(WORK, "cgcs-root/stx/")
MTOOLS = os.path.join(WORK, "stx-tools/centos-mirror-tools")

class PkgInfo:
    """
    PkgInfo has a name, mirror location and full path
    """
    def __init__(self, name, location="NotFound", fullpath=""):
        """
        Initialize PkgInfo object
        """
        self.name = name
        self.location = location
        self.fullpath = fullpath

    def __str__(self):
        """
        Return information about PkgInfo object
        """
        return "Name: {}\nLocation: {}\nFull Path: {}\n".format(self.name,
                                                                self.location,
                                                                self.fullpath)
    def print_with_comment_if_not_found(self, comment=""):
        """
        Prints the full path of an PkgInfo object if it doesn't have
        location, followed by a comment provided by the user.
        """
        if self.location == "NotFound":
            print(">>> {} {}".format(self.fullpath, comment), file=results)


class MirrorInfo:
    """
    MirrorInfo has a path and a list of source packages
    """
    def __init__(self, path, src_pkgs=None):
        """
        Initialize MirrorInfo object
        """
        self.path = path
        self.src_pkgs = src_pkgs

    def __str__(self):
        """
        Return information about MirrorInfo object
        """
        return "MirrorInfo: {} {}".format(self.path, self.src_pkgs)

class DependenciesReviewer:
    """
    DependenciesReviewer class reviews the content in stx-'s
    */centos/srpm_path matches with the information in the mirror's lists.
    If there are modules that does not match, the DependenciesReviewer can
    display the information.
    """
    def __init__(self, modulepath=os.path.abspath(".."),
                 mirrorpath=os.path.abspath(".")):
        self.modulepath = modulepath
        self.mirrorpath = mirrorpath
        self._src_pkgs_dict = {}
        self._src_pkgs_list = []

    def __str__(self):
        return "DependenciesReviewer: {} {} {}".format(self.modulepath,
                                                       self.mirrorpath)

    def _find_elements(self, spkgsdict, mirror_list, mirror_path):
        """
        Fill the dictionary with the location in the mirror's list
        """
        for key, value in spkgsdict.items():
            for i in range(0, len(value)):
                if value[i].name in mirror_list:
                    spkgsdict[key][i].location = mirror_path
        return spkgsdict

    def _get_content(self, path):
        """ Get path's content as a list """
        try:
            text = open(path).read()
            text_list = text.split("\n")
            text_list = list(filter(None, text_list))
            return text_list
        except FileNotFoundError:
            print("Mirror lst file not found {}".format(path.split("/")[-1]),
                  file=results)
            ERRORCODE = FILENOTFOUND
            return []

    def check_missing(self):
        """
        Solve the dependencies
        """
        # SOURCE PACKAGES
        # Get the paths for all source packages information files in the repo
        vardir = os.path.join("*", DISTRO["name"], DISTRO["dependencies"])
        packages_paths = subprocess.check_output(['find',
                                         self.modulepath,
                                         '-wholename',
                                         vardir])
        packages_paths = packages_paths.decode('utf-8')
        packages_paths = packages_paths.split("\n")
        packages_paths = list(filter(None, packages_paths))

        # Fill dictionary and list with the content from those files
        for path in packages_paths:
            pkgs_list = open(path).read()
            pkgs_list = pkgs_list.split("\n")
            pkgs_list = list(filter(None, pkgs_list))

            if not pkgs_list:
                print("No content in: "+path, file=results)
            else:
                temp = []
                for pkg in pkgs_list:
                    if "mirror:" in pkg:
                        pkgname = pkg.split("/")[-1]
                        temp.append(PkgInfo(pkgname, location="NotFound",
                                            fullpath=pkg))
                        self._src_pkgs_list.append(pkgname)
            self._src_pkgs_dict[path] = temp

        # MIRROR LISTS
        # Generate list of MirrorInfo objects, which is needed for the review
        all_files = os.listdir(self.mirrorpath)
        mirror_files = [x for x in all_files if DISTRO["prefix"] in x]
        _spkg_mirror = []
        for elem in mirror_files:
            # Get package's content
            _tmp_path = os.path.join(self.mirrorpath, elem)
            _tmp_pkgs = self._get_content(_tmp_path)
            # Do particular clean up for 3rd party packages' names
            if elem == DISTRO["prefix"]+"from_3rd_parties.lst":
                _tmp_pkgs = [x.split("#")[0] for x in _tmp_pkgs]
            # Create a list with the Mirror Info
            _spkg_mirror.append(MirrorInfo(path=_tmp_path, src_pkgs=_tmp_pkgs))

        # MATCHING
        # Finding Packages in the mirror
        for mirr in _spkg_mirror:
            # Fill the dictinoary with the location
            self._src_pkgs_dict = self._find_elements(self._src_pkgs_dict,
                                                   mirr.src_pkgs,
                                                   mirr.path)
            # Leave on the list only the missing Source Packages
            self._src_pkgs_list = [element for element in self._src_pkgs_list
                                if element not in mirr.src_pkgs]

    def how_many_missing(self):
        """
        Return the number of missing RPMs
        """
        return len(self._src_pkgs_list)

    def show_missing(self):
        """
        Show the DependenciesReviewer results based on how it was initialized
        """
        for key, value in self._src_pkgs_dict.items():
            for val in value:
                val.print_with_comment_if_not_found(key)

if __name__ == "__main__":
    try:
        directories = os.listdir(REPOS)
    except FileNotFoundError:
        print("Directory not found {}".format(REPOS), file=results)
        ERRORCODE = FILENOTFOUND

    if ERRORCODE == SUCCESS:
        stx_directories = []
        for directory in directories:
            if "stx-" in directory:
                A = DependenciesReviewer(modulepath=os.path.join(REPOS, directory),
                                         mirrorpath=MTOOLS)
                A.check_missing()
                if A.how_many_missing() > 0:
                    print("Missing Src Packages in module: "+directory,
			  file=results)
                    A.show_missing()
                    if ERRORCODE != FILENOTFOUND:
                        ERRORCODE = RPMMISMATCH
                else:
                    continue
    if ERRORCODE == SUCCESS:
        print("All Src Packages in stx-* repos were found in Mirror's lists.",
              file=results)
    results.close()
    sys.exit(ERRORCODE)
