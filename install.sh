#!/bin/bash
set -e

PROG=$0
PROGS="dd curl mkfs.ext4 mkfs.vfat fatlabel parted partprobe grub-install cryptsetup clevis"
DISTRO=/run/k3os/iso

if [ "$K3OS_DEBUG" = true ]; then
    set -x
fi

get_url()
{
    FROM=$1
    TO=$2
    case $FROM in
        ftp*|http*|tftp*)
            n=0
            attempts=5
            until [ "$n" -ge "$attempts" ]
            do
                curl -o $TO -fL ${FROM} && break
                n=$((n+1))
                echo "Failed to download, retry attempt ${n} out of ${attempts}"
                sleep 2
            done
            ;;
        *)
            cp -f $FROM $TO
            ;;
    esac
}

cleanup2()
{
    if [ -n "${TARGET}" ]; then
        umount ${TARGET}/boot/efi || true
        umount ${TARGET} || true
    fi

    losetup -d ${ISO_DEVICE} || losetup -d ${ISO_DEVICE%?} || true
    umount $DISTRO || true
}

cleanup()
{
    EXIT=$?
    cleanup2 2>/dev/null || true
    return $EXIT
}

usage()
{
    echo "Usage: $PROG [--force-efi] [--debug] [--tty TTY] [--poweroff] [--takeover] [--no-format] [--encrypt-fs] [--tang-server] [--luks-password] [--config https://.../config.yaml] DEVICE ISO_URL"
    echo ""
    echo "Example: $PROG /dev/vda https://github.com/rancher/k3os/releases/download/v0.8.0/k3os.iso"
    echo ""
    echo "DEVICE must be the disk that will be partitioned (/dev/vda). If you are using --no-format it should be the device of the K3OS_STATE partition (/dev/vda2)"
    echo ""
    echo "The parameters names refer to the same names used in the cmdline, refer to README.md for"
    echo "more info."
    echo ""
    exit 1
}

do_format()
{
    if [ "$K3OS_INSTALL_NO_FORMAT" = "true" ]; then
        STATE=$(blkid -L K3OS_STATE || true)
        if [ -z "$STATE" ] && [ -n "$DEVICE" ]; then
            tune2fs -L K3OS_STATE $DEVICE
            STATE=$(blkid -L K3OS_STATE)
        fi

        return 0
    fi

    dd if=/dev/zero of=${DEVICE} bs=1M count=1
    parted -s ${DEVICE} mklabel ${PARTTABLE}
    if [ "$PARTTABLE" = "gpt" ] && [ "$K3OS_ENCRYPT_FILESYSTEM" = "true" ]; then
        BOOT_NUM=1
        STATE_NUM=2
        parted -s ${DEVICE} mkpart primary fat32 0% 200MB
        parted -s ${DEVICE} mkpart primary ext4 200MB 100%
    elif [ "$PARTTABLE" = "gpt" ]; then
        BOOT_NUM=1
        STATE_NUM=2
        parted -s ${DEVICE} mkpart primary fat32 0% 50MB
        parted -s ${DEVICE} mkpart primary ext4 50MB 750MB
    else
        BOOT_NUM=
        STATE_NUM=1
        parted -s ${DEVICE} mkpart primary ext4 0% 700MB
    fi
    parted -s ${DEVICE} set 1 ${BOOTFLAG} on
    partprobe ${DEVICE} 2>/dev/null || true
    sleep 2

    PREFIX=${DEVICE}
    if [ ! -e ${PREFIX}${STATE_NUM} ]; then
        PREFIX=${DEVICE}p
    fi

    if [ ! -e ${PREFIX}${STATE_NUM} ]; then
        echo Failed to find ${PREFIX}${STATE_NUM} or ${DEVICE}${STATE_NUM} to format
        exit 1
    fi

    if [ -n "${BOOT_NUM}" ]; then
        BOOT=${PREFIX}${BOOT_NUM}
    fi
    STATE=${PREFIX}${STATE_NUM}

    mkfs.ext4 -F -L K3OS_STATE ${STATE}
    if [ -n "${BOOT}" ]; then
        mkfs.vfat -F 32 ${BOOT}
        fatlabel ${BOOT} K3OS_GRUB
    fi
}

# to coorectly mount use mapper: https://www.drupal8.ovh/en/tutoriels/382/mount-luks-encrypted-volumes-command-line
do_encrypt()
{   
    if [ -z $K3OS_ENCRYPT_FILESYSTEM ]; then
        return 0
    fi

    if [ "$PARTTABLE" != "gpt" ]; then
        echo "Can only encrypt filesystem if using gpt, not dos."
        return 0
    fi

    sleep 2
    KEYFILE=/etc/keyfile_luks.key
    if [ -z $K3OS_LUKS_PASSWORD ]; then
        openssl genrsa 2048 > $KEYFILE
    else
        echo $K3OS_LUKS_PASSWORD > $KEYFILE
    fi
    
    if [ "$K3OS_ENCRYPT_FILESYSTEM" = "true" ]; then
        echo "STATE is: $STATE"
        CRYPT_MAPPER_NAME="decrypted"
        password | cryptsetup -q luksFormat --type luks1 $STATE # --key-file $KEYFILE
        password | cryptsetup -q luksOpen $STATE $CRYPT_MAPPER_NAME # --key-file $KEYFILE
        pvcreate /dev/mapper/$CRYPT_MAPPER_NAME
        vgcreate vg0 /dev/mapper/$CRYPT_MAPPER_NAME
        lvcreate -L 2G vg0 -n swap
        lvcreate -L 2G vg0 -n boot
        lvcreate -l 100%FREE vg0 -n root

        mkfs.ext4 /dev/vg0/root        
        mkfs.ext4 /dev/vg0/boot     
        mffs.fat -F32  
        mkswap /dev/vg0/swap       
    fi

    # if [ ! -z "$K3OS_TANG_SERVER_URL" ]; then
    # clevis luks bind -y -d $STATE -k $KEYFILE tang '{"url": "http://tang.moti.us"}' # ${K3OS_TANG_SERVER_URL}
    # fi

    # if [ "$K3OS_ENCRYPT_FILESYSTEM" = "true" ]; then
    #     mkfs.ext4 -F -L K3OS_STATE /dev/mapper/$CRYPT_MAPPER_NAME
    # fi 
}

do_mount()
{
    TARGET=/run/k3os/target
    mkdir -p ${TARGET}
    
    # TODO: test this
    mkdir -p ${TARGET}/boot
    if [ "$K3OS_ENCRYPT_FILESYSTEM" = "true" ]; then
        mount -t ext4 /dev/vg0/root $TARGET
        mount -t ext4 /dev/vg0/boot $TARGET/boot
    else
        mount ${STATE} ${TARGET}
    fi

    if [ -n "${BOOT}" ]; then
        mkdir -p ${TARGET}/boot/efi
        mount ${BOOT} ${TARGET}/boot/efi
    fi

    if [ "$K3OS_ENCRYPT_FILESYSTEM" = "true" ]; then
        swapon /dev/vg0/swap
    fi

    mkdir -p ${DISTRO}
    mount -o ro ${ISO_DEVICE} ${DISTRO} || mount -o ro ${ISO_DEVICE%?} ${DISTRO}
}

do_copy()
{
    tar cf - -C ${DISTRO} k3os | tar xvf - -C ${TARGET}
    if [ -n "$STATE_NUM" ]; then
        echo $DEVICE $STATE_NUM > ${TARGET}/k3os/system/growpart # TODO: probably change
    fi

    if [ -n "$K3OS_INSTALL_CONFIG_URL" ]; then
        get_url "$K3OS_INSTALL_CONFIG_URL" ${TARGET}/k3os/system/config.yaml
        chmod 600 ${TARGET}/k3os/system/config.yaml
    fi

    if [ "$K3OS_INSTALL_TAKE_OVER" = "true" ]; then
        touch ${TARGET}/k3os/system/takeover

        if [ "$K3OS_INSTALL_POWER_OFF" = true ] || grep -q 'k3os.install.power_off=true' /proc/cmdline; then
            touch ${TARGET}/k3os/system/poweroff
        fi
    fi

    if [ "$K3OS_ENCRYPT_FILESYSTEM" = "true" ]; then
        dd bs=512 count=4 if=/dev/urandom of=${TARGET}/crypto_keyfile.bin
        cryptsetup luksAddKey /dev/sda2 ${TARGET}/crypto_keyfile.bin
    fi
}

install_grub()
{
    if [ "$K3OS_INSTALL_DEBUG" ]; then
        GRUB_DEBUG="k3os.debug"
    fi

    # mkdir -p ${TARGET}/boot/grub
    # cat > ${TARGET}/boot/grub/grub.cfg << EOF
|   # awk -F'"' '{print $2}'`
    if [ "$K3OS_ENCRYPT_FILESYSTEM" = "true" ]; then
        ROOT_PART_UUID = $(blkid -s UUID -o value /dev/sda2 | awk -F'"' '{print $2}')
        ROOT_PART_UUID_NO_DASHES = $(echo $ROOT_UUID | sed -e "s/-//" -e "s///")
        ROOT_VG_UUID = $(blkid -s UUID -o value /dev/mapper/vg0-root | awk -F'"' '{print $2}')
        BOOT_VG_UUID = $(blkid -s UUID -o value /dev/mapper/vg0-boot | awk -F'"' '{print $2}')

        VG_UUID = vgdisplay | grep "VG UUID" | aws {'print $NF'}
        LV_UUID_ROOT = lvdisplay -v /dev/vg0/root | grep "VG UUID" | aws {'print $NF'}
        LV_UUID_BOOT = lvdisplay -v /dev/vg0/boot | grep "VG UUID" | aws {'print $NF'}
    fi

    mkdir -p ${TARGET}/boot/grub
    cat > ${TARGET}/boot/grub/grub.cfg << EOF
#
# DO NOT EDIT THIS FILE
#
# It is automatically generated by grub-mkconfig using templates
# from /etc/grub.d and settings from /etc/default/grub
#

### BEGIN /etc/grub.d/00_header ###
insmod luks
insmod cryptodisk
insmod part_gpt
insmod lvm
if [ -s $prefix/grubenv ]; then
  load_env
fi
if [ "${next_entry}" ] ; then
   set default="${next_entry}"
   set next_entry=
   save_env next_entry
   set boot_once=true
else
   set default="0"
fi

if [ x"${feature_menuentry_id}" = xy ]; then
  menuentry_id_option="--id"
else
  menuentry_id_option=""
fi

export menuentry_id_option

if [ "${prev_saved_entry}" ]; then
  set saved_entry="${prev_saved_entry}"
  save_env saved_entry
  set prev_saved_entry=
  save_env prev_saved_entry
  set boot_once=true
fi

function savedefault {
  if [ -z "${boot_once}" ]; then
    saved_entry="${chosen}"
    save_env saved_entry
  fi
}

function load_video {
  if [ x$feature_all_video_module = xy ]; then
    insmod all_video
  else
    insmod efi_gop
    insmod efi_uga
    insmod ieee1275_fb
    insmod vbe
    insmod vga
    insmod video_bochs
    insmod video_cirrus
  fi
}

if [ x$feature_default_font_path = xy ] ; then
   font=unicode
else
insmod part_gpt
insmod cryptodisk
insmod luks
insmod gcry_rijndael
insmod gcry_rijndael
insmod gcry_sha256
insmod lvm
insmod ext2
cryptomount -u $ROOT_PART_UUID_NO_DASHES
set root='lvmid/${VG_UUID}/${LV_UUID_ROOT}'
if [ x$feature_platform_search_hint = xy ]; then
  search --no-floppy --fs-uuid --set=root --hint='lvmid/${VG_UUID}/${LV_UUID_ROOT}'  ${ROOT_VG_UUID}
else
  search --no-floppy --fs-uuid --set=root ${ROOT_VG_UUID}
fi
    font="/usr/share/grub/unicode.pf2"
fi

if loadfont $font ; then
  set gfxmode=auto
  load_video
  insmod gfxterm
fi
terminal_output gfxterm
if [ x$feature_timeout_style = xy ] ; then
  set timeout_style=menu
  set timeout=2
# Fallback normal timeout code in case the timeout_style feature is
# unavailable.
else
  set timeout=2
fi
### END /etc/grub.d/00_header ###

### BEGIN /etc/grub.d/10_linux ###
menuentry 'Alpine, with Linux lts' --class alpine --class gnu-linux --class gnu --class os $menuentry_id_option 'gnulinux-lts-advanced-${ROOT_VG_UUID}' {
	load_video
	set gfxpayload=keep
	insmod gzio
	insmod part_gpt
	insmod cryptodisk
	insmod luks
	insmod gcry_rijndael
	insmod gcry_rijndael
	insmod gcry_sha256
	insmod lvm
	insmod ext2
	cryptomount -u $ROOT_PART_UUID_NO_DASHES
	set root='lvmid/${VG_UUID}/${LV_UUID_BOOT}'
	if [ x$feature_platform_search_hint = xy ]; then
	  search --no-floppy --fs-uuid --set=root --hint='lvmid/${VG_UUID}/${LV_UUID_BOOT}'  ${BOOT_VG_UUID}
	else
	  search --no-floppy --fs-uuid --set=root ${BOOT_VG_UUID}
	fi
	echo	'Loading Linux lts ...'
	linux	/vmlinuz-lts root=/dev/mapper/vg0-root ro  modules=sd-mod,usb-storage,ext4 quiet rootfstype=ext4 cryptroot=UUID=$ROOT_PART_UUID cryptdm=lvmcrypt cryptkey
	echo	'Loading initial ramdisk ...'
	initrd	/initramfs-lts
}

### END /etc/grub.d/10_linux ###

### BEGIN /etc/grub.d/20_linux_xen ###

### END /etc/grub.d/20_linux_xen ###

### BEGIN /etc/grub.d/30_os-prober ###
### END /etc/grub.d/30_os-prober ###

### BEGIN /etc/grub.d/30_uefi-firmware ###
menuentry 'UEFI Firmware Settings' $menuentry_id_option 'uefi-firmware' {
	fwsetup
}
### END /etc/grub.d/30_uefi-firmware ###

### BEGIN /etc/grub.d/40_custom ###
# This file provides an easy way to add custom menu entries.  Simply type the
# menu entries you want to add after this comment.  Be careful not to change
# the 'exec tail' line above.
### END /etc/grub.d/40_custom ###

### BEGIN /etc/grub.d/41_custom ###
if [ -f  ${config_directory}/custom.cfg ]; then
  source ${config_directory}/custom.cfg
elif [ -z "${config_directory}" -a -f  $prefix/custom.cfg ]; then
  source $prefix/custom.cfg
fi
### END /etc/grub.d/41_custom ###



###########################################################################################
###########################################################################################
###########################################################################################



# set default=0
# set timeout=10
# 
# set gfxmode=auto
# set gfxpayload=keep
# insmod all_video
# insmod gfxterm
# 
# menuentry "k3OS Current" {
#   search.fs_label K3OS_STATE root
#   set sqfile=/k3os/system/kernel/current/kernel.squashfs
#   loopback loop0 /\$sqfile
#   set root=(\$root)
#   linux (loop0)/vmlinuz printk.devkmsg=on console=tty1 $GRUB_DEBUG
#   initrd /k3os/system/kernel/current/initrd
# }
# 
# menuentry "k3OS Previous" {
#   search.fs_label K3OS_STATE root
#   set sqfile=/k3os/system/kernel/previous/kernel.squashfs
#   loopback loop0 /\$sqfile
#   set root=(\$root)
#   linux (loop0)/vmlinuz printk.devkmsg=on console=tty1 $GRUB_DEBUG
#   initrd /k3os/system/kernel/previous/initrd
# }
# 
# menuentry "k3OS Rescue (current)" {
#   search.fs_label K3OS_STATE root
#   set sqfile=/k3os/system/kernel/current/kernel.squashfs
#   loopback loop0 /\$sqfile
#   set root=(\$root)
#   linux (loop0)/vmlinuz printk.devkmsg=on rescue console=tty1
#   initrd /k3os/system/kernel/current/initrd
# }
# 
# menuentry "k3OS Rescue (previous)" {
#   search.fs_label K3OS_STATE root
#   set sqfile=/k3os/system/kernel/previous/kernel.squashfs
#   loopback loop0 /\$sqfile
#   set root=(\$root)
#   linux (loop0)/vmlinuz printk.devkmsg=on rescue console=tty1
#   initrd /k3os/system/kernel/previous/initrd
# }
EOF

    if [ -z "${K3OS_INSTALL_TTY}" ]; then
        TTY=$(tty | sed 's!/dev/!!')
    else
        TTY=$K3OS_INSTALL_TTY
    fi
    if [ -e "/dev/${TTY%,*}" ] && [ "$TTY" != tty1 ] && [ "$TTY" != console ] && [ -n "$TTY" ]; then
        sed -i "s!console=tty1!console=tty1 console=${TTY}!g" ${TARGET}/boot/grub/grub.cfg
    fi

    if [ "$K3OS_INSTALL_NO_FORMAT" = "true" ]; then
        return 0
    fi

    if [ "$K3OS_INSTALL_FORCE_EFI" = "true" ]; then
        if [ $(uname -m) = "aarch64" ]; then
            GRUB_TARGET="--target=arm64-efi"
        else
            GRUB_TARGET="--target=x86_64-efi"
        fi
    fi

    grub-install ${GRUB_TARGET} --boot-directory=${TARGET}/boot --removable ${DEVICE} 
}

get_iso()
{
    ISO_DEVICE=$(blkid -L K3OS || true)
    if [ -z "${ISO_DEVICE}" ]; then
        for i in $(lsblk -o NAME,TYPE -n | grep -w disk | awk '{print $1}'); do
            mkdir -p ${DISTRO}
            if mount -o ro /dev/$i ${DISTRO}; then
                ISO_DEVICE="/dev/$i"
                umount ${DISTRO}
                break
            fi
        done
    fi

    if [ -z "${ISO_DEVICE}" ] && [ -n "$K3OS_INSTALL_ISO_URL" ]; then
        TEMP_FILE=$(mktemp k3os.XXXXXXXX.iso)
        get_url ${K3OS_INSTALL_ISO_URL} ${TEMP_FILE}
        ISO_DEVICE=$(losetup --show -f $TEMP_FILE)
        rm -f $TEMP_FILE
    fi

    if [ -z "${ISO_DEVICE}" ]; then
        echo "#### There is no k3os ISO device"
        return 1
    fi
}

setup_style()
{
    if [ "$K3OS_INSTALL_FORCE_EFI" = "true" ] || [ -e /sys/firmware/efi ]; then
        PARTTABLE=gpt
        BOOTFLAG=esp
        if [ ! -e /sys/firmware/efi ]; then
            echo WARNING: installing EFI on to a system that does not support EFI
        fi
    else
        PARTTABLE=msdos
        BOOTFLAG=boot
    fi
}

validate_progs()
{
    for i in $PROGS; do
        if [ ! -x "$(which $i)" ]; then
            MISSING="${MISSING} $i"
        fi
    done

    if [ -n "${MISSING}" ]; then
        echo "The following required programs are missing for installation: ${MISSING}"
        exit 1
    fi
}

validate_device()
{
    DEVICE=$K3OS_INSTALL_DEVICE
    if [ ! -b ${DEVICE} ]; then
        echo "You should use an available device. Device ${DEVICE} does not exist."
        exit 1
    fi
}

create_opt()
{
    mkdir -p "${TARGET}/k3os/data/opt"
}

while [ "$#" -gt 0 ]; do
    case $1 in
        --no-format)
            K3OS_INSTALL_NO_FORMAT=true
            ;;
        --encrypt-fs)
            K3OS_ENCRYPT_FILESYSTEM=true
            ;;
        --tang-server)
            shift 1
            K3OS_TANG_SERVER_URL=$1
            ;;
        --luks-password)
            shift 1
            K3OS_LUKS_PASSWORD=$1
            ;;
        --force-efi)
            K3OS_INSTALL_FORCE_EFI=true
            ;;
        --poweroff)
            K3OS_INSTALL_POWER_OFF=true
            ;;
        --takeover)
            K3OS_INSTALL_TAKE_OVER=true
            ;;
        --debug)
            set -x
            K3OS_INSTALL_DEBUG=true
            ;;
        --config)
            shift 1
            K3OS_INSTALL_CONFIG_URL=$1
            ;;
        --tty)
            shift 1
            K3OS_INSTALL_TTY=$1
            ;;
        -h)
            usage
            ;;
        --help)
            usage
            ;;
        *)
            if [ "$#" -gt 2 ]; then
                usage
            fi
            INTERACTIVE=true
            K3OS_INSTALL_DEVICE=$1
            K3OS_INSTALL_ISO_URL=$2
            break
            ;;
    esac
    shift 1
done

if [ -e /etc/environment ]; then
    source /etc/environment
fi

if [ -e /etc/os-release ]; then
    source /etc/os-release

    if [ -z "$K3OS_INSTALL_ISO_URL" ]; then
        K3OS_INSTALL_ISO_URL=${ISO_URL}
    fi
fi

if [ -z "$K3OS_INSTALL_DEVICE" ]; then
    usage
fi

validate_progs
validate_device

trap cleanup exit

write_config() 
{

cat > /etc/cloudinit.yaml << EOF
k3os:
  modules:
  - kvm
  - nvme
  - usb
  - kms
  - keymap
  - lvm
  - ext4
  - cryptsetup
  - cryptkey
  password: rancher
EOF
}

write_config
get_iso
setup_style
do_format
do_encrypt
do_mount
do_copy
install_grub
create_opt

if [ -n "$INTERACTIVE" ]; then
    exit 0
fi

if [ "$K3OS_INSTALL_POWER_OFF" = true ] || grep -q 'k3os.install.power_off=true' /proc/cmdline; then
    poweroff -f
else
    echo " * Rebooting system in 5 seconds (CTRL+C to cancel)"
    sleep 5
    reboot -f
fi
