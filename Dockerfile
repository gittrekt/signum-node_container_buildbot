# Number of layers don't matter in bulder
# Currently only supports amd64,arm64/v8, ppc64le, s390x
ARG NODE_VERSION=16.20.2
ARG ALPINE_VERSION=3.18

FROM node:${NODE_VERSION}-alpine${ALPINE_VERSION} as node
FROM alpine:${ALPINE_VERSION} as builder

# Setup the build environment
RUN  apk update && apk upgrade \
  && apk add --no-cache --update --upgrade --virtual .build-deps-full \
    coreutils \
    bind-tools \
    git \
    unzip \
    wget \
    curl \
    bash \
    musl \
    musl-dev \
    gcompat \
    musl-utils \
    openjdk11-jdk \
  && rm -rf /var/cache/apk/*

COPY --from=node /usr/lib /usr/lib
COPY --from=node /usr/local/lib /usr/local/lib
COPY --from=node /usr/local/include /usr/local/include
COPY --from=node /usr/local/bin /usr/local/bin

RUN node -v \
  && npm -v

COPY signum-node /signum-node
COPY build.gradle /signum-node/build.gradle
WORKDIR /signum-node

# Run gradle tasks
RUN chmod +x /signum-node/gradlew \
  && /signum-node/gradlew clean dist jdeps \ 
    -Pjdeps.recursive=true \
    -Pjdeps.ignore.missing.deps=true \
    -Pjdeps.print.module.deps=true

# Copy the build to /signum
RUN unzip -o build/distributions/signum-node.zip -d /signum \
  && cp update-phoenix.sh /signum/update-phoenix.sh \
  && chmod +x /signum/update-phoenix.sh

WORKDIR /signum

# Get phoenix and classic wallets
RUN bash -c /signum/update-phoenix.sh \
  && (cd /tmp && git clone https://github.com/signum-network/signum-classic-wallet.git \
    && cp -r signum-classic-wallet/src/* /signum/html/ui/classic/ && rm -rf signum-classic-wallet)

# Clean up /signum
RUN rm -rf /signum/signum-node.exe 2> /dev/null || true \
  && rm -rf /signum/signum-node.zip 2> /dev/null || true \
  && rm -rf /signum/*.sh 2> /dev/null || true

# Create a custom JRE
#RUN $JAVA_HOME/bin/jlink \ removed until alpine is fixed
RUN jlink \
  --add-modules $(cat /signum-node/build/reports/jdeps/print-module-deps-main.txt) \
  --strip-debug \
  --no-man-pages \
  --no-header-files \
  --compress=2 \
  --output /jre

RUN mkdir -p /requirements \
  && ldd /jre/bin/java | awk 'NF == 4 { system("cp --parents " $3 " /requirements") }'

# final image
FROM scratch
LABEL maintainer="GittRekt"
ENV JAVA_HOME=/jre
ENV PATH="/jre/bin:${PATH}"

COPY --from=builder /jre /jre
COPY --from=builder /signum /
COPY --from=builder /requirements/ /

VOLUME ["/conf", "/db"]
EXPOSE 8125/tcp 8123/tcp
ENTRYPOINT [ "/jre/bin/java", "-XX:MaxRAMPercentage=90.0", "-jar", "/signum-node.jar", "--headless", "-c", "/conf/" ]
