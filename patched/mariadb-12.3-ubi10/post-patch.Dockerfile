ARG BASE=scratch
FROM ${BASE}
USER 0
RUN microdnf update -y p11-kit p11-kit-trust perl-DBI \
 && microdnf clean all
USER mysql
