# Runtime image of drain-guard (PLAN.md phase 7). The binary is compiled on the build host
# (`make images`), so no base image is pulled. FROM scratch: no shell, no package manager.
FROM scratch
COPY drain-guard /drain-guard
USER 65532:65532
ENTRYPOINT ["/drain-guard"]
