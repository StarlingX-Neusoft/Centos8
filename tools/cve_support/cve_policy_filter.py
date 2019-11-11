#
# SPDX-License-Identifier: Apache-2.0
#
# Copyright (C) 2019 Intel Corporation
#

"""
Implement policy based on
https://wiki.openstack.org/wiki/StarlingX/Security/CVE_Support_Policy
Create documentation as pydoc -w cve_policy_filter
"""
import json
import sys
import os

def print_html_report(cves_report, title):
    """
    Print the html report
    """
    import jinja2

    template_loader = jinja2.FileSystemLoader(searchpath="./")
    template_env = jinja2.Environment(loader=template_loader)
    template_file = "template.txt"
    template = template_env.get_template(template_file)
    heads = ["cve_id", "status", "cvss2Score", "av", "ac", "au", "ai"]
    output_text = template.render(cves_to_fix=cves_report["cves_to_fix"],\
        cves_to_track=cves_report["cves_to_track"],\
        cves_w_errors=cves_report["cves_w_errors"],\
        cves_to_omit=cves_report["cves_to_omit"],\
        heads=heads,\
        title=title)
    report_title = 'report_%s.html' % (title)
    html_file = open(report_title, 'w')
    html_file.write(output_text)
    html_file.close()

def print_report(cves_report, title):
    """
    Print the txt STDOUT report
    """
    print("\n%s report:" % (title))
    print("\nValid CVEs to take action immediately: %d\n" \
        % (len(cves_report["cves_to_fix"])))
    for cve in cves_report["cves_to_fix"]:
        print("\n")
        print(cve["id"])
        print("status : " + cve["status"])
        print("cvss2Score : " + str(cve["cvss2Score"]))
        print("Attack Vector: " + cve["av"])
        print("Access Complexity : " + cve["ac"])
        print("Authentication: " + cve["au"])
        print("Availability Impact :" + cve["ai"])
        print("Affected packages:")
        print(cve["affectedpackages"])
        print(cve["summary"])
        if cve["sourcelink"]:
            print(cve["sourcelink"])

    print("\nCVEs to track for incoming fix: %d \n" \
        % (len(cves_report["cves_to_track"])))
    for cve in cves_report["cves_to_track"]:
        cve_line = []
        for key, value in cve.items():
            if key != "summary":
                cve_line.append(key + ":" + str(value))
        print(cve_line)

    print("\nERROR: CVEs that have no cvss2Score or cvss2Vector: %d \n" \
        % (len(cves_report["cves_w_errors"])))
    for cve in cves_report["cves_w_errors"]:
        print(cve)

def get_summary(data, cve_id):
    """
    return: nvd summary
    """
    try:
        summary = data["scannedCves"][cve_id]["cveContents"]["nvd"]["summary"]
    except KeyError:
        summary = None
    return summary

def get_source_link(data, cve_id):
    """
    return: web link to the nvd report
    """
    try:
        source_link = data["scannedCves"][cve_id]["cveContents"]["nvd"]["sourceLink"]
    except KeyError:
        source_link = None
    return source_link

def get_affectedpackages(data, cve_id):
    """
    return: affected packages by the CVE and fix/unfix status of each package
    """
    affectedpackages_list = []
    status_list = []
    try:
        affectedpackages = data["scannedCves"][cve_id]["affectedPackages"]
    except KeyError:
        affectedpackages = None
    else:
        for pkg in affectedpackages:
            affectedpackages_list.append(pkg["name"])
            status_list.append(pkg["notFixedYet"])
    return affectedpackages_list, status_list

def get_status(status_list):
    """
    return: status of CVE. If one of the pkgs is not fixed, CVE is not fixed
    """
    status = None
    if True in status_list:
        status = "unfixed"
    else:
        status = "fixed"
    return status

def main():
    """
    main function
    Rules to consider a CVE valid for STX from:
    https://wiki.openstack.org/wiki/StarlingX/Security/CVE_Support_Policy
    """
    data = {}
    cves = []
    cves_valid = []
    cves_to_fix = []
    cves_to_track = []
    cves_w_errors = []
    cves_to_omit = []
    cves_report = {}

    if len(sys.argv) < 3:
        print("\nERROR : Missing arguments, the expected arguments are:")
        print("\n   %s <result.json> <title>\n" % (sys.argv[0]))
        print("\n result.json = json file generated from: vuls report -format-json")
        print("\n")
        sys.exit(0)

    if os.path.isfile(sys.argv[1]):
        results_json = sys.argv[1]
    else:
        print("%s is not a file" % sys.argv[1])
        sys.exit(0)

    title = sys.argv[2]

    try:
        with open(results_json) as json_file:
            data = json.load(json_file)
    except ValueError as error:
        print(error)

    for element in data["scannedCves"]:
        cve = {}
        cve["id"] = str(element.strip())
        cves.append(cve)

    for cve in cves:
        cve_id = cve["id"]
        affectedpackages_list = []
        status_list = []
        try:
            nvd2_score = data["scannedCves"][cve_id]["cveContents"]["nvd"]["cvss2Score"]
            cvss2vector = data["scannedCves"][cve_id]["cveContents"]["nvd"]["cvss2Vector"]
        except KeyError:
            cves_w_errors.append(cve)
        else:
            cve["cvss2Score"] = nvd2_score
            for element in cvss2vector.split("/"):
                if "AV:" in element:
                    _av = element.split(":")[1]
                if "AC:" in element:
                    _ac = element.split(":")[1]
                if "Au:" in element:
                    _au = element.split(":")[1]
                if "A:" in element:
                    _ai = element.split(":")[1]
            cve["av"] = str(_av)
            cve["ac"] = str(_ac)
            cve["au"] = str(_au)
            cve["ai"] = str(_ai)
            cve["summary"] = get_summary(data, cve_id)
            cve["sourcelink"] = get_source_link(data, cve_id)
            affectedpackages_list, status_list = get_affectedpackages(data, cve_id)
            cve["affectedpackages"] = affectedpackages_list
            cve["status"] = get_status(status_list)
            cves_valid.append(cve)

    for cve in cves_valid:
        if (cve["cvss2Score"] >= 7.0
                and cve["av"] == "N"
                and cve["ac"] == "L"
                and ("N" in cve["au"] or "S" in cve["au"])
                and ("P" in cve["ai"] or "C" in cve["ai"])):
            if cve["status"] == "fixed":
                cves_to_fix.append(cve)
            else:
                cves_to_track.append(cve)
        else:
            cves_to_omit.append(cve)

    cves_report["cves_to_fix"] = cves_to_fix
    cves_report["cves_to_track"] = cves_to_track
    cves_report["cves_w_errors"] = cves_w_errors
    cves_report["cves_to_omit"] = cves_to_omit

    print_report(cves_report, title)
    print_html_report(cves_report, title)

if __name__ == "__main__":
    main()
