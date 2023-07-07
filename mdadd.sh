#!/bin/sh

MY_VERSION="2.04e"
# ----------------------------------------------------------------------------------------------------------------------
# Linux MD (Soft)RAID Add Script - Add a (new) harddisk to another multi MD-array harddisk
# Last update: July 7, 2023
# (C) Copyright 2005-2023 by Arno van Amersfoort
# Homepage              : https://rocky.eld.leidenuniv.nl/
# Email                 : a r n o v a AT r o c k y DOT e l d DOT l e i d e n u n i v DOT n l
#                         (note: you must remove all spaces and substitute the @ and the . at the proper locations!)
# ----------------------------------------------------------------------------------------------------------------------
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# version 2 as published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
# ----------------------------------------------------------------------------------------------------------------------

EOL='
'

##################
# Define globals #
##################
GPT_ENABLE=0

show_help()
{
  echo "Usage: $(basename $0) [ options ] [ source_disk ] [ target_disk ]" >&2
  echo "" >&2
  echo "Options:" >&2
  echo "--help|-h      - Print this help" >&2
  echo "--force        - Even proceed if target device does not appear empty" >&2
  echo "--noptupdate   - Do NOT update the partition table on the target device (EXPERT!)" >&2
  echo "--nobootupdate - Do NOT update the boot-loader (track0) on the target device (EXPERT!)" >&2
  echo "--nomdadd      - Do NOT add any devices to the existing MDs, only update partition-table/bootloader (EXPERT!)" >&2
  echo "" >&2
}


human_size()
{
  echo "$1" |awk '{
    SIZE=$1
    TB_SIZE=(SIZE / 1024 / 1024 / 1024 / 1024)
    if (TB_SIZE > 1.0)
    {
      printf("%.2f TiB\n", TB_SIZE)
    }
    else
    {
      GB_SIZE=(SIZE / 1024 / 1024 / 1024)
      if (GB_SIZE > 1.0)
      {
        printf("%.2f GiB\n", GB_SIZE)
      }
      else
      {
        MB_SIZE=(SIZE / 1024 / 1024)
        if (MB_SIZE > 1.0)
        {
          printf("%.2f MiB\n", MB_SIZE)
        }
        else
        {
          KB_SIZE=(SIZE / 1024)
          if (KB_SIZE > 1.0)
          {
            printf("%.2f KiB\n", KB_SIZE)
          }
          else
          {
            printf("%u B\n", SIZE)
          }
        }
      }
    }
  }'
}


# Safe (fixed) version of sgdisk since it doesn't always return non-zero when an error occurs
sgdisk_safe()
{
  local IFS=' '

  local result="$(sgdisk $@ 2>&1)"
  local retval=$?

  if [ $retval -ne 0 ]; then
    printf '%s\n' "$result" >&2
    return $retval
  fi

  if ! printf '%s\n' "$result" |grep -i -q "operation has completed successfully"; then
    printf '%s\n' "$result" >&2
    return 8 # Seems to be the most appropriate return code for this
  fi

  printf '%s\n' "$result"
  return 0
}


# Safe (fixed) version of sfdisk since it doesn't always return non-zero when an error occurs
sfdisk_safe()
{
  local IFS=' '

  local result="$(sfdisk $@ 2>&1)"
  local retval=$?

  # Can't just check sfdisk's return code as it is not reliable
  local parse_false="$(printf '%s\n' "$result" |grep -i -e "^Warning.*extends past end of disk" -e "^Warning.*exceeds max")"
  local parse_true="$(printf '%s\n' "$result" |grep -i -e "^New situation:")"
  if [ -n "$parse_false" -o -z "$parse_true" ]; then
    printf '%s\n' "$result" >&2

    if [ $retval -eq 0 ]; then
      retval=8 # Don't show 0, which may confuse user. 8 seems to be the most appropriate return code for this
    fi

    return $retval
  fi

  printf '%s\n' "$result"
  return 0
}


# Get partition prefix(es) for provided device
# $1 = Device
get_partition_prefix()
{
  if echo "$1" |grep -q '[0-9]$'; then
    echo "${1}p"
  else
    echo "${1}"
  fi
}


# Get partition number from argument and return to stdout
# This needs to handle the following formats properly: /dev/sda12, /dev/sda12p3, /dev/nvm0n1p12
get_partition_number()
{
  # Obtain the last number from the string and consider that the partition number
  echo "$1" |sed -r s,'.*[a-z]+([0-9]+)$','\1',
}


# $1 = disk device to get partitions from, if not specified all available partitions are listed
get_partitions_with_size()
{
  local DISK_NODEV="${1#/dev/}"

  local FIND_PARTS="$(cat /proc/partitions |sed -r -e '1,2d' -e s,'[[blank:]]+/dev/, ,' |awk '{ print $4" "$3 }')"

  if [ -n "$DISK_NODEV" ]; then
    echo "$FIND_PARTS" |grep -E "^$(get_partition_prefix $DISK_NODEV)[0-9]+[[:blank:]]"
  else
    echo "$FIND_PARTS" # Show all
  fi
}


# $1 = disk device to get partitions from, if not specified all available partitions are listed
get_partitions()
{
  get_partitions_with_size "$1" |awk '{ print $1 }'
}


# $1 = disk device to get partitions from, if not specified all available partitions are listed
get_partitions_with_size_type()
{
  local DISK_NODEV="${1#/dev/}"
  local PART_NODEV SIZE SIZE_HUMAN BLKID_INFO

  IFS=$EOL
  get_partitions "$DISK_NODEV" |while read LINE; do
    PART_NODEV="$(echo "$LINE" |awk '{ print $1 }')"

    SIZE="$(blockdev --getsize64 "/dev/$PART_NODEV" 2>/dev/null)"
    if [ -z "$SIZE" ]; then
      SIZE=0
    fi
    SIZE_HUMAN="$(human_size $SIZE |tr ' ' '_')"

    BLKID_INFO="$(blkid -o full -s LABEL -s TYPE -s UUID -s PARTUUID "/dev/$PART_NODEV" 2>/dev/null |sed s,'^/dev/.*: ',,)"
    if [ -z "$BLKID_INFO" ]; then
      BLKID_INFO="TYPE=\"unknown\""
    fi
    echo "$PART_NODEV: $BLKID_INFO SIZE=$SIZE SIZEH=$SIZE_HUMAN"
  done
}


# Get partitions directly from disk using sgdisk
get_disk_partitions()
{
  local DISK_NODEV="${1#/dev/}"

  local DEV_PREFIX="/dev/$DISK_NODEV"
  # FIXME: Not sure if this is correct:
  if echo "$DEV_PREFIX" |grep -q '[0-9]$'; then
    DEV_PREFIX="${DEV_PREFIX}p"
  fi

  sgdisk -p "/dev/$DISK_NODEV" 2>/dev/null |grep -E "^[[:blank:]]+[0-9]+" |awk '{ print DISK$1 }' DISK=$DEV_PREFIX
}


show_block_device_info()
{
  local DEVICE_NODEV="$(echo "$1" |sed -e s,'^/dev/',, -e s,'^/sys/class/block/',,)"

  local LSBLK="$(lsblk -P --nodeps -n -b -o vendor,model,rev,serial "/dev/$DEVICE_NODEV" |sed -r -e s,' +',' ',g -e s,'SERIAL=','S/N=',)"
  printf "%s" "$LSBLK"

  local SIZE="$(blockdev --getsize64 "/dev/$DEVICE_NODEV" 2>/dev/null)"
  if [ -n "$SIZE" ]; then
    printf -- " - %s bytes (%s)" "$SIZE" "$(human_size $SIZE)"
  fi

  echo ""
}


# Add partition number to device and return to stdout
# $1 = device
# $2 = number
add_partition_number()
{
  if [ -b "${1}${2}" ]; then
    echo "${1}${2}"
  elif [ -b "${1}p${2}" ]; then
    echo "${1}p${2}"
  else
    # Fallback logic:
    # FIXME: Not sure if this is correct:
    if echo "$1" |grep -q '[0-9]$'; then
      echo "${1}p${2}"
    else
      echo "${1}${2}"
    fi
  fi
}


# Function checks (and waits) till the kernel ACTUALLY re-read the partition table
part_check()
{
  local DEVICE="$1"

  printf "Waiting for up to date partition table from kernel for %s..." "$DEVICE"

  # Retry several times since some daemons can block the re-reread for a while (like dm/lvm)
  IFS=' '
  local TRY=10
  while [ $TRY -gt 0 ]; do
    TRY=$((TRY - 1))

    # First make sure all partitions reported by the disk exist according to the kernel in /dev/
    DISK_PARTITIONS="$(get_disk_partitions "$DEVICE" |sed -r -e s,'^[/a-z]*',, -e s,'^[0-9]+p',, |sort -n)"

    # Second make sure all partitions reported by the kernel in /dev/ exist according to the disk
    KERNEL_PARTITIONS="$(get_partitions "$DEVICE" |sed -r -e s,'^[/a-z]*',, -e s,'^[0-9]+p',, |sort -n)"

    # Compare the partition numbers
    if [ "$DISK_PARTITIONS" = "$KERNEL_PARTITIONS" ]; then
      echo ""
      return 0
    fi

    printf "."

    # Sleep 1 second:
    sleep 1
  done

  printf "\033[40m\033[1;31mFAILED!\n\033[0m" >&2
  return 1
}


# Wrapper for partprobe (call after performing a partition table update)
# $1 = Device to re-read
partprobe()
{
  local DEVICE="$1"
  local result=""

  echo "(Re)reading partition-table on $DEVICE..."

  # Retry several times since some daemons can block the re-reread for a while (like dm/lvm)
  local TRY=10
  while [ $TRY -gt 0 ]; do
    TRY=$((TRY - 1))

    # Somehow using the partprobe binary itself doesn't always work properly, so use blockdev instead
    result="$(blockdev --rereadpt "$DEVICE" 2>&1)"
    retval=$?

    # Wait a sec for things to settle
    sleep 1

    # If blockdev returned success, we're done
    if [ $retval -eq 0 -a -z "$result" ]; then
      break
    fi
  done

  if [ -n "$result" ]; then
    printf "\033[40m\033[1;31m%s\n\033[0m" "$result" >&2
    return 1
  fi

  return 0
}


# Function to detect whether a device has a GPT partition table
gpt_detect()
{
  if sfdisk -d "$1" 2>&1 |grep -q -E -i -e '^/dev/.*[[:blank:]]Id=ee' -e '^label: gpt'; then
    return 0 # GPT found
  else
    return 1 # GPT not found
  fi
}


# Check whether a certain command is available
check_command()
{
  local path IFS

  IFS=' '
  for cmd in $*; do
    if [ -n "$(which "$cmd" 2>/dev/null)" ]; then
      return 0
    fi
  done

  return 1
}


# Check whether a binary is available and if not, generate an error and stop program execution
check_command_error()
{
  local IFS=' '

  if ! check_command "$@"; then
    printf "\033[40m\033[1;31mERROR  : Command(s) \"%s\" is/are not available!\033[0m\n" "$(echo "$@" |tr ' ' '|')" >&2
    printf "\033[40m\033[1;31m         Please investigate. Quitting...\033[0m\n" >&2
    echo "" >&2
    exit 2
  fi
}


# Check whether a binary is available and if not, generate a warning but continue program execution
check_command_warning()
{
  local retval IFS=' '

  check_command "$@"
  retval=$?

  if [ $retval -ne 0 ]; then
    printf "\033[40m\033[1;31mWARNING: Command(s) \"%s\" is/are not available!\033[0m\n" "$(echo "$@" |tr ' ' '|')" >&2
    printf "\033[40m\033[1;31m         Please investigate. This *may* be a problem!\033[0m\n" >&2
    echo "" >&2
  fi

  return $retval
}


sanity_check()
{
  local REPORT_FORCE=0

  if [ "$(id -u)" != "0" ]; then 
    printf "\033[40m\033[1;31mERROR: Root check FAILED (you MUST be root to use this script)! Quitting...\n\033[0m" >&2
    echo "" >&2
    exit 1
  fi

  check_command_error mdadm
  check_command_error sfdisk
  check_command_error fdisk
  check_command_error sgdisk
  check_command_error dd
  check_command_error awk
  check_command_error grep
  check_command_error sed
  check_command_error cat
  check_command_error blkid
  check_command_error blockdev
  check_command_error lsblk

  if [ -z "$SOURCE" -o -z "$TARGET" ]; then
    echo "ERROR: Bad or missing argument(s)" >&2
    echo "" >&2
    show_help
    exit 4
  fi

  if ! echo "$SOURCE" |grep -q '^/dev/'; then
    printf "\033[40m\033[1;31mERROR: Source device %s does not start with /dev/! Quitting...\n\033[0m" "$SOURCE" >&2
    echo "" >&2
    exit 5
  fi

  if ! echo "$TARGET" |grep -q '^/dev/'; then
    printf "\033[40m\033[1;31mERROR: Target device %s does not start with /dev/! Quitting...\n033[0m" "$TARGET" >&2
    echo "" >&2
    exit 5
  fi

  if echo "$SOURCE" |grep -q 'md[0-9]'; then
    printf "\033[40m\033[1;31mERROR: The source device specified is an md-device! Quitting...\n\033[0m" >&2
    echo "A physical drive (part of the md-array(s)) is required as source device (eg. /dev/sda)!" >&2
    echo "" >&2
    exit 5
  fi

  echo "* Source device $SOURCE: $(show_block_device_info $SOURCE)"
  echo "* Target device $TARGET: $(show_block_device_info $TARGET)"
  echo ""

  if [ "$SOURCE" = "$TARGET" ]; then
    printf "\033[40m\033[1;31mERROR: Source and target device are the same (%s)! Quitting...\n033[0m" "$TARGET" >&2
    echo "" >&2
    exit 5
  fi

  # We also want variables without /dev/ :
  SOURCE_NODEV="${SOURCE#/dev/}"
  TARGET_NODEV="${TARGET#/dev/}"

  if [ -z "$(get_partitions "$SOURCE_NODEV")" ]; then
    printf "\033[40m\033[1;31mERROR: Source device %s does not contain any partitions!? Quitting...\n\033[0m" "$SOURCE" >&2
    echo "" >&2
    exit 7
  fi

  SOURCE_SIZE="$(blockdev --getsize64 "/dev/$SOURCE_NODEV" 2>/dev/null)"
  if [ -z "$SOURCE_SIZE" ]; then
    printf "\033[40m\033[1;31mERROR: Source device reports zero size! Quitting...\n\033[0m" >&2
    echo "" >&2
    exit 8
  fi

  TARGET_SIZE="$(blockdev --getsize64 "/dev/$TARGET_NODEV" 2>/dev/null)"
  if [ -z "$TARGET_SIZE" ]; then
    printf "\033[40m\033[1;31mERROR: Target device reports zero size! Quitting...\n\033[0m" >&2
    echo "" >&2
    exit 8
  fi

  if [ $SOURCE_SIZE -gt $TARGET_SIZE ]; then
    if [ $FORCE -ne 1 ]; then
      printf "\033[40m\033[1;31mERROR: Target device %s (%s blocks) is smaller than source device %s (%s blocks)! Quitting (Use --force to override)...\n\033[0m" "$TARGET" "$TARGET_SIZE" "$SOURCE" "$SOURCE_SIZE" >&2
      REPORT_FORCE=1
    else
      printf "\033[40m\033[1;31mWARNING: Target device %s (%s blocks) is smaller than source device %s (%s blocks)\nPress <enter> to continue or CTRL-C to abort...\n\033[0m" "$TARGET" "$TARGET_SIZE" "$SOURCE" "$SOURCE_SIZE" >&2
      read dummy
    fi
  fi

  if [ -n "$(get_partitions $TARGET_NODEV)" ] && [ $FORCE -ne 1 ]; then
    printf "\033[40m\033[1;31mERROR: Target device /dev/%s already contains partitions (Use --force to override)!\n\033[0m" "$TARGET_NODEV" >&2
    get_partitions_with_size_type /dev/$TARGET_NODEV >&2
    echo "" >&2
    REPORT_FORCE=1
  fi

  if grep -E -q "[[:blank:]]($TARGET_NODEV|$(get_partition_prefix $TARGET_NODEV)[0-9]+)\[" /proc/mdstat; then
    cat /proc/mdstat >&2
    echo "" >&2
    printf "\033[40m\033[1;31mERROR: Target device /dev/%s is already part of one or more md devices!\n\033[0m" "$TARGET_NODEV" >&2
    echo "" >&2
    exit 7
  fi

  if [ $REPORT_FORCE -eq 1 ]; then
    exit 8
  fi

  echo "* Perfoming mdadm detail scan..."
  mdadm --detail --scan --verbose >/dev/null
  retval=$?
  if [ $retval -ne 0 ]; then
    printf "\033[40m\033[1;31mERROR: mdadm returned an error(%i) while determining detail information!\n\033[0m" $retval >&2
    echo "" >&2
    exit 9
  fi

  echo "* Checking DOS partition table (if any) of source device $SOURCE..."
  if [ -e "/tmp/sfdisk.source" ]; then
    if ! mv "/tmp/sfdisk.source" "/tmp/sfdisk.source.bak"; then
      printf "\033[40m\033[1;31mERROR: Unable to rename previous /tmp/sfdisk.source! Quitting...\n\033[0m" >&2
      echo "" >&2
      exit 11
    fi
  fi
  sfdisk -d "$SOURCE" >"/tmp/sfdisk.source"
  retval=$?
  if [ $retval -ne 0 ]; then
    printf "\033[40m\033[1;31mERROR: sfdisk returned an error(%i) while dumping the partition table on %s!\n\033[0m" $retval "$SOURCE" >&2
    echo "" >&2
    exit 11
  fi

  echo "* Checking DOS partition table (if any) of target device $TARGET..."
  if [ -e "/tmp/sfdisk.target" ]; then
    rm -f "/tmp/sfdisk.target.bak" >/dev/null 2>&1
    if ! mv "/tmp/sfdisk.target" "/tmp/sfdisk.target.bak"; then
      printf "\033[40m\033[1;31mERROR: Unable to rename previous /tmp/sfdisk.target! Quitting...\n\033[0m" >&2
      echo "" >&2
      exit 11
    fi
  fi
  sfdisk -d "$TARGET" >"/tmp/sfdisk.target" 2>/dev/null

  # GPT found on source?:
  if gpt_detect "$SOURCE"; then
    # Flag GPT use for the rest of the program:
    GPT_ENABLE=1

    echo "* Checking GPT partition table of source device $SOURCE..."
    if [ -e "/tmp/sgdisk.source" ]; then
      if ! mv "/tmp/sgdisk.source" "/tmp/sgdisk.source.bak"; then
        printf "\033[40m\033[1;31mERROR: Unable to rename previous /tmp/sgdisk.source! Quitting...\n\033[0m" >&2
        echo "" >&2
        exit 11
      fi
    fi
    sgdisk_safe --backup="/tmp/sgdisk.source" "$SOURCE" >/dev/null
    retval=$?
    if [ $retval -ne 0 ]; then
      printf "\033[40m\033[1;31mERROR: sgdisk returned an error(%i) while dumping the partition table on %s!\n\033[0m" $retval "$SOURCE" >&2
      echo "" >&2
      exit 11
    fi
  fi

  if gpt_detect "$TARGET"; then
    echo "* Checking GPT partition table of target device $TARGET..."
    if [ -e "/tmp/sgdisk.target" ]; then
      rm -f "/tmp/sgdisk.target.bak" >/dev/null 2>&1
      if ! mv "/tmp/sgdisk.target" "/tmp/sgdisk.target.bak"; then
        printf "\033[40m\033[1;31mERROR: Unable to rename previous /tmp/sgdisk.target! Quitting...\n\033[0m" >&2
        echo "" >&2
        exit 11
      fi
    fi
    sgdisk_safe --backup="/tmp/sgdisk.target" "$TARGET" >/dev/null 2>&1
    retval=$?
    if [ $retval -ne 0 ]; then
      printf "WARNING: sgdisk returned an error(%i) while dumping the partition table on %s!\n" $retval "$TARGET" >&2
    fi
  fi

  echo "* Checking status of running MDs..."
  MD_DEV=""
  IFS=$EOL
  while read MDSTAT_LINE; do
    if echo "$MDSTAT_LINE" |grep -q '^md'; then
      MD_DEV_LINE="$MDSTAT_LINE"
      MD_DEV="$(echo "$MDSTAT_LINE" |awk '{ print $1 }')"

      IFS=$EOL
      for PART_NODEV in $(get_partitions "$TARGET"); do
        if echo "$MD_DEV_LINE" |grep -E -q "[[:blank:]]$PART_NODEV\["; then
          printf "\033[40m\033[1;31mERROR: Partition /dev/%s on target device is already in use by array /dev/%s!\n\033[0m" "$PART_NODEV" "$MD_DEV" >&2
          echo "" >&2
          exit 12
        fi
      done
    fi

    if echo "$MDSTAT_LINE" |grep -E -q '[[:blank:]]blocks[[:blank:]]' && ! echo "$MDSTAT_LINE" |grep -q '_'; then
      # This array is NOT degraded so now check whether we want to add devices to it:

      IFS=$EOL
      for PART_NODEV in $(get_partitions "$SOURCE"); do
        if echo "$MD_DEV_LINE" |grep -E -q "[[:blank:]]$PART_NODEV\["; then
          printf "%s\n%s\n" "$MD_DEV_LINE" "$MDSTAT_LINE"
          printf "\033[40m\033[1;31mWARNING: Array % is NOT degraded, target device %s%s will become a hotspare!\nPress <enter> to continue or CTRL-C to abort...\n\033[0m" "$MD_DEV" "$TARGET" "${PART_NODEV#"$SOURCE_NODEV"}" >&2
          read dummy
        fi
      done
    fi
  done < /proc/mdstat
}


# Create swap partitions on specified (target) device
create_swaps()
{
  local DEVICE="$1"

  IFS=$EOL
  sgdisk -p "$DEVICE" 2>/dev/null |grep -E -i "[[:blank:]]8200[[:blank:]]+Linux swap" |while read LINE; do
    NUM="$(echo "$LINE" |awk '{ print $1 }')"
    PART="$(add_partition_number "$DEVICE" "$NUM")"
    echo "* Creating swap on $PART (don't forget to enable in /etc/fstab!)..."
    if ! mkswap "$PART"; then
      printf "\033[40m\033[1;31mWARNING: mkswap failed for %s\n\033[0m" "$PART" >&2
    fi
  done
}


disable_swaps()
{
  local TARGET="$1"

  # Disable all swaps on target disk
  IFS=$EOL
  for SWAP in $(grep -E "^$(get_partition_prefix $TARGET)[0-9]+[[:blank:]]" /proc/swaps |awk '{ print $1 }'); do
    echo "* Disabling swap partition $SWAP on target device $TARGET"
    swapoff $SWAP >/dev/null 2>&1
  done
}


zap_mbr_and_partition_table()
{
  local TARGET="$1"

  # Completely zap GPT, MBR and legacy partition data
  sgdisk --zap-all "$TARGET" >/dev/null 2>&1

  # Clear partition table
#  sgdisk --clear "$TARGET" >/dev/null 2>&1
}


copy_track0()
{
  local SOURCE="$1"
  local TARGET="$2"

  if [ $GPT_ENABLE -eq 0 ]; then
    echo "* Copying track0(containing MBR) from $SOURCE to $TARGET:"
    # Always try to use a full 1MiB of DD_SOURCE else GRUB2 with a (legacy) DOS partition doesn't work
    # NOTE: We don't overwrite the DOS partition table, in case the user specified --noptupdate
    dd if="$SOURCE" of="$TARGET" bs=446 count=1 && dd if="$SOURCE" of="$TARGET" bs=512 seek=1 skip=1 count=62
    retval=$?
  else
    echo "* Copying GPT protective MBR from $SOURCE to $TARGET:"
    # For GPT we don't overwrite the partition table, in case the user specified --noptupdate and to avoid
    # a (falsely) detected corrupt GPT header
    dd if="$SOURCE" of="$TARGET" bs=446 count=1
    retval=$?
  fi

  if [ $retval -ne 0 ]; then
    printf "\033[40m\033[1;31mERROR: Track0(MBR) update from %s to %s failed(%i). Quitting...\n\033[0m" "$SOURCE" "$TARGET" $retval >&2
    echo "" >&2
    exit 5
  fi 
}


copy_partition_table()
{
  local SOURCE="$1"
  local TARGET="$2"

  # Handle GPT partition table
  if [ $GPT_ENABLE -eq 1 ]; then
    echo "* Copying GPT partition table from source $SOURCE to target $TARGET..."
    result="$(sgdisk_safe --replicate="$TARGET" "$SOURCE" 2>&1)"
    retval=$?
    if [ $retval -ne 0 ]; then
      printf '%s\n' "$result" >&2
      printf "\033[40m\033[1;31mERROR: sgdisk returned an error(%i) while copying the GPT partition table!\n\033[0m" $retval >&2
      echo "" >&2s
      exit 9
    else
      printf '%s\n' "$result"
    fi

    # Randomize GUIDS, since we don't want both disks to use the same ones
    echo "* Randomizing all GUIDs on target $TARGET..."
    sgdisk_safe --randomize-guids "$TARGET" >/dev/null
  else
    echo "* Copying DOS partition table from source $SOURCE to target $TARGET..."
    result="$(sfdisk -d "$SOURCE" |sfdisk_safe --no-reread --force "$TARGET" 2>&1)"
    retval=$?

    if [ $retval -ne 0 ]; then
      printf '%s\n' "$result" >&2
      printf "\033[40m\033[1;31mERROR: sfdisk returned an error(%i) while writing the DOS partition table!\n\033[0m" "$retval" >&2
      echo "" >&2
      exit 9
    fi
  fi

  # Wait for kernel to reread partition table
  if partprobe "$TARGET" && part_check "$TARGET"; then
    return
  else
    printf "\033[40m\033[1;31mERROR: (Re)reading the partition table failed!\n\033[0m" >&2
    echo "" >&2
    exit 9
  fi
}


# Copy/build all md devices that exist on the source drive:
add_devices_to_mds()
{
  local SOURCE="$1"
  local TARGET="$2"

  echo "* Adding partition(s) to (active) md(s)"

  IFS=$EOL
  for LINE in $(grep -E '^md[0-9]+ : active ' /proc/mdstat |sort); do
    MD_DEV="/dev/$(echo "$LINE" |awk '{ print $1 }')"

    PARTITION_NR=""
    IFS=' '
    for ITEM in $LINE; do
      if echo "$ITEM" |grep -q -E '\[[0-9]+\]$'; then
        PART="$(echo "$ITEM" |sed -r 's,\[[0-9]+\]$,,')"
        if echo "/dev/$PART" |grep -E -q -x "$(get_partition_prefix $SOURCE)[0-9]+"; then
          PARTITION_NR="$(get_partition_number $PART)"
          break
        fi
      fi
    done

    if [ -z "$PARTITION_NR" ]; then
      continue # No match found, go to next md
    fi

    NO_ADD=0
    echo ""
    TARGET_PARTITION="$(get_partition_prefix $TARGET)$PARTITION_NR"
    echo "* Adding $TARGET_PARTITION to RAID array $MD_DEV:"
    printf "\033[40m\033[1;31m"
    mdadm --add "$MD_DEV" "$TARGET_PARTITION"
    retval=$?
    if [ $retval -ne 0 ]; then
      printf "\033[40m\033[1;31mERROR: mdadm returned an error(%i) while adding device!\n\033[0m" $retval >&2
      echo "" >&2
      exit 12
    fi
    printf "\033[0m"
  done

  echo ""
}


# Copy boot/EFI (eg. grub) partitions
copy_boot_partitions()
{
  local SOURCE="$1"
  local TARGET="$2"

  IFS=$EOL
  # Normally there will be one boot/EFI partition, but use a loop to allow this to be extended for other types
  sgdisk -p "$SOURCE" 2>/dev/null |grep -E -i "[[:blank:]](EF00|EF02)[[:blank:]]" |while read LINE; do
    NUM="$(echo "$LINE" |awk '{ print $1 }')"
    SOURCE_PART="$(add_partition_number "$SOURCE" "$NUM")"
    TARGET_PART="$(add_partition_number "$TARGET" "$NUM")"

    echo "* Copy boot partition $SOURCE_PART to $TARGET_PART..."
    dd if=$SOURCE_PART of=$TARGET_PART bs=1M
    retval=$?

    if [ $retval -ne 0 ]; then
      printf "\033[40m\033[1;31mERROR: Boot partition %s failed to copy to %s(%i)!\n\n\033[0m" "$SOURCE_PART" "$TARGET_PART" $retval >&2
    fi
  done
}


#######################
# Program entry point #
#######################
echo "mdadd v$MY_VERSION - (C) Copyright 2005-2023 by Arno van Amersfoort"
echo ""

# Set environment variables to default
FORCE=0
NO_PT_UPDATE=0
NO_BOOT_UPDATE=0
NO_MD_ADD=0
SOURCE=""
TARGET=""

# Check arguments
unset IFS
for ARG in $*; do
  ARGNAME="${ARG%%=*}"
  # Can't directly obtain value as = is optional!:
  ARGVAL="${ARG#$ARGNAME}"
  ARGVAL="${ARGVAL#=}"

  case "$ARGNAME" in
                                 --force|-force|-f) FORCE=1;;
                      --noptupdate|--nopt|--nopart) NO_PT_UPDATE=1;;
                           --nobootupdate|--noboot) NO_BOOT_UPDATE=1;;
                                         --nomdadd) NO_MD_ADD=1;;
                                         --help|-h) show_help
                                                    exit 0
                                                    ;;
                                                -*) echo "ERROR: Bad argument \"$ARG\"" >&2
                                                    echo "" >&2
                                                    show_help
                                                    exit 1
                                                    ;;
                                                 *) if [ -z "$SOURCE" ]; then
                                                      SOURCE="$ARG"
                                                    elif [ -z "$TARGET" ]; then
                                                      TARGET="$ARG"
                                                    else
                                                      echo "ERROR: Bad command syntax with argument \"$ARG\"" >&2
                                                      echo "" >&2
                                                      show_help
                                                      exit 1
                                                    fi
                                                    ;;
  esac
done

# Make sure everything is sane:
sanity_check

disable_swaps "$TARGET"

if [ $NO_PT_UPDATE -ne 1 -a $NO_BOOT_UPDATE -ne 1 ]; then
  # Zap MBR and partition table
  zap_mbr_and_partition_table "$TARGET"
fi

# Copy legacy MBR/track0 boot loader to target disk (if any)
if [ $NO_BOOT_UPDATE -ne 1 ]; then
  copy_track0 "$SOURCE" "$TARGET"
else
  echo "* NOTE: Not updating boot loader target $TARGET..."
fi

# Update (copy) partitions from source to target
if [ $NO_PT_UPDATE -ne 1 ]; then
  copy_partition_table "$SOURCE" "$TARGET"
else
  echo "* NOTE: Not updating partition table on target $TARGET..."
fi

# Copy (GRUB) boot/EFI partitions to target disk (if any)
if [ $NO_BOOT_UPDATE -ne 1 ]; then
  copy_boot_partitions "$SOURCE" "$TARGET"
fi

# Create actual md devices on target
if [ $NO_MD_ADD -ne 1 ]; then
  NO_ADD=1
  add_devices_to_mds "$SOURCE" "$TARGET"

  # Wait a bit for mdstat to settle
  sleep 3

  echo "* Showing current /proc/mdstat (you may need to update your mdadm.conf (manually)..."
  cat /proc/mdstat
  echo ""

  if [ $NO_ADD -eq 1 ]; then
    printf "\033[40m\033[1;31mWARNING: No mdadm --add actions were performed, please investigate!\n\033[0m" >&2
  fi
fi

# run mkswap on swap partitions
create_swaps "$TARGET"

echo "* All done"
echo ""
