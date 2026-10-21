ARG BASE=scratch
FROM ${BASE}
USER 0
RUN microdnf update -y libarchive p11-kit p11-kit-trust perl-DBI coreutils-single libevent \
    glibc glibc-common glibc-minimal-langpack perl-URI \
 && microdnf clean all
USER mysql
