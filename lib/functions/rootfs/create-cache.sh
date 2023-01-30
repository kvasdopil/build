#!/usr/bin/env bash

# this gets from cache or produces a new rootfs, and leaves a mounted chroot "$SDCARD" at the end.
function get_or_create_rootfs_cache_chroot_sdcard() {
	# validate "${SDCARD}" is set. it does not exist, yet...
	if [[ -z "${SDCARD}" ]]; then
		exit_with_error "SDCARD is not set at get_or_create_rootfs_cache_chroot_sdcard()"
	fi
	[[ ! -d "${SDCARD:?}" ]] && exit_with_error "create_new_rootfs_cache: ${SDCARD} is not a directory"

	# this was moved from configuration to this stage, that way configuration can be offline
	# if ROOTFSCACHE_VERSION not provided, check which is current version in the cache storage in GitHub.
	#  - ROOTFSCACHE_VERSION is provided by external "build rootfs GHA script" in armbian/scripts
	if [[ -z "${ROOTFSCACHE_VERSION}" ]]; then
		if [[ "${SKIP_ARMBIAN_REPO}" != "yes" ]]; then
			display_alert "ROOTFSCACHE_VERSION not set, getting remotely" "Github API and armbian/mirror " "debug"
			# rpardini: why 2 calls?
			# this uses `jq` hostdep
			ROOTFSCACHE_VERSION=$(curl https://api.github.com/repos/armbian/cache/releases/latest -s --fail | jq .tag_name -r || true)
			# anonymous API access is very limited which is why we need a fallback
			# rpardini: yeah but this is 404'ing
			#ROOTFSCACHE_VERSION=${ROOTFSCACHE_VERSION:-$(curl -L --silent https://cache.armbian.com/rootfs/latest --fail)}
			display_alert "Remotely-obtained ROOTFSCACHE_VERSION" "${ROOTFSCACHE_VERSION}" "debug"
		else
			ROOTFSCACHE_VERSION=668 # The neighbour of the beast.
			display_alert "Armbian mirror skipped, using fictional rootfs cache version" "${ROOTFSCACHE_VERSION}" "debug"
		fi
	else
		display_alert "ROOTFSCACHE_VERSION is set externally" "${ROOTFSCACHE_VERSION}" "warn"
	fi
	
	# Make ROOTFSCACHE_VERSION global at this point, in case it was not.
	declare -g ROOTFSCACHE_VERSION="${ROOTFSCACHE_VERSION}"

	display_alert "ROOTFSCACHE_VERSION found online or preset" "${ROOTFSCACHE_VERSION}" "warn"

	local packages_hash="${AGGREGATED_ROOTFS_HASH}" # Produced by aggregation.py - currently only AGGREGATED_PACKAGES_DEBOOTSTRAP and AGGREGATED_PACKAGES_ROOTFS
	local packages_hash=${packages_hash:0:16}       # it's an md5, which is 32 hex digits; used to be 8

	local cache_type="cli"
	[[ ${BUILD_DESKTOP} == yes ]] && cache_type="xfce-desktop"
	[[ -n ${DESKTOP_ENVIRONMENT} ]] && cache_type="${DESKTOP_ENVIRONMENT}"
	[[ ${BUILD_MINIMAL} == yes ]] && cache_type="minimal"

	# seek last cache, proceed to previous otherwise build it
	local cache_list
	readarray -t cache_list <<< "$(get_rootfs_cache_list "$cache_type" "$packages_hash" | sort -r)"

	display_alert "ROOTFSCACHE_VERSION after getting cache list" "${ROOTFSCACHE_VERSION}" "warn"

	declare possible_cached_version # @TODO: does this kill the above var?
	for possible_cached_version in "${cache_list[@]}"; do
		ROOTFSCACHE_VERSION="${possible_cached_version}" # global var
		local cache_name="${ARCH}-${RELEASE}-${cache_type}-${packages_hash}-${ROOTFSCACHE_VERSION}.tar.zst"
		local cache_fname="${SRC}/cache/rootfs/${cache_name}"

		[[ "$ROOT_FS_CREATE_ONLY" == yes ]] && break

		display_alert "Checking cache" "$cache_name" "info"

		# if aria2 file exists download didn't succeeded
		if [[ ! -f $cache_fname || -f ${cache_fname}.aria2 ]]; then
			if [[ "${SKIP_ARMBIAN_REPO}" != "yes" ]]; then
				display_alert "Downloading from servers" # download_rootfs_cache() requires ROOTFSCACHE_VERSION
				download_and_verify "rootfs" "$cache_name" || continue
			fi
		fi

		if [[ -f $cache_fname && ! -f ${cache_fname}.aria2 ]]; then
			display_alert "Cache found!" "$cache_name" "info"
			break
		fi
	done

	display_alert "ROOTFSCACHE_VERSION after looping" "${ROOTFSCACHE_VERSION}" "warn"

	# if not "only" creating rootfs and cache exists, extract it
	# if aria2 file exists, download didn't succeeded, so skip it
	# @TODO this could be named IGNORE_EXISTING_ROOTFS_CACHE=yes
	if [[ "${ROOT_FS_CREATE_ONLY}" != "yes" && -f "${cache_fname}" && ! -f "${cache_fname}.aria2" ]]; then
		[[ ! -d "${SDCARD:?}" ]] || exit_with_error "get_or_create_rootfs_cache_chroot_sdcard: extract: ${SDCARD} is not a directory"

		local date_diff=$((($(date +%s) - $(stat -c %Y "${cache_fname}")) / 86400))
		display_alert "Extracting $cache_name" "$date_diff days old" "info"
		pv -p -b -r -c -N "$(logging_echo_prefix_for_pv "extract_rootfs") $cache_name" "$cache_fname" | zstdmt -dc | tar xp --xattrs -C "${SDCARD}"/

		# @TODO: this never runs, since 'set -e' ("errexit") is in effect, and https://github.com/koalaman/shellcheck/wiki/SC2181
		# [[ $? -ne 0 ]] && rm $cache_fname && exit_with_error "Cache $cache_fname is corrupted and was deleted. Restart."

		run_host_command_logged rm -v "${SDCARD}"/etc/resolv.conf
		run_host_command_logged echo "nameserver ${NAMESERVER}" ">" "${SDCARD}"/etc/resolv.conf

		create_sources_list "${RELEASE}" "${SDCARD}/"
	else
		display_alert "Creating rootfs" "cache miss" "info"
		create_new_rootfs_cache
	fi

	# @TODO: remove after killing usages
	#  used for internal purposes. Faster rootfs cache rebuilding
	if [[ "${ROOT_FS_CREATE_ONLY}" == "yes" ]]; then
		display_alert "Using, does nothing" "ROOT_FS_CREATE_ONLY=yes, late in get_or_create_rootfs_cache_chroot_sdcard" "warning"
		# this used to try to disable traps, umount and exit. no longer. let the function finish
	fi

	return 0
}

function create_new_rootfs_cache() {
	[[ ! -d "${SDCARD:?}" ]] && exit_with_error "create_new_rootfs_cache: ${SDCARD} is not a directory"

	# This var ROOT_FS_CREATE_VERSION is only used here, afterwards it's all cache_name and cache_fname
	local ROOT_FS_CREATE_VERSION=${ROOT_FS_CREATE_VERSION:-$(date --utc +"%Y%m%d")}
	local cache_name=${ARCH}-${RELEASE}-${cache_type}-${packages_hash}-${ROOT_FS_CREATE_VERSION}.tar.zst
	local cache_fname=${SRC}/cache/rootfs/${cache_name}

	display_alert "Creating new rootfs cache for" "${RELEASE} ${ROOT_FS_CREATE_VERSION}" "info"

	create_new_rootfs_cache_via_debootstrap # in rootfs-create.sh
	create_new_rootfs_cache_tarball         # in rootfs-create.sh

	# needed for backend to keep current only @TODO: still needed?
	echo "$cache_fname" > "${cache_fname}.current"

	return 0 # protect against possible future short-circuiting above this
}

# get_rootfs_cache_list <cache_type> <packages_hash>
#
# return a list of versions of all avaiable cache from remote and local.
function get_rootfs_cache_list() {
	local cache_type=$1
	local packages_hash=$2

	# this uses `jq` hostdep
	{
		# Don't even try remote if we're told to skip.
		if [[ "${SKIP_ARMBIAN_REPO}" != "yes" ]]; then
			curl --silent --fail -L "https://api.github.com/repos/armbian/cache/releases?per_page=3" | jq -r '.[].tag_name' ||
				curl --silent --fail -L https://cache.armbian.com/rootfs/list
		fi

		find "${SRC}"/cache/rootfs/ -mtime -7 -name "${ARCH}-${RELEASE}-${cache_type}-${packages_hash}-*.tar.zst" |
			sed -e 's#^.*/##' |
			sed -e 's#\..*$##' |
			awk -F'-' '{print $5}'
	} | sort | uniq
}
