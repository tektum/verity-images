ARG BASE=scratch
FROM ${BASE}
USER 0
RUN microdnf update -y libarchive p11-kit p11-kit-trust perl-DBI \
 && microdnf clean all
USER mysql
