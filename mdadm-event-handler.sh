#!/bin/sh

# MDADM Event Handler - Generate mails when MD events occur
# Drop a line like "PROGRAM /root/bin/sys/mdadm-event-handler.sh" in your mdadm.conf to use it
#
# Last update: November 1, 2016
# (C) Copyright 2006-2016 by Arno van Amersfoort
# Homepage              : http://rocky.eld.leidenuniv.nl/
# Email                 : a r n o v a AT r o c k y DOT e l d DOT l e i d e n u n i v DOT n l
#                         (note: you must remove all spaces and substitute the @ and the . at the proper locations!)
# ----------------------------------------------------------------------------------------------------------------------
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# version 2 as published by the Free Software Foundation.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
# ----------------------------------------------------------------------------------------------------------------------

CONFIG="/etc/mdadm/mdadm.conf"
REPORT_MISMATCH=1
IGNORE_EVENTS="NewArray DeviceDisappeared"

# Overrule mailto address from the mdadm.conf file?:
#MAILADDR="root"

parse_event()
{
  echo "Host            : $(hostname)"
  if [ -z "$1" ]; then
    echo "Event           : Test message"
  else
    echo "MD Device       : $2"
    echo "Event           : $1"
    if [ -n "$3" ]; then
      echo "Device Component: $3"
    fi
  fi

  echo ""
  echo "/proc/mdstat dump:"
  FAIL=0
  DEGRADED=0
  MISMATCH=0
  unset IFS
  while read LINE; do
    printf "%s" "$LINE"
    if echo "$LINE" |grep -q ': active '; then
      DEV="$(echo "$LINE" |awk '{ print $1 }')"

      printf " (mismatch_cnt=%s)" "$(cat /sys/block/$DEV/md/mismatch_cnt)"
      if [ "$REPORT_MISMATCH" != "0" -a "$(cat /sys/block/$DEV/md/mismatch_cnt)" != "0" ]; then
        MISMATCH=$(($MISMATCH +1))
        printf " (WARNING: Unsynchronised (mismatch) blocks!)"
      fi

      if echo "$LINE" |grep -q '\(F\)'; then
        FAIL=$(($FAIL + 1))
        printf " (WARNING: FAILED DISK(S)!)"
      fi

      if echo "$LINE" |grep -q '\(S\)'; then
        printf " (Hotspare(s) available)"
      else
        printf " (NOTE: No hotspare?!)"
      fi
    fi

    if echo "$LINE" |grep -q 'blocks'; then
      if echo "$LINE" |grep -q '_'; then
        DEGRADED=$(($DEGRADED + 1))
        printf " (DEGRADED!!!)"
      fi
    fi

    echo ""
  done < /proc/mdstat

  if [ $FAIL -gt 0 ]; then
    echo ""
    echo "** WARNING: $FAIL MD(RAID) array(s) have FAILED disk(s)! **"
  fi

  if [ $DEGRADED -gt 0 ]; then
    echo ""
    echo "** WARNING: $DEGRADED MD(RAID) array(s) are running in degraded mode! **"
  fi

  if [ $MISMATCH -gt 0 ]; then
    echo ""
    echo "** WARNING: $MISMATCH MD(RAID) array(s) have unsynchronized (mismatch) blocks! **"
  fi
}


# main line:
############

# Get MAILADDR from mdadm.conf config file, if not set already
if [ -z "$MAILADDR" ] && [ -f "$CONFIG" ]; then
  MAILADDR=`grep '^MAILADDR ' "$CONFIG" |cut -d' ' -f2`
  if [ -z "$MAILADDR" ]; then
    MAILADDR="root"
  fi
fi

# Sleep 1 second just to make sure things are in a 'stable state'
sleep 1

if ! echo "$IGNORE_EVENTS" |grep -q -i -E "(^|,| )$1($|,| )"; then
  # Call the parser and send it to the configured address
  parse_event $* |mail -s "RAID(MD) event on $(hostname)" "$MAILADDR"
fi

exit 0

