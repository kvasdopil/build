#!/usr/bin/env bash
function compile_kernel() {
	local kernel_work_dir="${SRC}/cache/sources/${LINUXSOURCEDIR}"
	display_alert "Kernel build starting" "${LINUXSOURCEDIR}" "info"

	# Prepare the git bare repo for the kernel; shared between all kernel builds
	declare kernel_git_bare_tree

	# @TODO: have a way to actually use this. It's inefficient, but might be the only way for people without ORAS/OCI for some reason.
	# Important: for the bundle version, gotta use "do_with_logging_unless_user_terminal" otherwise floods logs.
	# alternative # LOG_SECTION="kernel_prepare_bare_repo_from_bundle" do_with_logging_unless_user_terminal do_with_hooks \
	# alternative # 	kernel_prepare_bare_repo_from_bundle # this sets kernel_git_bare_tree

	LOG_SECTION="kernel_prepare_bare_repo_from_oras_gitball" do_with_logging do_with_hooks \
		kernel_prepare_bare_repo_from_oras_gitball # this sets kernel_git_bare_tree

	# prepare the working copy; this is the actual kernel source tree for this build
	declare checked_out_revision_ts="" checked_out_revision="undetermined" # set by fetch_from_repo
	LOG_SECTION="kernel_prepare_git" do_with_logging_unless_user_terminal do_with_hooks kernel_prepare_git

	# Capture date variables set by fetch_from_repo; it's the date of the last kernel revision
	declare kernel_git_revision="${checked_out_revision}"
	declare kernel_base_revision_ts="${checked_out_revision_ts}"
	declare kernel_base_revision_date # Used for KBUILD_BUILD_TIMESTAMP in make.
	kernel_base_revision_date="$(LC_ALL=C date -d "@${kernel_base_revision_ts}")"
	display_alert "Using Kernel git revision" "${kernel_git_revision} at '${kernel_base_revision_date}'"

	# Possibly 'make clean'.
	LOG_SECTION="kernel_maybe_clean" do_with_logging do_with_hooks kernel_maybe_clean

	# Patching.
	declare hash pre_patch_version
	kernel_main_patching # has it's own logging sections inside

	# Stop after patching;
	if [[ "${PATCH_ONLY}" == yes ]]; then
		display_alert "PATCH_ONLY is set, stopping." "PATCH_ONLY=yes and patching success" "cachehit"
		return 0
	fi

	# patching worked, it's a good enough indication the git-bundle worked;
	# let's clean up the git-bundle cache, since the git-bare cache is proven working.
	LOG_SECTION="kernel_cleanup_bundle_artifacts" do_with_logging do_with_hooks kernel_cleanup_bundle_artifacts

	# re-read kernel version after patching
	declare version
	version=$(grab_version "$kernel_work_dir")
	display_alert "Compiling $BRANCH kernel" "$version" "info"

	# determine the toolchain
	declare toolchain
	LOG_SECTION="kernel_determine_toolchain" do_with_logging do_with_hooks kernel_determine_toolchain

	kernel_config # has it's own logging sections inside

	# package the kernel-source .deb
	LOG_SECTION="kernel_package_source" do_with_logging do_with_hooks kernel_package_source

	# build via make and package .debs; they're separate sub-steps
	kernel_prepare_build_and_package # has it's own logging sections inside

	display_alert "Done with" "kernel compile" "debug"

	LOG_SECTION="kernel_deploy_pkg" do_with_logging do_with_hooks kernel_deploy_pkg

	return 0
}

function kernel_maybe_clean() {
	if [[ $CLEAN_LEVEL == *make-kernel* ]]; then
		display_alert "Cleaning Kernel tree - CLEAN_LEVEL contains 'make-kernel'" "$LINUXSOURCEDIR" "info"
		(
			cd "${kernel_work_dir}" || exit_with_error "Can't cd to kernel_work_dir: ${kernel_work_dir}"
			run_host_command_logged git clean -xfdq # faster & more efficient than 'make clean'
		)
	else
		display_alert "Not cleaning Kernel tree; use CLEAN_LEVEL=make-kernel if needed" "CLEAN_LEVEL=${CLEAN_LEVEL}" "debug"
	fi
}

function kernel_package_source() {
	[[ "${BUILD_KSRC}" != "yes" ]] && return 0

	display_alert "Creating kernel source package" "${LINUXCONFIG}" "info"

	local ts=${SECONDS}
	local sources_pkg_dir tmp_src_dir tarball_size package_size
	tmp_src_dir=$(mktemp -d) # subject to TMPDIR/WORKDIR, so is protected by single/common error trapmanager to clean-up.

	sources_pkg_dir="${tmp_src_dir}/${CHOSEN_KSRC}_${REVISION}_all"

	mkdir -p "${sources_pkg_dir}"/usr/src/ \
		"${sources_pkg_dir}/usr/share/doc/linux-source-${version}-${LINUXFAMILY}" \
		"${sources_pkg_dir}"/DEBIAN

	run_host_command_logged cp -v "${SRC}/config/kernel/${LINUXCONFIG}.config" "${sources_pkg_dir}/usr/src/${LINUXCONFIG}_${version}_${REVISION}_config"
	run_host_command_logged cp -v COPYING "${sources_pkg_dir}/usr/share/doc/linux-source-${version}-${LINUXFAMILY}/LICENSE"

	display_alert "Compressing sources for the linux-source package" "exporting from git" "info"
	cd "${kernel_work_dir}" || exit_with_error "Can't cd to kernel_work_dir: ${kernel_work_dir}"

	local tar_prefix="${version}/"
	local output_tarball="${sources_pkg_dir}/usr/src/linux-source-${version}-${LINUXFAMILY}.tar.zst"

	# export tar with `git archive`; we point it at HEAD, but could be anything else too
	run_host_command_logged git archive "--prefix=${tar_prefix}" --format=tar HEAD "| zstdmt > '${output_tarball}'"
	tarball_size="$(du -h -s "${output_tarball}" | awk '{print $1}')"

	cat <<- EOF > "${sources_pkg_dir}"/DEBIAN/control
		Package: linux-source-${BRANCH}-${LINUXFAMILY}
		Version: ${version}-${BRANCH}-${LINUXFAMILY}+${REVISION}
		Architecture: all
		Maintainer: ${MAINTAINER} <${MAINTAINERMAIL}>
		Section: kernel
		Priority: optional
		Depends: binutils, coreutils
		Provides: linux-source, linux-source-${version}-${LINUXFAMILY}
		Recommends: gcc, make
		Description: This package provides the source code for the Linux kernel $version
	EOF

	fakeroot_dpkg_deb_build -Znone -z0 "${sources_pkg_dir}" "${sources_pkg_dir}.deb" # do not compress .deb, it already contains a zstd compressed tarball! ignores ${KDEB_COMPRESS} on purpose
	package_size="$(du -h -s "${sources_pkg_dir}.deb" | awk '{print $1}')"
	run_host_command_logged rsync --remove-source-files -r "${sources_pkg_dir}.deb" "${DEB_STORAGE}/"
	display_alert "$(basename "${sources_pkg_dir}.deb" ".deb") packaged" "$((SECONDS - ts)) seconds, ${tarball_size} tarball, ${package_size} .deb" "info"
}

function kernel_prepare_build_and_package() {
	declare -a build_targets
	declare kernel_dest_install_dir
	declare -a install_make_params_quoted
	declare -A kernel_install_dirs

	build_targets=("all")                                              # "All" builds the vmlinux/Image/Image.gz default for the ${ARCH}
	kernel_dest_install_dir=$(mktemp -d "${WORKDIR}/kernel.XXXXXXXXX") # subject to TMPDIR/WORKDIR, so is protected by single/common error trapmanager to clean-up.

	# define dict with vars passed and target directories
	declare -A kernel_install_dirs=(
		["INSTALL_PATH"]="${kernel_dest_install_dir}/image/boot"  # Used by `make install`
		["INSTALL_MOD_PATH"]="${kernel_dest_install_dir}/modules" # Used by `make modules_install`
		#["INSTALL_HDR_PATH"]="${kernel_dest_install_dir}/libc_headers" # Used by `make headers_install` - disabled, only used for libc headers
	)

	build_targets+=(install modules_install) # headers_install disabled, only used for libc headers
	if [[ "${KERNEL_BUILD_DTBS:-yes}" == "yes" ]]; then
		display_alert "Kernel build will produce DTBs!" "DTBs YES" "debug"
		build_targets+=("dtbs_install")
		kernel_install_dirs+=(["INSTALL_DTBS_PATH"]="${kernel_dest_install_dir}/dtbs") # Used by `make dtbs_install`
	fi

	# loop over the keys above, get the value, create param value in array; also mkdir the dir
	local dir_key
	for dir_key in "${!kernel_install_dirs[@]}"; do
		local dir="${kernel_install_dirs["${dir_key}"]}"
		local value="${dir_key}=${dir}"
		mkdir -p "${dir}"
		install_make_params_quoted+=("${value}")
	done

	# Fire off the build & package
	LOG_SECTION="kernel_build" do_with_logging do_with_hooks kernel_build

	LOG_SECTION="kernel_package" do_with_logging do_with_hooks kernel_package
}

function kernel_build() {
	local ts=${SECONDS}
	cd "${kernel_work_dir}" || exit_with_error "Can't cd to kernel_work_dir: ${kernel_work_dir}"

	display_alert "Building kernel" "${LINUXFAMILY} ${LINUXCONFIG} ${build_targets[*]}" "info"
	make_filter="| grep --line-buffered -v -e 'LD' -e 'AR' -e 'INSTALL' -e 'SIGN' -e 'XZ' " \
		do_with_ccache_statistics \
		run_kernel_make_long_running "${install_make_params_quoted[@]@Q}" "${build_targets[@]}"

	display_alert "Kernel built in" "$((SECONDS - ts)) seconds - ${version}-${LINUXFAMILY}" "info"
}

function kernel_package() {
	local ts=${SECONDS}
	cd "${kernel_work_dir}" || exit_with_error "Can't cd to kernel_work_dir: ${kernel_work_dir}"
	display_alert "Packaging kernel" "${LINUXFAMILY} ${LINUXCONFIG}" "info"
	prepare_kernel_packaging_debs "${kernel_work_dir}" "${kernel_dest_install_dir}" "${version}" kernel_install_dirs
	display_alert "Kernel packaged in" "$((SECONDS - ts)) seconds - ${version}-${LINUXFAMILY}" "info"
}

function kernel_deploy_pkg() {
	cd "${kernel_work_dir}/.." || exit_with_error "Can't cd to kernel_work_dir: ${kernel_work_dir}"

	# @TODO: rpardini: this is kept for historical reasons... wth?
	# remove firmware image packages here - easier than patching ~40 packaging scripts at once
	run_host_command_logged rm -fv "linux-firmware-image-*.deb"

	run_host_command_logged rsync -v --remove-source-files -r ./*.deb "${DEB_STORAGE}/"
}
