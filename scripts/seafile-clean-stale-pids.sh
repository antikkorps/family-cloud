#!/bin/bash
# Remove PID files left behind by an unclean shutdown (power cut, host reboot).
#
# /opt/seafile/pids lives in the container layer, not the volume, so a stale
# seahub.pid survives restarts. On the next boot the recorded PID often gets
# reused by another process (seafevents in practice), gunicorn concludes seahub
# is already running and refuses to start -- the container then sits unhealthy
# with only "Error: Seahub failed to start" in the logs.
#
# my_init runs the scripts in /etc/my_init.d before enterpoint.sh, so this is
# guaranteed to happen while nothing is listening yet.

rm -f /opt/seafile/pids/*.pid
