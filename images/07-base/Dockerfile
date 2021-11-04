ARG REPO
ARG TAG
FROM alpine:3.12 as clevis-build
ARG ARCH
RUN apk --no-cache add \
        alpine-sdk \
        automake \
        autoconf-archive \
        cmake \
        curl \
        meson \
        ninja \
        wget \
        jansson-dev \
        cryptsetup \
        cryptsetup-dev \
        cryptsetup-libs \
        jq \
        autoconf \
        libressl-dev \
        libtool \
        http-parser-dev \
        zlib-dev \
        pkgconfig \
        libgcrypt-dev \
        json-c \
        json-c-dev \
        curl-dev \
        doxygen \
        linux-headers \
        udisks2-dev \
        libpwquality-dev

# https://github.com/tpm2-software/tpm2-tss
RUN wget https://github.com/tpm2-software/tpm2-tss/archive/refs/tags/2.4.6.tar.gz \
    && tar -xf 2.4.6.tar.gz \
    && cd tpm2-tss-2.4.6 \
    && ./bootstrap \
    && ./configure && make -j4 && make install

# https://github.com/tpm2-software/tpm2-tools
RUN wget https://github.com/tpm2-software/tpm2-tools/archive/refs/tags/5.2.tar.gz \
    && tar -xf 5.2.tar.gz \
    && cd tpm2-tools-5.2 \
    && ./bootstrap \
    && ./configure && make -j4 && make install

# https://github.com/latchset/luksmeta
RUN wget https://github.com/latchset/luksmeta/archive/refs/tags/v9.tar.gz \
    && tar -xf v9.tar.gz \
    && cd luksmeta-9 \
    && autoreconf -if && ./configure && make -j4 && make install

# https://github.com/latchset/jose
RUN wget https://github.com/latchset/jose/archive/refs/tags/v11.tar.gz \
    && tar -xf v11.tar.gz \
    && cd jose-11 \
    && meson build  \
    && ninja -C build install

# https://github.com/latchset/tang
RUN wget https://github.com/latchset/tang/archive/refs/tags/v10.tar.gz \
    && tar -xf v10.tar.gz \
    && cd tang-10 \
    && meson build \
    && ninja -C build install

# https://github.com/latchset/clevis
RUN wget https://github.com/latchset/clevis/archive/refs/tags/v18.tar.gz \
    && tar -xf v18.tar.gz \
    && cd clevis-18 \
    && meson build  \
    && sed -i "s|subdir('sss')||g" /clevis-18/src/pins/meson.build \
    && ninja -C build install

# # This adds roughly 1.5M
FROM ${REPO}/k3os-base:${TAG} AS base
RUN apk --no-cache add jansson libpwquality

COPY --from=clevis-build /usr/bin/tang* /usr/bin/
COPY --from=clevis-build /usr/bin/jose* /usr/bin/
COPY --from=clevis-build /usr/local/bin/ /usr/bin/
COPY --from=clevis-build /usr/lib/libjose.so* /usr/lib/
COPY --from=clevis-build /usr/local/lib/ /usr/lib/
COPY --from=clevis-build /usr/libexec/tangd* /usr/libexec/