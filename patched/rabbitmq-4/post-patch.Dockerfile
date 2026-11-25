# RabbitMQ builds Erlang against a vendored /opt/openssl, so Copa cannot patch
# the binary. Build the immutable 3.5.10-dev commit carrying the five CVE fixes.
ARG BASE=scratch

FROM ${BASE} AS openssl-builder
USER 0

ARG OPENSSL_COMMIT=5fba8ad64875ff1aff6cd2ad111ca12c33fa6ba2
ARG OPENSSL_SHA256=b6e5d334086e91e35476a95bcd6559a05b3d07de656b4b1cf24694e46beaa3c9

RUN set -eux; \
	apt-get update; \
	apt-get install --yes --no-install-recommends \
		build-essential \
		ca-certificates \
		curl \
		perl \
	; \
	curl -fL -o openssl.tar.gz \
		"https://github.com/openssl/openssl/archive/${OPENSSL_COMMIT}.tar.gz"; \
	echo "$OPENSSL_SHA256 *openssl.tar.gz" | sha256sum --check --strict -; \
	mkdir -p /usr/src/openssl; \
	tar --extract --file openssl.tar.gz --directory /usr/src/openssl --strip-components 1; \
	rm openssl.tar.gz; \
	cd /usr/src/openssl; \
	case "$(dpkg --print-architecture)" in \
		amd64) target=linux-x86_64 ;; \
		arm64) target=linux-aarch64 ;; \
		*) exit 1 ;; \
	esac; \
	./Configure \
		"$target" \
		enable-fips \
		--prefix=/opt/openssl \
		--openssldir=/opt/openssl/etc/ssl \
		--libdir=/opt/openssl/lib \
		-Wl,-rpath=/opt/openssl/lib \
	; \
	make -j "$(getconf _NPROCESSORS_ONLN)"; \
	make install_sw install_ssldirs install_fips; \
	rm -rf /opt/openssl/etc/ssl/certs /opt/openssl/etc/ssl/private; \
	ln -s /etc/ssl/certs /etc/ssl/private /opt/openssl/etc/ssl

FROM ${BASE}
COPY --from=openssl-builder /opt/openssl /opt/openssl
# Copa follows the lagging Trivy report, so upgrade ca-certificates explicitly to
# drop the compromised eMudhra roots (emSign ECC Root CA - G3, AAA Certificate Services).
RUN apt-get update \
 && apt-get install --only-upgrade --no-install-recommends -y ca-certificates \
 && dpkg --compare-versions "$(dpkg-query -W -f='${Version}' ca-certificates)" ge 20260816ubuntu0.24.04.1 \
 && rm -rf /var/lib/apt/lists/*
RUN openssl version \
 && erl -noshell -eval '[{<<"OpenSSL">>, _, Version}] = crypto:info_lib(), io:format("~s", [Version]).' -s init stop
