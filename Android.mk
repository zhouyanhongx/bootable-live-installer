LOCAL_PATH := $(call my-dir)
include $(CLEAR_VARS)

ifeq ($(HOST_OS),linux)
include $(CLEAR_VARS)
LOCAL_SRC_FILES := \
		../../system/core/libdiskconfig/diskconfig.c \
		../../system/core/libdiskconfig/diskutils.c \
		../../system/core/libdiskconfig/write_lst.c \
		../../system/core/libdiskconfig/config_mbr.c
LOCAL_C_INCLUDES += system/core/libdiskconfig/include
LOCAL_MODULE := libdiskconfig_host_grub
LOCAL_MODULE_TAGS := optional
LOCAL_CFLAGS := -O2 -g -W -Wall -Werror -D_LARGEFILE64_SOURCE
include $(BUILD_HOST_STATIC_LIBRARY)
endif # HOST_OS == linux

include $(CLEAR_VARS)
LOCAL_MODULE := install_mbr
LOCAL_C_INCLUDES += system/core/libdiskconfig/include
LOCAL_SRC_FILES := editdisklbl/editdisklbl.c
LOCAL_CFLAGS := -O2 -g -W -Wall -Werror# -D_LARGEFILE64_SOURCE
LOCAL_STATIC_LIBRARIES := libdiskconfig_host_grub libcutils liblog
install_mbr := $(HOST_OUT_EXECUTABLES)/$(LOCAL_MODULE)
UNSPARSER := $(HOST_OUT_EXECUTABLES)/simg2img
SQUASHER := $(HOST_OUT_EXECUTABLES)/mksquashfs
include $(BUILD_HOST_EXECUTABLE)

GRUB_DEFAULT := 0
ifeq ($(CI_BUILD),true)
GRUB_TIMEOUT := 1
else
GRUB_TIMEOUT := 10
endif

BDATE ?= $(shell date +"%F")
TARGET_INITRD_DIR := $(PRODUCT_OUT)/initrd
LOCAL_INITRD_DIR := $(LOCAL_PATH)/initrd
BOOT_DIR := $(LOCAL_PATH)/boot
INITRD := $(PRODUCT_OUT)/initrd.img
$(INITRD): $(LOCAL_PATH)/initrd/init $(wildcard $(LOCAL_PATH)/initrd/*/*) | $(MKBOOTFS)
	rm -rf $(TARGET_INITRD_DIR)
	$(ACP) -dprf $(LOCAL_INITRD_DIR) $(TARGET_INITRD_DIR)
	echo "BUILDDATE=$(BDATE)" > $(TARGET_INITRD_DIR)/scripts/3-buildinfo
	echo "CI_BUILD=$(CI_BUILD)" >> $(TARGET_INITRD_DIR)/scripts/3-buildinfo
	sed "s|SERIAL_PORT|$(SERIAL_PARAMETER)|" $(LOCAL_INITRD_DIR)/scripts/2-install > $(TARGET_INITRD_DIR)/scripts/2-install
	mkdir -p $(addprefix $(TARGET_INITRD_DIR)/,mnt proc sys tmp dev etc lib newroot sbin usr/bin usr/sbin scratchpad)
	$(MKBOOTFS) $(TARGET_INITRD_DIR) | gzip -9 > $@

$(PRODUCT_OUT)/vendor.sfs : $(PRODUCT_OUT)/vendor.img | $(UNSPARSER) $(SQUASHER)
	simg2img $(PRODUCT_OUT)/{vendor.img,vendor.unsparse}
	mksquashfs $(PRODUCT_OUT)/{vendor.unsparse,vendor.sfs} -noappend
#	rm $(PRODUCT_OUT)/vendor.{img,unsparse}

$(PRODUCT_OUT)/system.sfs : $(PRODUCT_OUT)/system.img | $(UNSPARSER) $(SQUASHER)
	simg2img $(PRODUCT_OUT)/{system.img,system.unsparse}
	mksquashfs $(PRODUCT_OUT)/{system.unsparse,system.sfs} -noappend
#	rm $(PRODUCT_OUT)/system.{img,unsparse}


# 1. Compute the disk file size need in blocks for a block size of 1M
# 2. Prepare a vfat disk file and copy necessary files
# 3. Copy GRUB2 files
PROJECT_CELADON-EFI := $(PRODUCT_OUT)/$(TARGET_PRODUCT).img
DISK_LAYOUT := $(LOCAL_PATH)/editdisklbl/disk_layout.conf

GRUB_FILES := $(addprefix $(PRODUCT_OUT)/,initrd.img kernel ramdisk.img system.sfs vendor.sfs boot.img efi/kernelflinger.efi)
SRC_GRUBCFG := $(BOOT_DIR)/boot/grub/grub.cfg

ifeq ($(BOARD_AVB_ENABLE),true)
GRUB_FILES += $(PRODUCT_OUT)/vbmeta.img
SRC_GRUBCFG := $(BOOT_DIR)/boot/grub/grub_kfonly.cfg
endif

ifneq ($(BOARD_SLOT_AB_ENABLE),true)
GRUB_FILES += $(PRODUCT_OUT)/recovery.img
endif

ifeq ($(TARGET_USE_TRUSTY),true)
GRUB_FILES += $(PRODUCT_OUT)/tos.img
endif

$(PROJECT_CELADON-EFI): $(GRUB_FILES) | $(install_mbr)
	blksize=0; \
	for size in `du -sBM --apparent-size $^ | awk '{print $$1}' | cut -d'M' -f1`; do \
		blksize=$$(($$blksize + $$size)); \
	done; \
	blksize=$$(($$(($$blksize + 64)) * 1024));	\
	rm -f $@.fat; mkdosfs -n PROJECTCELADON -C $@.fat $$blksize
	mcopy -Qsi $@.fat $(BOOT_DIR)/* $^ ::
	sed "s|KERNEL_CMDLINE|$(BOARD_KERNEL_CMDLINE)|; s|BUILDDATE|$(BDATE)|; s|GRUB_DEFAULT|$(GRUB_DEFAULT)|; s|GRUB_TIMEOUT|$(GRUB_TIMEOUT)|; s|console=tty[^ ]* ||g; s|SERIAL_PORT|$(SERIAL_PARAMETER)|g; s|CONSOLE|console=tty0|g; s|memmap=[^ ]*||g" $(SRC_GRUBCFG) > $(@D)/grub.cfg
	mcopy -Qoi $@.fat $(@D)/grub.cfg ::boot/grub
	cat /dev/null > $@; $(install_mbr) -l $(DISK_LAYOUT) -i $@ oand=$@.fat
	rm -f $@.fat

.PHONY: project_celadon-efi
project_celadon-efi: $(PROJECT_CELADON-EFI)

