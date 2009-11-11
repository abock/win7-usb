#!/usr/bin/env bash
#
# win7-iso-to-usb.sh
# Written by Aaron Bockover <aaron@abock.org>
# Copyright 2009 Aaron Bockover
# Licensed under the MIT/X11 license
#

function usage {
	echo "Written by Aaron Bockover <aaron@abock.org>."
	echo "Copyright 2009 Aaron Bockover"
	echo "Licensed under the MIT/X11 license"
	echo
	echo "Usage: $0 ISO [TARGET DEVICE]"
	echo
	echo "    ISO             Path to the Windows 7 ISO file"
	echo
	echo "    TARGET DEVICE   Target USB block device node. This argument"
	echo "                    is optional if devkit-disks is installed."
	echo
	echo "                    Omitting this argument will present a list"
	echo "                    of available target USB block devices."
	echo
}

function check-program {
	full_path="$(which "$1" 2>/dev/null)"
	if ! test -x "$full_path"; then
		usage
		echo "You must have $1 installed and in your PATH."
		exit 1
	fi
}

function dk-enum-device-files {
	devkit-disks --dump | grep device-file: | cut -f2 -d:
}

function dk-get-device-field {
	devkit-disks --show-info $1 | awk -F: '/'"$2"':[ ]*/{
		sub (/^[ ]*/, "", $2);
		sub (/[ ]*$/, "", $2);
		print $2
	}'
}

function dk-compare-device-field {
	test "$(dk-get-device-field $1 "$2")" $3 "$4"
}

function dk-id-for-device-file {
	devkit-disks --show-info $1 | head -n1 | awk -F' ' '{print $NF}'
}

function select-target-device {
	declare -a devices=()
	device_count=0

	echo Select a target USB device:
	echo

	for device in $(dk-enum-device-files); do
		if dk-compare-device-field $device removable -eq 1 && \
			dk-compare-device-field $device interface = usb; then

			devkit_id=$(dk-id-for-device-file $device)
			display_name=$(dk-get-device-field $device model)

			echo " 1) $display_name [$device]"

			devices[$device_count]="$device:"
			for child_device in $(dk-enum-device-files); do
				if dk-compare-device-field $child_device \
					"part of" = $devkit_id && \
					dk-compare-device-field $child_device "is mounted" -eq 1; then
					mount_path=$(dk-get-device-field $child_device "mount paths")
					devices[$device_count]="${devices[$device_count]}$child_device "
					echo "    $child_device mounted at $mount_path"
				fi
			done

			let device_count++
		fi
	done

	if test $device_count -eq 0; then
		echo "  No available devices"
		exit 0
	fi

	echo ; read -p "Device number (1): " device_index ; echo
	test -z $device_index && device_index=1
	let device_index--
	if test $device_index -lt 0 || test $device_index -ge $device_count; then
		echo Invalid device selection.
		exit 1
	fi

	device="${devices[$device_index]}"
	device_file="$(echo "$device" | cut -f1 -d:)"
	device_mounts="$(echo "$device" | cut -f2 -d:)"

	if ! test -z "$device_mounts"; then
		echo "Device $device_file has mounted partitions."
		read -p "Unmount all partitions on $device_file? [Y/N]: " unmount_device
		case "$unmount_device" in
			Y|y) ;;
			N|n) echo "Cannot continue with mounted partitions."; exit 1 ;;
			*) echo "Invalid choice."; exit 1 ;;
		esac
		for mount in $device_mounts; do
			echo "Unmounting $mount..."
			if ! umount $mount; then
				echo "Failed to unmount $mount"
				exit 1
			fi
		done
	fi
}

if test $# -le 0; then
	usage
	exit 1
fi

if test $UID -ne 0; then
	usage
	echo "You must be root to run this tool."
	exit 1
fi

check-program ntfs-3g
check-program sfdisk
check-program mount
check-program umount
check-program mkntfs

iso_path="$1"
if ! test -f "$iso_path"; then
	usage
	echo "You must specify a path to the Windows 7 ISO."
	exit 1
fi

if test -e "$2"; then
	device_file=$2
else
	if test -x $(which devkit-disks 2>/dev/null); then
		select-target-device
	else
		usage
		echo You do not have devkit-disks installed. Without this tool
		echo the target device must be specified as the second argument
		echo to this script.
		echo
		echo Ensure there are no mounted partitions on the device first.
		echo
		exit 1
	fi
fi

## Windows 7 Installation ##

read -p "WARNING: All data on $device_file will be DESTROYED. Continue? [Y/N]: " destroy_device
case "$destroy_device" in
	Y|y) ;;
	N|n) echo "Quitting. $device_file has not been touched."; exit 1 ;;
	*) echo "Invalid choice."; exit 1 ;;
esac
echo

# Create mount points for later use
win7_iso_mount=$(mktemp -d /tmp/win7-iso.XXXX)
win7_usb_mount=$(mktemp -d /tmp/win7-usb.XXXX)
if ! test -d "$win7_iso_mount" || ! test -d "$win7_usb_mount"; then
	echo "Could not create mount directories."
	exit 1
fi

# From here on we will just bail if something fails
set -e

# Zero out the MBR
echo "Zeroing out the MBR..."
dd if=/dev/zero of=$device_file bs=512 count=1 conv=notrunc &>/dev/null

# Partition the USB key with a bootable NTFS
# partition that consumes the entire disk
echo "Creating partitions on $device_file..."
sfdisk $device_file &>/dev/null <<EOF
,,7,*
;
EOF

device_ntfs_partition=$(sfdisk -l $device_file | grep '^'"$device_file" \
	| head -n1 | cut -f1 -d' ')

echo "  NTFS data partition = $device_ntfs_partition"

# Format the data partition with NTFS
echo "Formatting $device_ntfs_partition as NTFS..."
mkntfs --fast -L WIN7SETUP $device_ntfs_partition

# Mount the NTFS partition
echo "Mounting $device_ntfs_partition using ntfs-3g at $win7_usb_mount..."
mount -t ntfs-3g $device_ntfs_partition "$win7_usb_mount"

# Mount the UDF ISO
echo "Mounting $iso_path using udf at $win7_iso_mount..."
mount -t udf -o loop,ro "$iso_path" "$win7_iso_mount"

# Copy the ISO contents to the USB NTFS partition
echo "Copying $iso_path contents to the USB stick. This may take some time..."
cp -a "$win7_iso_mount"/* "$win7_usb_mount"

# Rename bootmgr to NTLDR since that's what the MBR loads
echo "Renaming bootmgr to NTLDR..."
mv "$win7_usb_mount/bootmgr" "$win7_usb_mount/NTLDR"

echo "Syncing filesystems and umounting..."
sync
umount "$win7_iso_mount"
rmdir "$win7_iso_mount"
umount "$win7_usb_mount"
rmdir "$win7_usb_mount"

# Install the Windows 7 MBR code
echo "Installing Windows 7 MBR to $device_file..."

WIN7_MBR_CODE="
33c0 8ed0 bc00 7c8e c08e d8be 007c bf00 06b9 0002 fcf3 a450 681c 06cb fbb9 0400
bdbe 0780 7e00 007c 0b0f 850e 0183 c510 e2f1 cd18 8856 0055 c646 1105 c646 1000
b441 bbaa 55cd 135d 720f 81fb 55aa 7509 f7c1 0100 7403 fe46 1066 6080 7e10 0074
2666 6800 0000 0066 ff76 0868 0000 6800 7c68 0100 6810 00b4 428a 5600 8bf4 cd13
9f83 c410 9eeb 14b8 0102 bb00 7c8a 5600 8a76 018a 4e02 8a6e 03cd 1366 6173 1cfe
4e11 750c 807e 0080 0f84 8a00 b280 eb84 5532 e48a 5600 cd13 5deb 9e81 3efe 7d55
aa75 6eff 7600 e88d 0075 17fa b0d1 e664 e883 00b0 dfe6 60e8 7c00 b0ff e664 e875
00fb b800 bbcd 1a66 23c0 753b 6681 fb54 4350 4175 3281 f902 0172 2c66 6807 bb00
0066 6800 0200 0066 6808 0000 0066 5366 5366 5566 6800 0000 0066 6800 7c00 0066
6168 0000 07cd 1a5a 32f6 ea00 7c00 00cd 18a0 b707 eb08 a0b6 07eb 03a0 b507 32e4
0500 078b f0ac 3c00 7409 bb07 00b4 0ecd 10eb f2f4 ebfd 2bc9 e464 eb00 2402 e0f8
2402 c349 6e76 616c 6964 2070 6172 7469 7469 6f6e 2074 6162 6c65 0045 7272 6f72
206c 6f61 6469 6e67 206f 7065 7261 7469 6e67 2073 7973 7465 6d00 4d69 7373 696e
6720 6f70 6572 6174 696e 6720 7379 7374 656d 0000 0063 7b9a"

echo -n -e $(echo "$WIN7_MBR_CODE" | tr -d '[:space:]' | sed 's/../\\x&/g') \
	| dd of=$device_file conv=notrunc &>/dev/null

sync

echo Done.

