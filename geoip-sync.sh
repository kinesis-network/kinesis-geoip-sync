#!/bin/sh
# Copies the latest MaxMind GeoLite2 databases into an R2 bucket, the place managers and
# developers are meant to read them from.
#
# For each edition, the bucket holds:
#   <edition>/<edition>.mmdb            the latest database
#   <edition>/<edition>.tar.gz.sha256   "<sha256>  <edition>_<YYYYMMDD>.tar.gz": the release
#                                       the database came from, and its checksum
# A pass asks MaxMind for the current release name with a HEAD request, which does not
# count against GeoLite's 30 downloads a day, and downloads only a release the bucket
# lacks. A downloaded release stays in $CACHE until it is stored, so a failed upload is
# retried without downloading it again. Each upload overwrites the previous database, so
# no old versions are kept (GeoLite EULA §6.3).
#
# Usage: geoip-sync           sync now, then every 12 hours
#                             (1 hour after a pass in which an edition failed)
#        geoip-sync --once    sync once; exit non-zero if an edition failed
set -u

EDITIONS="GeoLite2-City GeoLite2-ASN"
INTERVAL_SECONDS=$((12 * 3600))
RETRY_SECONDS=3600
DOWNLOAD_URL="https://download.maxmind.com/geoip/databases"
CACHE="${TMPDIR:-/tmp}/geoip-sync"

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

# curl against MaxMind's download URLs, HTTPS only, following the redirect to a presigned
# URL. The credentials go to curl through stdin, so they never show on a command line;
# curl does not send them on to the redirect's host.
maxmind() {
	printf 'user = "%s:%s"\n' "$MAXMIND_ACCOUNT_ID" "$MAXMIND_LICENSE_KEY" |
		curl --config - --fail --silent --show-error --location \
			--proto =https --proto-redir =https --max-time 600 "$@"
}

# Syncs one edition. Returns non-zero on any failure. The bucket then holds the previous
# release, or the new database without a checksum file, which the next pass completes.
sync_edition() {
	edition=$1
	url="$DOWNLOAD_URL/$edition/download?suffix"

	# The file name in Content-Disposition carries the build date.
	release=$(maxmind --head "$url=tar.gz" | tr -d '\r' |
		grep -i '^content-disposition:' | tail -n 1 | sed 's/.*filename=//; s/[";]//g')
	case $release in
	"${edition}"_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].tar.gz) ;;
	*)
		log "$edition: no release name from MaxMind"
		return 1
		;;
	esac

	# Exit status 3 is rclone's "directory not found": nothing stored yet.
	stored=$(rclone lsf "r2:$R2_BUCKET/$edition/")
	status=$?
	if [ "$status" -ne 0 ] && [ "$status" -ne 3 ]; then
		log "$edition: cannot list the bucket"
		return 1
	fi
	if printf '%s\n' "$stored" | grep -qx "$edition.mmdb" &&
		printf '%s\n' "$stored" | grep -qx "$edition.tar.gz.sha256"; then
		have=$(rclone cat "r2:$R2_BUCKET/$edition/$edition.tar.gz.sha256") || return 1
		if [ "${have#*  }" = "$release" ]; then
			log "$edition: up to date ($release)"
			return 0
		fi
	fi

	dir="$CACHE/$edition"
	if [ ! -f "$dir/$release" ]; then
		# Drops an older release left from a pass that failed.
		rm -rf "$dir"
		mkdir -p "$dir" || return 1
		maxmind --output "$dir/release.sha256" "$url=tar.gz.sha256" || return 1
		maxmind --output "$dir/$release.part" "$url=tar.gz" || return 1
		mv "$dir/$release.part" "$dir/$release" || return 1
	fi

	# The checksum file reads "<sha256>  <release>".
	read -r want _ <"$dir/release.sha256" || true
	case ${want:-} in
	*[!0-9a-f]*) want="" ;;
	esac
	if [ "${#want}" -ne 64 ] || ! (cd "$dir" && echo "$want  $release" | sha256sum -c - >/dev/null); then
		log "$edition: $release does not match MaxMind's checksum"
		rm -rf "$dir"
		return 1
	fi
	if ! tar -xzOf "$dir/$release" "${release%.tar.gz}/$edition.mmdb" >"$dir/$edition.mmdb"; then
		log "$edition: no $edition.mmdb in $release"
		rm -rf "$dir"
		return 1
	fi
	printf '%s  %s\n' "$want" "$release" >"$dir/stored.sha256" || return 1

	# Old checksum file first, new one last: a checksum file in the bucket always names the
	# database next to it.
	if printf '%s\n' "$stored" | grep -qx "$edition.tar.gz.sha256"; then
		rclone deletefile "r2:$R2_BUCKET/$edition/$edition.tar.gz.sha256" || return 1
	fi
	rclone copyto "$dir/$edition.mmdb" "r2:$R2_BUCKET/$edition/$edition.mmdb" || return 1
	rclone copyto "$dir/stored.sha256" "r2:$R2_BUCKET/$edition/$edition.tar.gz.sha256" || return 1
	log "$edition: stored $release ($(wc -c <"$dir/$edition.mmdb") bytes)"
	rm -rf "$dir"
}

# One pass over every edition. Returns non-zero if any edition failed.
sync_all() {
	failed=0
	for edition in $EDITIONS; do
		if ! sync_edition "$edition"; then
			log "$edition: sync failed"
			failed=1
		fi
	done
	return "$failed"
}

case "${1:-}" in
--once)
	sync_all
	;;
"")
	while :; do
		if sync_all; then
			sleep "$INTERVAL_SECONDS"
		else
			sleep "$RETRY_SECONDS"
		fi
	done
	;;
*)
	echo "usage: geoip-sync [--once]" >&2
	exit 2
	;;
esac
