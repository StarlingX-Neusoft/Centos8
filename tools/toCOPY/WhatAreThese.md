# This lists what we copy into the container and what they are

## To replace/update these, rebuild the container with new ones:
* .inputrc
  * Allows up arrows to work with history
* finishSetup.sh
  * a shell script run when doing a docker exec into the container. It relies on a number of things being set up so it is done at run, rather than build time.  It is run based on .bashrc, so make sure you use that shell!
* .gitconfig
  * NOT in the repo, this needs to be copied in from YOUR personal gitconfig
