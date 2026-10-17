# RabbitMQ builds Erlang against a vendored /opt/openssl, so Copa cannot patch
# CVE-2026-14456. Rebuild the OpenSSL 3.5 branch at the upstream fix commit.
ARG BASE=scratch

FROM ${BASE} AS openssl-builder
USER 0

ARG OPENSSL_COMMIT=45e844fa2a14ec92d146bd8f5778ac130b6625fb
ARG OPENSSL_SHA256=f54250b21795bb01240f3f9b42c384868d04460e339e39275aaaf93487f2d903

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
RUN openssl version \
 && erl -noshell -eval '[{<<"OpenSSL">>, _, Version}] = crypto:info_lib(), io:format("~s", [Version]).' -s init stop
