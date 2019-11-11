echo "!! This script dumps all GPG keys added by \"rpm --import\"."
echo "!! it also lists out all keys' fingerprints, so that you can "
echo "!! cross-check with info at \"https://www.centos.org/keys/\""
echo ""

echo "-------------------- Start ----------------------------"

all_imported_keys="./all_imported_keys.txt"
echo "dump imported keys into $all_imported_keys"
# dump all RPM GPG keys we've already imported.
rpm -qi gpg-pubkey-\* > $all_imported_keys

# list fingerprint for each of keys we've imported
all_keys="`find /etc/pki/rpm-gpg -type f -name "RPM-GPG-KEY*"`"
for key in $all_keys;do
    gpg --quiet --with-fingerprint $key
done

echo "-------------------- Done ----------------------------"

