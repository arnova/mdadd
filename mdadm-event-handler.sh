#!/bin/sh

# MDADM Event Handler - Generate mails when MD events occur
# Drop a line like "PROGRAM /root/bin/sys/mdadm-event-handler.sh" in your mdadm.conf to use it
#
# Last update: Jul 4, 2017
# (C) Copyright 2006-2017 by Arno van Amersfoort
# Web                   : https://github.com/arnova/mdadd
# Email                 : a r n o DOT v a n DOT a m e r s f o o r t AT g m a i l DOT c o m
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
  echo "Event           : $1"
  if [ -n "$2" ]; then
    echo "MD Device       : $2"
  fi
  if [ -n "$3" ]; then
    echo "Device Component: $3"
  fi

  echo ""
  FAIL=0
  DEGRADED=0
  MISMATCH=0
  unset IFS
  while read LINE; do
    printf "%s" "$LINE"
    DEV=""
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

    if [ -n "$DEV" ]; then
      blkid -o full -s LABEL -s PTTYPE -s TYPE -s UUID "/dev/${DEV}" |cut -d' ' -f1 --complement
    fi
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

MD_EVENT="${1:-Test message}"
MD_DEVICE="$2"
MD_COMPONENT="$3"

# Get MAILADDR from mdadm.conf config file, if not set already
if [ -z "$MAILADDR" ] && [ -f "$CONFIG" ]; then
  MAILADDR="$(grep '^MAILADDR ' "$CONFIG" |cut -d' ' -f2)"
  if [ -z "$MAILADDR" ]; then
    MAILADDR="root"
  fi
fi

# Sleep 1 second just to make sure things are in a 'stable state'
sleep 1

if ! echo "$IGNORE_EVENTS" |grep -q -i -E "(^|,| )$1($|,| )"; then
  # Call the parser and send it to the configured address
  parse_event "$MD_EVENT" "$MD_DEVICE" "$MD_COMPONENT" |mail -s "$(hostname) $MD_DEVICE event: $MD_EVENT" "$MAILADDR"
fi

exit 0

