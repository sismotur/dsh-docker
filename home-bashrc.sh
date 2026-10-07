# ~/.bashrc for the dsh container user (uid 1000 / node).
# dsh-shell starts: bash --rcfile /data/tmp/dsh-shell-*/bashrc -i
# and that generated file only does: source ~/.bashrc
# So profile.d is never loaded unless we pull it in here.
#
# Rootfs is read-only at runtime; run-dsh.sh bind-mounts this file over
# /home/node/.bashrc.

# If not running interactively, don't do anything
case $- in
  *i*) ;;
  *) return ;;
esac

# Debian interactive defaults (hist, color ls, etc.)
if [ -f /etc/bash.bashrc ]; then
  # shellcheck disable=SC1091
  . /etc/bash.bashrc
fi

# Project aliases + WORKSPACE_NAME prompt (inventrip_api, not "workspace")
if [ -f /etc/profile.d/dsh-aliases.sh ]; then
  # shellcheck disable=SC1091
  . /etc/profile.d/dsh-aliases.sh
fi
