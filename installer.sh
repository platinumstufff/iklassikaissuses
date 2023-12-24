#!/bin/bash

supported_components=("OpenGApps")

AMD64_REC_URL='https://fydeos.com/arc-rec/arc-rec-x86_64.tar.gz'
ARM_REC_URL='https://fydeos.com/arc-rec/arc-rec-arm64.tar.gz'

is_arcvm() {
	[[ -a /opt/google/vms/android/system.raw.img ]]
}

arc_mode=arcpp
if is_arcvm; then
  arc_mode=arcvm
fi

is_testmode() {
#  local test_mode=`cat /etc/lsb-release 2>/dev/null |grep CHROMEOS_RELEASE_BUILD_TYPE |grep "Test Build"`
#  [[ -n "$test_mode" ]]
# Skip test mode, but we need local package for arcvm"
  is_arcvm
}

# dirs
data_dir="/home/chronos/fydeos-arc"
arc_rec_dir="${data_dir}/arc-rec"
zip_dir="${data_dir}/zip"
work_dir="${data_dir}/work_dir"
tmp_dir="${data_dir}/tmp_dir"
arc_env_dir="${arc_rec_dir}/env"
payload_dir="${arc_env_dir}/payload"
root_dir="${arc_env_dir}/root"
arc_env_config="${arc_env_dir}/config.json"
arcvm_env_config="${arc_env_dir}/config_vm.json"
arcpp_env_config="${arc_env_dir}/config_cpp.json"

system_rw_dir="${work_dir}/system_rw"
backup_dir="${data_dir}/backup"

# files to download
pkg_arc_rec="${data_dir}/arc-rec.tar.gz"
uname_ret=$(uname -m)
if [[ $uname_ret = "aarch64" ]]; then
	pkg_arc_rec_url=$ARM_REC_URL
else
	pkg_arc_rec_url=$AMD64_REC_URL
fi
before_hook_sh="${zip_dir}/before_hook.sh"
update_zip="${zip_dir}/update.zip"
after_hook_sh="${zip_dir}/after_hook.sh"

local_arc_rec_bak_path="/usr/share/fydeos_shell/arc-rec"
pkg_arc_rec_local="${local_arc_rec_bak_path}/arc-rec-x86_64.tar.gz"
if [[ $uname_ret = "aarch64" ]]; then
	pkg_arc_rec_local="${local_arc_rec_bak_path}/arc-rec-arm64.tar.gz"
fi
after_hook_sh_local_bak="${local_arc_rec_bak_path}/after_hook.sh"

# scripts
flash_zip_sh="${arc_rec_dir}/flash_zip.sh"

# files
origin_img_md5_file="${backup_dir}/system.raw.img.origin.md5"
origin_img_file="${backup_dir}/system.raw.img.origin"
components_file="${data_dir}/components.list"
cur_img_path="/opt/google/containers/android/system.raw.img"
cur_img_md5_file="${data_dir}/system.raw.img.current.md5"
install_log_file="${data_dir}/install.log"
install_log_fifo_file="${data_dir}/install.log.fifo"
new_system_img="${data_dir}/system.raw.img.new"
runc_exe="${arc_rec_dir}/runc"
runc_exe_overlayfs="run_oci"

# others
zip_command="/usr/bin/zip"
if [[ ! -x "$zip_command" ]]; then
  zip_command="/usr/local/bin/zip"
fi

# errno
err_terrible_failure=2
err_network=3
err_flash=4
err_backup=5
err_exchange=6
err_file_not_found=7
err_io=8

overlayfs_mnt=/mnt/stateful_partition/unencrypted/android/root_rw
overlayfs_top=/mnt/stateful_partition/unencrypted/android/root_up
overlayfs_work=/mnt/stateful_partition/unencrypted/android/root_work

# Refactoring Open GApps ++
props_dir="/usr/share/arc/properties"
if is_arcvm; then
  props_dir="/usr/share/arcvm/properties"
fi
default_url="www.google.com"
# Refactoring Open GApps --

use_overlayfs() {
  mount | grep $overlayfs_mnt 2>&1 >/dev/null
  [ $? -eq 0 ]
}

android_data_dir() {
  if is_arcvm; then
    local user_mount=`mount |grep "/home/root" | awk '{print $3}'`
    if [ -n "$user_mount" ]; then
      echo $user_mount/android-data/data
    else
      echo ~
    fi
  else
    echo "/opt/google/containers/android/rootfs/android-data/data"
  fi
}

usage(){
    echo "usage: installer.sh <component_name> <command> [arg]..."
    echo ""
    echo "commands:"
    echo "    test-network              do a network test"
    echo "    prepare                   download enviroment and extract it into <data_dir>/arc-rec/"
    echo "    download <before_hook_sh_url> <update_zip_url or zip_file_absolute_path> <after_hook_sh_url>"
    echo "                              use \"-\" to indicate that the parameter does not exist"
    echo "    flash                     flash the update.zip into <cur_img_path> file and package"
    echo "                              into <new_system_img>"
    echo "    replace                   replace <new_system_img> with <cur_img_path>"
    echo "    clear                     clear after flash"
    echo "    restore                   uninstall this component"
    echo "    status                    print status infomation with JSON syntax"
    echo ""
    echo "supported component_name:     ${supported_components[*]}"
    echo ""
    echo "constant values:"
    echo "    component_name:   ${component_name}"
    echo "    data_dir:         ${data_dir}"
    echo "    cur_img_path:     ${cur_img_path}"
    echo "    new_system_img:   ${new_system_img}"
}


error(){
    local status=$1
    echo -n "(exit ${status}) "
    if [[ $2 == "" ]]; then
        # default msg
        case ${status} in
            ${err_terrible_failure} )
                echo "what a terrible failure!"
                ;;
            ${err_network} )
                echo "network error"
                ;;
            ${err_flash} )
                echo "install failed"
                ;;
            ${err_backup} )
                echo "backup failed"
                ;;
            ${err_exchange} )
                echo "install failed"
                ;;
            ${err_file_not_found} )
                echo "file not found"
                ;;
            ${err_io} )
                echo "IO error, please reboot and try again"
                ;;
            *)
                echo "unknown problem"
                ;;
        esac
        exit ${status}
    else
        shift
        echo $@
        exit ${status}
    fi
}

wget_wrapper(){
    # wget --dns-timeout=10 --connect-timeout=10 --read-timeout=5 --progress=bar:force:noscroll $@
    curl -L --progress-bar --connect-timeout 15 --retry 2 "$@"
}

# expand_stateful_partition(){
#     local part=$(df "/mnt/stateful_partition" | tail -n +2 | awk '{print $1}')
#     echo "stateful partition is ${part}"
#     expand-partition.sh --dst ${part}
# }

use_local_bak() {
  local source="$1"
  local target="$2"

  cp -f "$source" "$target"
}

# Refactoring Open GApps ++
do_test_network() {
    url=${default_url}
    if [[ $# -eq 1 ]]; then
        url=$1
    fi

    curl --silent --retry 1 --max-time 6 ${url} -o /dev/null || error ${err_network}
}

replace_properties() {
    echo "[-] fix env..."
    mount -o rw,remount / || { echo "failed to mount / as Read-Write"; return 1; }
    for prop in `ls $props_dir/*.prop`; do
      sed -i "s;\(\.build\.fingerprint=\)$1\(.*\);\1$2\2;" $prop || { echo "failed to replace prop"; return 1; }
    done
    mount -o ro,remount /
    echo "[-] fix env done."
}

remove_old_gms_data() {
    # gsf
    local android_data=$(android_data_dir)
    find $android_data -name "*.gsf*" | xargs rm -rf

    # vending
    find $android_data -name "*.vending*" | xargs rm -rf

    # gms
    find $android_data -name "*.gms*" | xargs rm -rf


    # others
    rm -rf $android_data/system/sync/accounts.xml $android_data/system_*
}
# Refactoring Open GApps --

do_prepare(){
    # if is_booting_from_usb; then
    #     echo "Expanding partition for your USB device..."
    #     expand_stateful_partition
    # fi

	mkdir -p ${data_dir}
  if is_testmode; then
    use_local_bak "$pkg_arc_rec_local" "$pkg_arc_rec" || error ${err_network} "download failed"
  else
	  wget_wrapper -o ${pkg_arc_rec} ${pkg_arc_rec_url} || use_local_bak "$pkg_arc_rec_local" "$pkg_arc_rec" || error ${err_network} "download failed"
  fi
  clear_workdir
	rm -rf ${arc_rec_dir}
	tar -xvf ${pkg_arc_rec} -C ${data_dir} >/dev/null
  if is_arcvm; then
    cp $arcvm_env_config $arc_env_config
  else
    cp $arcpp_env_config $arc_env_config
  fi
}

resolve_update_zip(){
    if [[ $1 = /* ]]; then
        if [[ ! -f $1 ]]; then
            error ${err_file_not_found} "file not exit: $1"
        fi
        "$zip_command" -T $1 || error ${err_terrible_failure} "not a valied zip file"
# Refactoring Open GApps --
        cp $1 ${update_zip} || error ${err_terrible_failure} "copy update.zip falied"
    else
        local retry=3
        while [[ ${retry} -gt 0 ]]; do
            wget_wrapper -o ${update_zip} $1 || error ${err_network} "download failed"
            "$zip_command" -T ${update_zip} && break
            let retry--
        done

        if [[ ${retry} -eq 0 ]]; then
            # failed
            error ${err_terrible_failure} "not a valied zip file, pleae try again."
        fi
    fi
}

do_download(){
    mkdir -p ${zip_dir}

    [[ $1 && $1 != "-" ]] && { wget_wrapper -o ${before_hook_sh} $1 || error ${err_network} "download failed" ; }
    [[ $2 && $2 != "-" ]] && { resolve_update_zip $2; }
    if is_testmode; then
      [[ $3 && $3 != "-" ]] && { use_local_bak "$after_hook_sh_local_bak" "$after_hook_sh" || error ${err_network} "download failed" ; }
    else
      [[ $3 && $3 != "-" ]] && { wget_wrapper -o ${after_hook_sh} $3 || use_local_bak "$after_hook_sh_local_bak" "$after_hook_sh" || error ${err_network} "download failed" ; }
    fi
}


prepare_workdir(){
    local image_filename=`basename ${cur_img_path}`

    mkdir -p ${work_dir} || { clear_workdir; error ${err_io}; }
    mkdir -p "${work_dir}/system" || { clear_workdir; error ${err_io}; }
    cp ${cur_img_path} "${work_dir}/" || { clear_workdir; error ${err_io}; }
    mount -o loop,rw,sync "${work_dir}/${image_filename}" "${work_dir}/system" || { clear_workdir; error ${err_io}; }
    cp -a "${work_dir}/system" "${work_dir}/system_rw" || { clear_workdir; error ${err_io}; }
    umount "${work_dir}/system"
    mount --bind "${work_dir}/system_rw" ${root_dir} || { clear_workdir; error ${err_io}; }
}

clear_workdir(){
    umount -R ${root_dir} 1>/dev/null 2>&1
    umount -R "${work_dir}/system_rw" 1>/dev/null 2>&1
    umount -R "${work_dir}/system_rw" 1>/dev/null 2>&1
    umount -R "${work_dir}/system" 1>/dev/null 2>&1
    rm -rf ${work_dir} 1>/dev/null 2>&1
}

do_flash(){
  # clear_workdir -> prepare_workdir -> before_hook -> flash_zip -> after_hook -> package_newfs
  mkdir -p ${work_dir} || true
  mkdir -p ${root_dir} || true
	echo "[-] prepare files"
# Refactoring Open GApps ++
  remove_old_gms_data
# Refactoring Open GApps --
  if use_overlayfs; then
      umount $root_dir
      system_rw_dir=$overlayfs_mnt
      mount --bind $system_rw_dir $root_dir
  else
      clear_workdir
      prepare_workdir
  fi

	mkdir -p ${tmp_dir}
  [ -d "/sys/fs/cgroup/memory" ] && mkdir -p /sys/fs/cgroup/memory/android 1>/dev/null 2>&1
  [ -d "/sys/fs/cgroup/schedtune" ] && mkdir -p /sys/fs/cgroup/schedtune/android 1>/dev/null 2>&1

	echo "[-] prepare before installation"
    if [[ -f ${before_hook_sh} ]]; then
		  chmod u+x ${before_hook_sh}
		  ${before_hook_sh} ${update_zip} ${system_rw_dir} ${tmp_dir} || error ${err_flash} "exit with code $?"
    fi

	echo "[-] install"
  if use_overlayfs; then
    ${flash_zip_sh} ${runc_exe_overlayfs} ${root_dir} ${payload_dir} ${update_zip} ${arc_mode} || error ${err_flash} "exit with code $?"
  else
	  ${flash_zip_sh} ${runc_exe} ${root_dir} ${payload_dir} ${update_zip} ${arc_mode}|| error ${err_flash} "exit with code $?"
  fi
	echo "[-] prepare after installation"
    if [[ -f ${after_hook_sh} ]]; then
		  chmod u+x ${after_hook_sh}
		  ${after_hook_sh} ${update_zip} ${system_rw_dir} ${tmp_dir} ${arc_mode} || error ${err_flash} "exit with code $?"
    fi

	rm -rf ${tmp_dir}

  echo "[-] package files"
    if ! use_overlayfs; then
      rm -f ${new_system_img}
      ${arc_rec_dir}/mksquashfs "${work_dir}/system_rw" ${new_system_img} -quiet || error ${err_terrible_failure} "failed to package new image file"
    fi
  echo "[-] clear files"
      clear_workdir
      [ -d "/sys/fs/cgroup/memory/android" ] && rm -rf /sys/fs/cgroup/memory/android 1>/dev/null 2>&1
      [ -d "/sys/fs/cgroup/schedtune/android" ] && rm -rf /sys/fs/cgroup/schedtune/android 1>/dev/null 2>&1
}

need_backup(){
    # if no origin img exist, or current origin img is replaced
    # by a system update. in this case we should make a backup.

    if [[ ! -f ${origin_img_file} ]] || [[ ! `cat ${cur_img_md5_file}` ]] || [[ `cat ${cur_img_md5_file}` != `md5sum ${cur_img_path} | awk '{print $1}'` ]]; then
        return 0
    fi
    return 1
}

backup(){
    echo "[-] backup..."
    mkdir -p ${backup_dir} || error ${err_backup}

    local md5=`md5sum ${cur_img_path} | awk '{print $1}'`
    cp ${cur_img_path} ${origin_img_file} || error ${err_backup} "backup failed"
    echo "${md5}" > ${origin_img_md5_file}
}

mark_as_installed(){
    local components=`cat ${components_file} 2>/dev/null`
    if [[ ${components} != *${component_name}* ]]; then
        echo "${components},${component_name}" > ${components_file}
    fi
}

mark_as_uninstalled(){
    local components=`cat ${components_file} 2>/dev/null`
    if [[ ${components} = *${component_name}* ]]; then
        components=(${components//,/ })
        local i=0
        while [ $i -lt ${#components[*]} ];do
            if [[ ! "${components[$i]}" ]] || [[ "${components[$i]}" = "${component_name}" ]]; then
                unset components[$i]
            fi
            let i++
        done
        echo ${components[@]} | tr ' ' ',' > ${components_file}
    fi
}

check_if_installed(){
    local components=`cat ${components_file} 2>/dev/null`
    [[ ${components} = *${component_name}* ]] && return 0
    return 1
}

exchange_with_cur(){
    umount -A '/opt/google/containers/android/rootfs/root/' 1>/dev/null 2>&1
    kill `cat /run/containers/android-run_oci/container.pid 2>/dev/null` 1>/dev/null 2>&1

    # clear current img
    echo "" > ${cur_img_md5_file}
    # use new img

    mount -o rw,remount / || error ${err_terrible_failure} "failed to mount / as Read-Write"
    cp $1 ${cur_img_path} || error ${err_exchange} "exchange failed"
    # TODO
    local md5=`md5sum ${cur_img_path} | awk '{print $1}'`
    echo "${md5}" > ${cur_img_md5_file}
    mount -o ro,remount /
}

is_booting_from_usb() {
    [ -n "$(udevadm info $(rootdev -d) | grep ID_BUS |grep usb)" ]
}

do_replace(){
    # if no origin img exist, or current origin img is replaced
    # by a system update. in this case we should make a backup.
    if ! use_overlayfs; then
      if [[ ! -f ${new_system_img} ]]; then
          error ${err_terrible_failure} "file not exist: ${new_system_img}"
      fi

      need_backup && backup

      exchange_with_cur ${new_system_img}
    fi
# Refactoring Open GApps ++
    replace_properties fydeos google
# Refactoring Open GApps --
    mark_as_installed
}

do_clear(){
    clear_workdir
    rm -rf ${zip_dir}
    rm -f ${new_system_img}
}

do_restore(){
    if use_overlayfs; then
      rm -rf $overlayfs_top/*
      rm -rf $overlayfs_work/*
    elif [[ -d $overlayfs_top ]]; then
      rm -rf $overlayfs_top $overlayfs_work $overlayfs_mnt
    else
      if [[ ! -f ${origin_img_file} ]]; then
          error ${err_terrible_failure} "file not exist: ${origin_img_file}"
      fi
      exchange_with_cur ${origin_img_file}
    fi
# Refactoring Open GApps ++
    replace_properties google fydeos
# Refactoring Open GApps --
    mark_as_uninstalled
}

do_status(){
    echo '{'
    if check_if_installed; then
        echo -n '"installed": true'
    else
        echo -n '"installed": false'
    fi
    echo ','
    if ! use_overlayfs; then
      if ls ${origin_img_file} 1>/dev/null 2>&1; then
          echo -n '"has_backup": true'
      else
          echo -n '"has_backup": false'
      fi
    else
      echo -n '"has_backup": true'
    fi
    echo ','
    if is_booting_from_usb; then
        echo -n '"is_booting_from_usb": true'
    else
        echo -n '"is_booting_from_usb": false'
    fi
    echo ','
    if use_overlayfs; then
      echo -n '"use_overlayfs": true'
    else
      echo -n '"use_overlayfs": false'
    fi
    echo ','
    if is_arcvm; then
      echo -n '"arc_mode": "arcvm"'
    else
      echo -n '"arc_mode": "arcpp"'
    fi
    echo ''
    echo '}'
}

check_component_name_valied(){
    for name in ${supported_components[*]}
    do
        if [[ $1 = ${name} ]]; then
            return 0
        fi
    done
    return 1
}

if [ `id -u` -ne 0 ];then
	echo "should be run as root"
    exit 1
fi

component_name=$1
if ! check_component_name_valied ${component_name}; then
    usage
    echo
    error 1 "component_name \"${component_name}\" not valied"
fi

cmd=$2
if [[ $cmd = "" ]]; then
    usage
    echo
    error 1 "<command> needed"
fi

# init
mkdir -p ${data_dir}
mount -o exec,remount "/home/chronos/"

# setup log record
mkfifo ${install_log_fifo_file}
cat ${install_log_fifo_file} | tee -a ${install_log_file} &
exec 1>${install_log_fifo_file}
exec 2>&1
rm -f ${install_log_fifo_file}

# log start
echo "" >>${install_log_file}
echo "[`date`] args: $@" >>${install_log_file}

shift
shift

case $cmd in
# Refactoring Open GApps ++
    test-network)
        do_test_network $@
        ;;
# Refactoring Open GApps --
    prepare)
        do_prepare
        ;;
    download)
        do_download $@
        ;;
    flash)
        do_flash
        ;;
    replace)
        do_replace
        ;;
    clear)
        do_clear
        ;;
    restore)
        do_restore
        ;;
    status)
        do_status
        ;;
    *)
        echo "command not found: ${cmd}"
        echo
        usage
        ;;
esac

exit 0
