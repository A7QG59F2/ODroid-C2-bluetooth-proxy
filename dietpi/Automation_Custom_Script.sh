#!/bin/bash
# DietPi first-boot hook. DietPi runs this once, as root, after its own
# first-run setup has finished. Pulls this repo and runs install.sh.
#
# Use one of:
#   A) dietpi.txt:  AUTO_SETUP_CUSTOM_SCRIPT_EXEC=https://raw.githubusercontent.com/A7QG59F2/ODroid-C2-bluetooth-proxy/main/dietpi/Automation_Custom_Script.sh
#      (the GitHub repo must be public)
#   B) copy this file to the boot partition as  /boot/Automation_Custom_Script.sh
#      and leave AUTO_SETUP_CUSTOM_SCRIPT_EXEC=0
#
# Optional: put your edited config on the boot partition as /boot/odroid-ha.conf
# and install.sh will use it instead of the defaults.
set -e
REPO=https://github.com/A7QG59F2/ODroid-C2-bluetooth-proxy
command -v git >/dev/null || { apt-get update; apt-get install -y git; }
rm -rf /opt/odroid-ha/src
git clone --depth 1 "$REPO" /opt/odroid-ha/src
bash /opt/odroid-ha/src/install.sh
