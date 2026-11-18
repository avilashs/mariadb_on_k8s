# Runtime image of db-canary (PLAN.md phase 6). `make images` compiles the binary
# statically on the build host and copies it into this context, so the build pulls no
# base image. FROM scratch: the canary needs no shell, no package manager and no system
# CA store. A server's CA comes from the operator's Secret, mounted at run time.
FROM scratch
COPY db-canary /db-canary
USER 65532:65532
ENTRYPOINT ["/db-canary"]
