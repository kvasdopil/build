function cli_rootfs_pre_run() {
	declare -g ARMBIAN_COMMAND_REQUIRE_BASIC_DEPS="yes" # Require prepare_host_basic to run before the command.

	# "gimme root on a Linux machine"
	cli_standard_relaunch_docker_or_sudo
}

function cli_rootfs_run() {
	declare -a vars_cant_be_set=("BOARD" "LINUXFAMILY" "BOARDFAMILY")
	# loop through all vars and check if they are set and bomb out
	for var in "${vars_cant_be_set[@]}"; do
		if [[ -n ${!var} ]]; then
			exit_with_error "Param '${var}' is set ('${!var}') but can't be set for rootfs CLI; rootfs's are shared across boards and families."
		fi
	done

	declare -a vars_need_to_be_set=("RELEASE" "ARCH") # Maybe the rootfs version?
	# loop through all vars and check if they are not set and bomb out if so
	for var in "${vars_need_to_be_set[@]}"; do
		if [[ -z ${!var} ]]; then
			exit_with_error "Param '${var}' is not set but needs to be set for rootfs CLI."
		fi
	done

	declare -r __wanted_rootfs_arch="${ARCH}"
	declare -g -r RELEASE="${RELEASE}" # make readonly for finding who tries to change it

	# configuration etc - it initializes the extension manager; handles its own logging sections.
	prep_conf_main_only_rootfs < /dev/null # no stdin for this, so it bombs if tries to be interactive.

	declare -g -r ARCH="${ARCH}" # make readonly for finding who tries to change it
	if [[ "${ARCH}" != "${__wanted_rootfs_arch}" ]]; then
		exit_with_error "Param 'ARCH' is set to '${ARCH}' after config, but different from wanted '${__wanted_rootfs_arch}'"
	fi

	# default build, but only invoke specific rootfs functions needed. It has its own logging sections.
	do_with_default_build cli_rootfs_only_in_default_build < /dev/null # no stdin for this, so it bombs if tries to be interactive.

	reset_uid_owner "${BUILT_ROOTFS_CACHE_FILE}"

	display_alert "Rootfs build complete" "${BUILT_ROOTFS_CACHE_NAME}" "info"
	display_alert "Rootfs build complete, file: " "${BUILT_ROOTFS_CACHE_FILE}" "info"
}

# This is run inside do_with_default_build(), above.
function cli_rootfs_only_in_default_build() {
	LOG_SECTION="prepare_rootfs_build_params_and_trap" do_with_logging prepare_rootfs_build_params_and_trap

	LOG_SECTION="calculate_rootfs_cache_id" do_with_logging calculate_rootfs_cache_id

	display_alert "Going to build rootfs" "packages_hash: '${packages_hash:-}' cache_type: '${cache_type:-}'" "info"

	# "rootfs" CLI skips over a lot goes straight to create the rootfs. It doesn't check cache etc.
	LOG_SECTION="create_new_rootfs_cache" do_with_logging create_new_rootfs_cache
}
