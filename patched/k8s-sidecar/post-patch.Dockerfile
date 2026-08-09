# Rebuild the interpreter to remediate fixable CVEs in the vendored Python
# 3.15.0b2 (CVE-2026-0864, CVE-2026-9669, CVE-2026-11940, CVE-2026-11972,
# CVE-2026-12003; fixed upstream in 3.15.0b3/b4). Alpine has no apk package
# for this from-source interpreter, so Copa cannot patch it; this mirrors the
# official docker-library/python 3.15-rc/alpine3.22 build recipe with only
# PYTHON_VERSION/PYTHON_SHA256 bumped, built on the same Alpine base as the
# pinned upstream image to keep the musl ABI identical.
ARG BASE=scratch

FROM alpine:3.22 AS python-build

ENV PYTHON_VERSION=3.15.0b4
ENV PYTHON_SHA256=93efb9c88d7b6633368e7f7b8f8db6e98988f7f761c09b77849447262841ce3a

RUN set -eux; \
	apk add --no-cache --virtual .build-deps \
		bluez-dev \
		bzip2-dev \
		dpkg-dev dpkg \
		findutils \
		gcc \
		gdbm-dev \
		gnupg \
		libc-dev \
		libffi-dev \
		libnsl-dev \
		libtirpc-dev \
		linux-headers \
		make \
		ncurses-dev \
		openssl-dev \
		pax-utils \
		readline-dev \
		sqlite-dev \
		tar \
		tcl-dev \
		tk \
		tk-dev \
		util-linux-dev \
		xz \
		xz-dev \
		zlib-dev \
		zstd-dev \
	; \
	\
	wget -O python.tar.xz "https://www.python.org/ftp/python/${PYTHON_VERSION%%[a-z]*}/Python-$PYTHON_VERSION.tar.xz"; \
	echo "$PYTHON_SHA256 *python.tar.xz" | sha256sum -c -; \
	mkdir -p /usr/src/python; \
	tar --extract --directory /usr/src/python --strip-components=1 --file python.tar.xz; \
	rm python.tar.xz; \
	\
	cd /usr/src/python; \
	gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)"; \
	./configure \
		--build="$gnuArch" \
		--enable-loadable-sqlite-extensions \
		--enable-option-checking=fatal \
		--enable-shared \
		$(test "${gnuArch%%-*}" != 'riscv64' && echo '--with-lto') \
		--with-ensurepip \
	; \
	nproc="$(nproc)"; \
	EXTRA_CFLAGS="-DTHREAD_STACK_SIZE=0x100000"; \
	LDFLAGS="${LDFLAGS:-} -Wl,--strip-all"; \
	arch="$(apk --print-arch)"; \
	case "$arch" in \
		x86_64|aarch64) \
			EXTRA_CFLAGS="${EXTRA_CFLAGS:-} -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer"; \
			;; \
		x86) \
			;; \
		*) \
			EXTRA_CFLAGS="${EXTRA_CFLAGS:-} -fno-omit-frame-pointer"; \
			;; \
	esac; \
	make -j "$nproc" \
		"EXTRA_CFLAGS=${EXTRA_CFLAGS:-}" \
		"LDFLAGS=${LDFLAGS:-}" \
	; \
	rm python; \
	make -j "$nproc" \
		"EXTRA_CFLAGS=${EXTRA_CFLAGS:-}" \
		"LDFLAGS=${LDFLAGS:-} -Wl,-rpath='\$\$ORIGIN/../lib'" \
		python \
	; \
	make install; \
	\
	cd /; \
	rm -rf /usr/src/python; \
	\
	find /usr/local -depth \
		\( \
			\( -type d -a \( -name test -o -name tests -o -name idle_test \) \) \
			-o \( -type f -a \( -name '*.pyc' -o -name '*.pyo' -o -name 'libpython*.a' \) \) \
		\) -exec rm -rf '{}' + \
	; \
	apk del --no-network .build-deps; \
	\
	export PYTHONDONTWRITEBYTECODE=1; \
	/usr/local/bin/python3 --version

FROM ${BASE}
USER 0
COPY --from=python-build /usr/local/bin/ /usr/local/bin/
COPY --from=python-build /usr/local/lib/ /usr/local/lib/
COPY --from=python-build /usr/local/include/ /usr/local/include/
RUN python3 --version | grep -qx 'Python 3.15.0b4'
USER 65534:65534
