FROM flyway/flyway:10-alpine
USER root
RUN mkdir -p /flyway/sql
COPY ./scripts/ /tmp/scripts/

# Rename dev-friendly `master_X.Y.Z.sql` / `client_X.Y.Z.sql` into
# Flyway-compliant names:
#   master_2026.1.1.sql → V2026.1.1.1__master_2026.1.1.sql
#   client_2026.1.1.sql → V2026.1.1.2__client_2026.1.1.sql
#
# The trailing .1 / .2 on the physical version (before `__`) gives each
# team its own unique version so both can share one history table;
# Flyway's natural version sort guarantees master (.1) runs before
# client (.2) within each logical release.
#
# The `master_X.Y.Z` / `client_X.Y.Z` text after `__` becomes the
# Flyway `description` column (underscores render as spaces) — so the
# history table shows "master 2026.1.1", "client 2026.1.1" etc, making
# the logical release obvious at a glance.
#
# Everything lands in a single /flyway/sql directory.
RUN set -e; \
    for file in /tmp/scripts/master/*.sql; do \
      [ -e "$file" ] || continue; \
      fname=$(basename -- "$file"); \
      version=$(echo "$fname" | sed 's/^master_//;s/\.sql$//'); \
      mv "$file" "/flyway/sql/V${version}.1__master_${version}.sql"; \
    done; \
    for file in /tmp/scripts/client/*.sql; do \
      [ -e "$file" ] || continue; \
      fname=$(basename -- "$file"); \
      version=$(echo "$fname" | sed 's/^client_//;s/\.sql$//'); \
      mv "$file" "/flyway/sql/V${version}.2__client_${version}.sql"; \
    done

# Base image's ENTRYPOINT is already `flyway`. CMD is the whole job.
CMD ["info", "migrate"]
