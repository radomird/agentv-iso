# AgenTV's build step inside the live ISO. archiso runs this file in the live
# system's chroot once its packages are installed, and deletes it after.
#
# It has no shebang on purpose: omarchy-iso's build refuses an executable
# under /root that its profiledef.sh doesn't list, and that file is
# omarchy-iso's own, so AgenTV can't add a line to it. archiso marks this file
# executable and runs it anyway, and without a shebang it runs under /bin/sh,
# which is bash on Arch.

bash /usr/share/agentv-iso/customize.sh
rm -rf /usr/share/agentv-iso
