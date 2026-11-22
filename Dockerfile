FROM alpine:3.24
RUN apk add --no-cache ca-certificates curl rclone tini
COPY --chmod=0755 geoip-sync.sh /usr/local/bin/geoip-sync
USER nobody
# tini -g passes SIGTERM to the whole process group, so a stop ends a running download too.
ENTRYPOINT ["/sbin/tini", "-g", "--", "/usr/local/bin/geoip-sync"]
