# The multi-LLM query optimizer (https://github.com/avilashs/query_optimizer), built offline from wheels that
# hack/build-query-optimizer.sh downloads on the host, so the build needs no network and every dependency is
# the file that was fetched, not whatever the index serves at build time. Only the drivers this platform
# uses are installed: PostgreSQL (psycopg) and MySQL/MariaDB (PyMySQL).
FROM python:3.12-slim

RUN useradd --create-home --uid 10001 qopt \
 && mkdir -p /config /data \
 && chown qopt:qopt /data
COPY wheels /wheels
RUN pip install --no-cache-dir --no-index --find-links=/wheels 'query-optimizer[postgres,mysql]' \
 && rm -rf /wheels

USER qopt
WORKDIR /data
ENV PYTHONUNBUFFERED=1
# /config/config.yaml : configuration (mounted read-only; secrets come from environment variables)
# /data               : state.db (audit log and de-duplication) and reports/
VOLUME ["/data"]
ENTRYPOINT ["qopt"]
CMD ["run", "-c", "/config/config.yaml"]
