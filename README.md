# kinesis-geoip-sync

Keeps the latest MaxMind GeoLite2 databases in a private R2 bucket, the place managers and developers are meant to
read the `.mmdb` files from, so they can stay out of git and stay current.

Every 12 hours (1 hour after a pass that failed), for `GeoLite2-City` and `GeoLite2-ASN`:

1. Ask MaxMind for the current release name (a HEAD request, which doesn't count as a download) and compare it with
   the one in the bucket.
2. If the bucket lacks it, download the release and its `.sha256`, check them, and upload the `.mmdb`, then the
   checksum file. A downloaded release is kept until it is stored, so a failed upload doesn't download it again.

## Bucket layout

```
<edition>/<edition>.mmdb            latest database, e.g. GeoLite2-City/GeoLite2-City.mmdb
<edition>/<edition>.tar.gz.sha256   checksum file of its release: "<sha256>  GeoLite2-City_20261120.tar.gz"
```

Each upload overwrites the previous one, so the bucket keeps no old versions. The GeoLite EULA (§6.3) requires
licensees to stop using and delete old versions within 30 days of a new release, and it does not allow sharing the
data with third parties: keep the bucket private, and refresh local copies at least that often.

## Run

```
docker run -d --name geoip-sync \
  -e MAXMIND_ACCOUNT_ID=... -e MAXMIND_LICENSE_KEY=... \
  -e R2_ACCOUNT_ID=... -e R2_ACCESS_KEY_ID=... -e R2_SECRET_ACCESS_KEY=... \
  -e R2_BUCKET=kinesis-geoip \
  kinesisorg/kinesis-geoip-sync:latest
```

All are required.

| Variable | Meaning |
|---|---|
| `MAXMIND_ACCOUNT_ID`, `MAXMIND_LICENSE_KEY` | MaxMind account and a license key for this job |
| `R2_ACCOUNT_ID` | Cloudflare account id (the endpoint is `https://<id>.r2.cloudflarestorage.com`) |
| `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` | R2 key with object read and write on the bucket |
| `R2_BUCKET` | bucket name |

`geoip-sync --once` (e.g. `docker run --rm ... kinesisorg/kinesis-geoip-sync:latest --once`) runs one pass and exits
non-zero if an edition failed. GeoLite allows 30 downloads a day per account; a new release costs two (the
`.tar.gz` and its `.sha256`).

## Get the files for local debugging

With an R2 key that can read the bucket:

```
export RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
  RCLONE_CONFIG_R2_ENDPOINT=https://<account-id>.r2.cloudflarestorage.com \
  RCLONE_CONFIG_R2_ACCESS_KEY_ID=... RCLONE_CONFIG_R2_SECRET_ACCESS_KEY=...
rclone copyto r2:kinesis-geoip/GeoLite2-City/GeoLite2-City.mmdb ./GeoLite2-City.mmdb
```

## Release

Push a tag `vX.Y.Z`. The workflow builds `linux/amd64` and `linux/arm64` and pushes
`kinesisorg/kinesis-geoip-sync:X.Y.Z` and `:latest` to Docker Hub. It needs the repository secrets
`DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`.
