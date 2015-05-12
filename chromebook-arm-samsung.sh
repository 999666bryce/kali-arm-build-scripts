#!/bin/bash

if [[ $# -eq 0 ]] ; then
    echo "Please pass version number, e.g. $0 1.0.1"
    exit 0
fi

basedir=`pwd`/chromebook-$1

# Make sure that the cross compiler can be found in the path before we do
# anything else, that way the builds don't fail half way through.
export CROSS_COMPILE=arm-linux-gnueabihf-
if [ $(compgen -c $CROSS_COMPILE | wc -l) -eq 0 ] ; then
    echo "Missing cross compiler. Set up PATH according to the README"
    exit 1
fi
# Unset CROSS_COMPILE so that if there is any native compiling needed it doesn't
# get cross compiled.
unset CROSS_COMPILE

# Package installations for various sections.
# This will build a minimal Gnome Kali system with the top 10 tools.
# This is the section to edit if you would like to add more packages.
# See http://www.kali.org/new/kali-linux-metapackages/ for meta packages you can
# use.  You can also install packages, using just the package name, but keep in
# mind that not all packages work on ARM! If you specify one of those, the
# script will throw an error, but will still continue on, and create an unusable
# image, keep that in mind.

arm="abootimg cgpt fake-hwclock ntpdate vboot-utils vboot-kernel-utils uboot-mkimage"
base="kali-menu kali-defaults initramfs-tools usbutils"
desktop="gdm3 gnome-core gnome-brave-icon-theme gnome-orca gnome-shell-extensions kali-root-login xserver-xorg-video-fbdev"
tools="passing-the-hash winexe aircrack-ng hydra john sqlmap wireshark libnfc-bin mfoc"
services="openssh-server apache2"
extras="iceweasel wpasupplicant"

export packages="${arm} ${base} ${desktop} ${tools} ${services} ${extras}"
export architecture="armhf"
# If you have your own preferred mirrors, set them here.
# You may want to leave security.kali.org alone, but if you trust your local
# mirror, feel free to change this as well.
# After generating the rootfs, we set the sources.list to the default settings.
export mirror=http.kali.org
export security=security.kali.org

# Set this to use an http proxy, like apt-cacher-ng, and uncomment further down
# to unset it.
#export http_proxy="http://localhost:3142/"

mkdir -p ${basedir}
cd ${basedir}

# create the rootfs - not much to modify here, except maybe the hostname.
debootstrap --foreign --arch $architecture kali kali-$architecture http://$mirror/kali

cp /usr/bin/qemu-arm-static kali-$architecture/usr/bin/

LANG=C chroot kali-$architecture /debootstrap/debootstrap --second-stage

# Create sources.list
cat << EOF > kali-$architecture/etc/apt/sources.list
deb http://$mirror/kali kali main contrib non-free
deb http://$security/kali-security kali/updates main contrib non-free
EOF

# Set hostname
echo "kali" > kali-$architecture/etc/hostname

# So X doesn't complain, we add kali to hosts
cat << EOF > kali-$architecture/etc/hosts
127.0.0.1       kali    localhost
::1             localhost ip6-localhost ip6-loopback
fe00::0         ip6-localnet
ff00::0         ip6-mcastprefix
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

cat << EOF > kali-$architecture/etc/network/interfaces
auto lo
iface lo inet loopback
EOF

cat << EOF > kali-$architecture/etc/resolv.conf
nameserver 8.8.8.8
EOF

export MALLOC_CHECK_=0 # workaround for LP: #520465
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

mount -t proc proc kali-$architecture/proc
mount -o bind /dev/ kali-$architecture/dev/
mount -o bind /dev/pts kali-$architecture/dev/pts

cat << EOF > kali-$architecture/debconf.set
console-common console-data/keymap/policy select Select keymap from full list
console-common console-data/keymap/full select en-latin1-nodeadkeys
EOF

cat << EOF > kali-$architecture/third-stage
#!/bin/bash
dpkg-divert --add --local --divert /usr/sbin/invoke-rc.d.chroot --rename /usr/sbin/invoke-rc.d
cp /bin/true /usr/sbin/invoke-rc.d
echo -e "#!/bin/sh\nexit 101" > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

apt-get update
apt-get install locales-all

debconf-set-selections /debconf.set
rm -f /debconf.set
apt-get update
apt-get -y install git-core binutils ca-certificates initramfs-tools uboot-mkimage
apt-get -y install locales console-common less nano git
echo "root:toor" | chpasswd
sed -i -e 's/KERNEL\!=\"eth\*|/KERNEL\!=\"/' /lib/udev/rules.d/75-persistent-net-generator.rules
rm -f /etc/udev/rules.d/70-persistent-net.rules
apt-get --yes --force-yes install $packages

rm -f /usr/sbin/policy-rc.d
rm -f /usr/sbin/invoke-rc.d
dpkg-divert --remove --rename /usr/sbin/invoke-rc.d

rm -f /third-stage
EOF

chmod +x kali-$architecture/third-stage
LANG=C chroot kali-$architecture /third-stage

cat << EOF > kali-$architecture/cleanup
#!/bin/bash
rm -rf /root/.bash_history
apt-get update
apt-get clean
rm -f /0
rm -f /hs_err*
rm -f cleanup
rm -f /usr/bin/qemu*
EOF

chmod +x kali-$architecture/cleanup
LANG=C chroot kali-$architecture /cleanup

umount kali-$architecture/proc/sys/fs/binfmt_misc
umount kali-$architecture/dev/pts
umount kali-$architecture/dev/
umount kali-$architecture/proc

echo "Creating image file for Chromebook"
dd if=/dev/zero of=${basedir}/kali-$1-chromebook.img bs=1M count=7000
parted kali-$1-chromebook.img --script -- mklabel gpt
cgpt create -z kali-$1-chromebook.img
cgpt create kali-$1-chromebook.img

cgpt add -i 1 -t kernel -b 8192 -s 32768 -l U-Boot -S 1 -T 5 -P 10 kali-$1-chromebook.img
cgpt add -i 2 -t data -b 40960 -s 32768 -l Kernel kali-$1-chromebook.img
cgpt add -i 12 -t data -b 73728 -s 32768 -l Script kali-$1-chromebook.img
cgpt add -i 3 -t data -b 106496 -s `expr $(cgpt show kali-$1-chromebook.img | grep 'Sec GPT table' | awk '{ print \$1 }')  - 106496` -l Root kali-$1-chromebook.img

loopdevice=`losetup -f --show ${basedir}/kali-$1-chromebook.img`
device=`kpartx -va $loopdevice| sed -E 's/.*(loop[0-9])p.*/\1/g' | head -1`
device="/dev/mapper/${device}"
bootp=${device}p2
rootp=${device}p3
scriptp=${device}p12
ubootp=${device}p1

mkfs.ext2 $bootp
mkfs.ext4 $rootp
mkfs.vfat -F 16 $scriptp

mkdir -p ${basedir}/bootp ${basedir}/root ${basedir}/script
mount $bootp ${basedir}/bootp
mount $rootp ${basedir}/root
mount $scriptp ${basedir}/script

echo "Rsyncing rootfs into image file"
rsync -HPavz -q ${basedir}/kali-$architecture/ ${basedir}/root/

cat << EOF > ${basedir}/root/etc/apt/sources.list
deb http://http.kali.org/kali kali main non-free contrib
deb http://security.kali.org/kali-security kali/updates main contrib non-free

deb-src http://http.kali.org/kali kali main non-free contrib
deb-src http://security.kali.org/kali-security kali/updates main contrib non-free
EOF

# Uncomment this if you use apt-cacher-ng otherwise git clones will fail.
#unset http_proxy

# Kernel section.  If you want to use a custom kernel, or configuration, replace
# them in this section. Currently we're using 3.4, but there will be a switch to
# 3.8.
git clone --depth 1 https://chromium.googlesource.com/chromiumos/third_party/kernel -b chromeos-3.8 ${basedir}/kernel
cd ${basedir}/kernel
cp ${basedir}/../kernel-configs/chromebook-3.8_wireless-3.4.config .config
export ARCH=arm
# Edit the CROSS_COMPILE variable as needed.
export CROSS_COMPILE=arm-linux-gnueabihf-
patch -p1 --no-backup-if-mismatch < ${basedir}/../patches/mac80211-3.4.patch
patch -p1 --no-backup-if-mismatch < ${basedir}/../patches/0001-exynos-drm-smem-start-len.patch
# sed -i 's/CONFIG_ERROR_ON_WARNING=y/# CONFIG_ERROR_ON_WARNING is not set/g' .config
make WIFIVERSION="-3.4" -j $(grep -c processor /proc/cpuinfo)
make WIFIVERSION="-3.4" dtbs
make WIFIVERSION="-3.4" modules_install INSTALL_MOD_PATH=${basedir}/root
cat << __EOF__ > ${basedir}/kernel/arch/arm/boot/kernel-snow.its
/dts-v1/;

/ {
    description = "Chrome OS kernel image with one or more FDT blobs";
    #address-cells = <1>;
    images {
        kernel@1{
   description = "kernel";
            data = /incbin/("zImage");
            type = "kernel_noload";
            arch = "arm";
            os = "linux";
            compression = "none";
            load = <0>;
            entry = <0>;
        };
        fdt@1{
            description = "exynos5250-snow-rev4.dtb";
            data = /incbin/("dts/exynos5250-snow-rev4.dtb");
            type = "flat_dt";
            arch = "arm";
            compression = "none";
            hash@1{
                algo = "sha1";
            };
        };
        fdt@2{
            description = "exynos5250-snow-rev5.dtb";
            data = /incbin/("dts/exynos5250-snow-rev5.dtb");
            type = "flat_dt";
            arch = "arm";
            compression = "none";
            hash@1{
                algo = "sha1";
            };
        };
    };
    configurations {
        default = "conf@1";
        conf@1{
            kernel = "kernel@1";
            fdt = "fdt@1";
        };
        conf@2{
            kernel = "kernel@1";
            fdt = "fdt@2";
        };
    };
};
__EOF__
cd ${basedir}/kernel/arch/arm/boot
mkimage -f kernel-snow.its ${basedir}/bootp/vmlinux.uimg
cd ${basedir}

# Create boot.txt file
mkdir ${basedir}/script/u-boot/
cat << EOF > ${basedir}/script/u-boot/boot.txt
setenv bootpart 3
setenv rootpart 2
setenv regen_ext2_bootargs 'setenv bootdev_bootargs root=/dev/\${devname}\${bootpart} quiet rootfstype=ext4 rootwait rw lsm.module_locking=0'
setenv cros_bootfile /vmlinux.uimg
setenv extra_bootargs console=tty1
setenv mmc0_boot echo ERROR: Could not boot from USB or SD
EOF

# Create u-boot boot script image
mkimage -A arm -T script -C none -d ${basedir}/script/u-boot/boot.txt ${basedir}/script/u-boot/boot.scr.uimg

# Touchpad configuration
mkdir -p ${basedir}/root/etc/X11/xorg.conf.d
cat << EOF > ${basedir}/root/etc/X11/xorg.conf.d/10-synaptics-chromebook.conf
Section "InputClass"
	Identifier		"touchpad"
	MatchIsTouchpad		"on"
	Driver			"synaptics"
	Option			"TapButton1"	"1"
	Option			"TapButton2"	"3"
	Option			"TapButton3"	"2"
	Option			"FingerLow"	"15"
	Option			"FingerHigh"	"20"
	Option			"FingerPress"	"256"
EndSection
EOF
# Turn off DPMS, this is supposed to help with fbdev/armsoc blanking.
# Doesn't really seem to affect fbdev, but marked improvement with armsoc.
cat << EOF > ${basedir}/root/etc/X11/xorg.conf
Section "ServerFlags"
    Option     "NoTrapSignals" "true"
    Option     "DontZap" "false"

    # Disable DPMS timeouts.
    Option     "StandbyTime" "0"
    Option     "SuspendTime" "0"
    Option     "OffTime" "0"

    # Disable screen saver timeout.
    Option     "BlankTime" "0"
EndSection

Section "Monitor"
    Identifier "DefaultMonitor"
EndSection

Section "Device"
    Identifier "DefaultDevice"
    Option     "monitor-LVDS1" "DefaultMonitor"
EndSection

Section "Screen"
    Identifier "DefaultScreen"
    Monitor    "DefaultMonitor"
    Device     "DefaultDevice"
EndSection

Section "ServerLayout"
    Identifier "DefaultLayout"
    Screen     "DefaultScreen"
EndSection
EOF

# At the moment we use fbdev, but in the future, we will switch to the armsoc
# driver provided by ChromiumOS.
cat << EOF > ${basedir}/root/etc/X11/xorg.conf.d/20-armsoc.conf
Section "Device"
        Identifier      "Mali FBDEV"
#       Driver          "armsoc"
	Driver		"fbdev"
        Option          "fbdev"                 "/dev/fb0"
        Option          "Fimg2DExa"             "false"
        Option          "DRI2"                  "true"
        Option          "DRI2_PAGE_FLIP"        "false"
        Option          "DRI2_WAIT_VSYNC"       "true"
#       Option          "Fimg2DExaSolid"        "false"
#       Option          "Fimg2DExaCopy"         "false"
#       Option          "Fimg2DExaComposite"    "false"
        Option          "SWcursorLCD"           "false"
EndSection

Section "Screen"
        Identifier      "DefaultScreen"
        Device          "Mali FBDEV"
        DefaultDepth    24
EndSection
EOF

rm -rf ${basedir}/root/lib/firmware
cd ${basedir}/root/lib
git clone https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git firmware
rm -rf ${basedir}/root/lib/firmware/.git
cd ${basedir}

# Unmount partitions
umount $bootp
umount $rootp
umount $scriptp

# This is the u-boot bootloader that gets written to the first partition. When
# you hit CTRL+U, this is what gets read first.  If you want to customize your
# u-boot in some way, you will need to read the ChromiumOS dev wiki.
# http://www.chromium.org/chromium-os/developer-guide
wget -O - http://commondatastorage.googleapis.com/chromeos-localmirror/distfiles/nv_uboot-snow.kpart.bz2 | bunzip2 > nv_uboot-snow.kpart
dd if=nv_uboot-snow.kpart of=$ubootp

kpartx -dv $loopdevice
losetup -d $loopdevice

# Clean up all the temporary build stuff and remove the directories.
# Comment this out to keep things around if you want to see what may have gone
# wrong.
echo "Removing temporary build files"
rm -rf ${basedir}/kernel ${basedir}/bootp ${basedir}/root ${basedir}/kali-$architecture ${basedir}/patches ${basedir}/nv_uboot-snow.kpart ${basedir}/script

# If you're building an image for yourself, comment all of this out, as you
# don't need the sha1sum or to compress the image, since you will be testing it
# soon.
echo "Generating sha1sum for kali-$1-chromebook.img"
sha1sum kali-$1-chromebook.img > ${basedir}/kali-$1-chromebook.img.sha1sum
# Don't pixz on 32bit, there isn't enough memory to compress the images.
MACHINE_TYPE=`uname -m`
if [ ${MACHINE_TYPE} == 'x86_64' ]; then
echo "Compressing kali-$1-chromebook.img"
pixz ${basedir}/kali-$1-chromebook.img ${basedir}/kali-$1-chromebook.img.xz
rm ${basedir}/kali-$1-chromebook.img
echo "Generating sha1sum for kali-$1-chromebook.img.xz"
sha1sum kali-$1-chromebook.img.xz > ${basedir}/kali-$1-chromebook.img.xz.sha1sum
fi
