#!/usr/bin/env bash

set -o errexit
set -o errtrace
set -o pipefail
if [[ ${DEBUG:-0} -eq 1 ]]; then
	set -o xtrace
fi

function zfs:list_snapshots() {
	local snap_name="${1}"
	local base_dataset="${2}"

	zfs list -r -t snapshot "${base_dataset}" -o name -H | grep "${snap_name}"
}

function prep_env() {
	local database_dir="${1}"
	local tmp_dir="${2}"

	if [[ ! -d "${database_dir}" ]]; then
		echo "Database directory ${database_dir} does not exist. Creating..."
		mkdir -p "${database_dir}"
		chmod 2750 "${database_dir}"
	fi

	if [[ -d "${tmp_dir}" ]]; then
		echo "Duplicati tmp directory ${tmp_dir} already exists. Cleaning up..."
		rm -rf "${tmp_dir}"
	fi
	echo "Creating Duplicati tmp directory ${tmp_dir}"
	mkdir -p "${tmp_dir}"
}

function zfs:create_snapshots() {
	local base_dataset="${1}"
	local snapshot_name="${2}"
	local backup_basedir="${3}"
	local snapshots
	local snapshot
	local dataset

	zfs snapshot -r "${base_dataset}@${snapshot_name}"
	snapshots=( $( zfs:list_snapshots "${snapshot_name}" "${base_dataset}" ) )
	for snapshot in "${snapshots[@]}"; do
		dataset=$( echo "${snapshot}" | sed 's/\(.*\)@'${snapshot_name}'$/\1/' )
		mkdir -p "${backup_basedir}/${dataset}"
		echo "Mounting ${snapshot} to ${backup_basedir}/${dataset}"
		mount -t zfs "${snapshot}" "${backup_basedir}/${dataset}"
	done
}

function run_backup() {
	local backup_src="${1}"
	local config_dir="${2}"
	local tmp_dir="${3}"
	local backup_dest="${4}"
	local passphrase="${5}"

	docker run --rm \
		-v "${backup_src}":/backup \
		-v "${config_dir}":/data \
		-v "${tmp_dir}":/tmp \
		duplicati/duplicati \
		duplicati-cli backup \
			"${backup_dest}" /backup \
				--dbpath=/data/backup.sqlite \
				--encryption-module=aes \
				--compression-module=zip \
				--dblock-size=1GB \
				--passphrase="${passphrase}" \
				--retention-policy="1W:1D,4W:1W,12M:1M" \
				--blocksize=512KB \
				--throttle-upload=6656KB \
				--auto-vacuum=true \
				--auto-cleanup=true \
				--full-result=true \
				--disable-module=console-password-input
}

function cleanup() {
	local base_dataset="${1}"
	local snapshot_name="${2}"
	local backup_basedir="${3}"

	umount -R "${backup_basedir}/${base_dataset}" || true
	zfs destroy -pr "${base_dataset}@${snapshot_name}" || true
	rm -rf "${backup_basedir}" || true
}

################################################################################
# Attempt to find and load config variables                                    #
################################################################################

BACKUP_NAME="${1:-$BACKUP_NAME}"

if [[ -z "${BACKUP_NAME}" ]] && [[ -z "${ENV_FILE}" ]]; then
	echo "No backup name or env file specified. Exiting..."
	exit 1
fi

if [[ -n "${BACKUP_NAME}" ]] && [[ -z "${ENV_FILE}" ]]; then
	config_dir="${CONFIG_DIR:-/etc/duplicati-zfs-backup}"
	ENV_FILE="${config_dir}/${BACKUP_NAME}"
fi

if [[ -f "${ENV_FILE}" ]]; then
	echo "Loading configs from env file ${ENV_FILE}"
	source "${ENV_FILE}"
else
	echo "No environment file found. Using existing environment variables."
fi

###############################################################################
# Validate required variables are set                                         #
###############################################################################

if [[ -n "${BACKUP_NAME}" ]]; then
	echo "Using backup name ${BACKUP_NAME}"
	backup_name="${BACKUP_NAME}"
else
	echo "No backup name specified as BACKUP_NAME or as an arg. Exiting..."
	exit 1
fi

if [[ -n "${BASE_DATASET}" ]]; then
	base_dataset="${BASE_DATASET}"
else
	echo "No base dataset specified as BASE_DATASET. Exiting..."
	exit 1
fi

if [[ -n "${BACKUP_DEST}" ]]; then
	backup_dest="${BACKUP_DEST}"
else
	echo "No backup destination URI specified as BACKUP_DEST. Exiting..."
	exit 1
fi

if [[ -n "${PASSPHRASE}" ]]; then
	passphrase="${PASSPHRASE}"
else
	echo "No encryption passphrase specified as PASSPHRASE. Exiting..."
	exit 1
fi

###############################################################################
# Setup optional variables and variables used internally                      #
###############################################################################

duplicati_base="${DUPLICATI_BASEDIR:-/opt/duplicati}"
duplicati_data="${DUPLICATI_DATADIR:-$duplicati_base/$backup_name}"
duplicati_tmp="${TMP_DIR:-/var/tmp/duplicati/$backup_name}"

snapshot_name="bkup_$( date +'%F_%T' )"
backup_src_base="$( mktemp -d )"

trap 'cleanup ${base_dataset} ${snapshot_name} ${backup_src_base}' ERR

###############################################################################
# Let's go! 																																  #
###############################################################################

echo "Preparing for backup..."
prep_env "${duplicati_data}" "${duplicati_tmp}"

echo "Creating snapshots ${snapshot_name} of datasets under ${base_dataset}"
zfs:create_snapshots "${base_dataset}" "${snapshot_name}" "${backup_src_base}"

echo "Beginning duplicati backup ${backup_name}"
run_backup \
	"${backup_src_base}" \
	"${duplicati_data}" \
	"${duplicati_tmp}" \
	"${backup_dest}" \
	"${passphrase}"

echo "Backup complete"

if [[ ${DEBUG} -eq 1 ]]; then
	echo "Done. Leaving snapshots at ${backup_basedir}."
else
	echo "Unmounting and destroying snapshots"
	cleanup "${base_dataset}" "${snapshot_name}" "${backup_src_base}"
	echo "All done"
fi
