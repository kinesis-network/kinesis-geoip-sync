#!/bin/sh
# Copies MaxMind GeoLite2 databases into an R2 bucket, so managers and developers
# read them from there instead of from git.
#
# For each edition, the bucket holds:
#   <edition>/<edition>.mmdb            the latest database
#   <edition>/<edition>.tar.gz.sha256   MaxMind's checksum file of the release it came
#                                       from (the file name in it carries the build date)
# A pass downloads an edition only when MaxMind's checksum differs from the stored one.
# The .mmdb is overwritten, so the bucket keeps no old versions (GeoLite EULA §6.3).
#
# Usage: geoip-sync           sync now, then every 12 hours
#                             (1 hour after a pass in which an edition failed)
#        geoip-sync --once    sync once; exit non-zero if an edition failed
set -u

EDITIONS="GeoLite2-City GeoLite2-ASN"
INTERVAL_SECONDS=$((12 * 3600))
RETRY_SECONDS=3600
DOWNLOAD_URL="https://download.maxmind.com/geoip/databases"

: "${MAXMIND_ACCOUNT_ID:?MAXMIND_ACCOUNT_ID is required}"
: "${MAXMIND_LICENSE_KEY:?MAXMIND_LICENSE_KEY is required}"
: "${R2_ACCOUNT_ID:?R2_ACCOUNT_ID is required}"
: "${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID is required}"
: "${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY is required}"
: "${R2_BUCKET:?R2_BUCKET is required}"

# rclone remote "r2", configured from the environment only.
export RCLONE_CONFIG=/dev/null
export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
export RCLONE_CONFIG_R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
# A key scoped to one bucket may not create buckets.
export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true

log() {
	echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"
}

# Downloads "$DOWNLOAD_URL/<edition>/download?suffix=<suffix>" to a file. The
# credentials go to curl through stdin, so they never show on a command line. curl
# does not send them on to the presigned URL MaxMind redirects to.
download() {
	printf 'user = "%s:%s"\n' "$MAXMIND_ACCOUNT_ID" "$MAXMIND_LICENSE_KEY" |
		curl --config - --fail --silent --show-error --location \
			--retry 3 --max-time 600 \
			--output "$3" "$DOWNLOAD_URL/$1/download?suffix=$2"
}

# Syncs one edition. Returns non-zero on any failure; the bucket then keeps what it had.
sync_edition() {
	edition=$1
	dir="$work/$edition"
	mkdir -p "$dir/x" || return 1

	download "$edition" tar.gz.sha256 "$dir/release.sha256" || return 1
	# The checksum file reads "<sha256>  <edition>_<YYYYMMDD>.tar.gz".
	read -r want release <"$dir/release.sha256" || true
	if [ -z "${want:-}" ] || [ -z "${release:-}" ]; then
		log "$edition: unexpected checksum file from MaxMind"
		return 1
	fi

	# A failed read (no object yet, or R2 trouble) counts as "not stored": the upload
	# below then fails loudly if R2 is the problem.
	have=$(rclone cat "r2:$R2_BUCKET/$edition/$edition.tar.gz.sha256" 2>/dev/null | cut -d ' ' -f 1)
	if [ "$want" = "$have" ]; then
		log "$edition: up to date ($release)"
		return 0
	fi

	download "$edition" tar.gz "$dir/$release" || return 1
	if ! (cd "$dir" && echo "$want  $release" | sha256sum -c - >/dev/null); then
		log "$edition: checksum mismatch for $release"
		return 1
	fi
	tar -xzf "$dir/$release" -C "$dir/x" || return 1
	mmdb=$(find "$dir/x" -type f -name "$edition.mmdb" | head -n 1)
	if [ -z "$mmdb" ]; then
		log "$edition: no $edition.mmdb in $release"
		return 1
	fi

	# Database first, checksum file last: a stored checksum always matches the stored
	# database, and an interrupted pass is retried on the next one.
	rclone copyto "$mmdb" "r2:$R2_BUCKET/$edition/$edition.mmdb" || return 1
	rclone copyto "$dir/release.sha256" "r2:$R2_BUCKET/$edition/$edition.tar.gz.sha256" || return 1
	log "$edition: stored $release ($(wc -c <"$mmdb") bytes)"
}

# One pass over every edition. Returns non-zero if any edition failed.
sync_all() {
	work=$(mktemp -d) || return 1
	failed=0
	for edition in $EDITIONS; do
		if ! sync_edition "$edition"; then
			log "$edition: sync failed"
			failed=1
		fi
	done
	rm -rf "$work"
	work=""
	return "$failed"
}

# As PID 1 in a container, sh ignores SIGTERM unless it is trapped. sleep runs in the
# background so the trap fires at once instead of after the sleep.
work=""
sleeper=""
trap '[ -n "$sleeper" ] && kill "$sleeper" 2>/dev/null; rm -rf "$work"; exit 143' TERM INT

case "${1:-}" in
--once)
	sync_all
	;;
"")
	while :; do
		if sync_all; then
			sleep "$INTERVAL_SECONDS" &
		else
			sleep "$RETRY_SECONDS" &
		fi
		sleeper=$!
		wait "$sleeper"
		sleeper=""
	done
	;;
*)
	echo "usage: geoip-sync [--once]" >&2
	exit 2
	;;
esac
