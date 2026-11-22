FROM alpine:3.24
RUN apk add --no-cache ca-certificates curl rclone
COPY --chmod=0755 geoip-sync.sh /usr/local/bin/geoip-sync
USER nobody
ENTRYPOINT ["/usr/local/bin/geoip-sync"]
