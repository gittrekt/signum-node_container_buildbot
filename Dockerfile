# Number of layers don't matter in builder
# Currently only supports amd64,arm64/v8, ppc64le, s390x
ARG NODE_VERSION=20
FROM node:${NODE_VERSION}-alpine AS builder

# ---------------------------------------------------------------------------
# Layer 1: System packages + Java (changes very rarely)
# ---------------------------------------------------------------------------
RUN echo "http://dl-3.alpinelinux.org/alpine/latest-stable/main" > /etc/apk/repositories \
  && echo "http://dl-3.alpinelinux.org/alpine/latest-stable/community" >> /etc/apk/repositories \
  && apk update && apk upgrade --available --no-cache \
  && apk add --no-cache --update --upgrade \
    coreutils \
    bind-tools \
    git \
    unzip \
    wget \
    curl \
    bash \
    gcompat \
    openjdk21-jdk \
    binutils \
  && rm -rf /var/cache/apk/*

ENV JAVA_HOME="/usr/lib/jvm/java-21-openjdk"

# ---------------------------------------------------------------------------
# Layer 2: Gradle wrapper + build definition only
# These files change less often than source → better cache hit rate
# ---------------------------------------------------------------------------
WORKDIR /signum-node

COPY signum-node/gradlew \
     signum-node/gradlew.bat \
     signum-node/build.gradle \
     signum-node/settings.gradle \
     signum-node/gradle.properties \
     ./

COPY signum-node/gradle ./gradle

# Disable Node.js download (we already have Node in the base image)
RUN sed -i 's/download = true/download = false/g' build.gradle \
  && chmod +x gradlew

# Warm Gradle dependency cache (does not compile source yet)
# This layer is reused as long as build.gradle / settings.gradle stay the same
RUN ./gradlew dependencies --no-daemon || true

# ---------------------------------------------------------------------------
# Layer 3: Full source (changes frequently)
# ---------------------------------------------------------------------------
COPY signum-node /signum-node

# Re-apply sed in case the full COPY overwrote build.gradle
RUN sed -i 's/download = true/download = false/g' build.gradle

# Fail early if Node/npm are missing
RUN node -v && npm -v

# Full build
RUN ./gradlew clean dist jdeps \
    --no-daemon \
    -Pjdeps.recursive=true \
    -Pjdeps.ignore.missing.deps=true \
    -Pjdeps.print.module.deps=true

# ---------------------------------------------------------------------------
# Layer 4: Unpack + wallets + jlink (depends on build output)
# ---------------------------------------------------------------------------
RUN unzip -o build/distributions/signum-node.zip -d /signum \
  && cp update-phoenix.sh /signum/update-phoenix.sh \
  && chmod +x /signum/update-phoenix.sh

WORKDIR /signum

# Get phoenix and classic wallets
RUN bash -c /signum/update-phoenix.sh \
  && (cd /tmp && git clone --depth 1 https://github.com/signum-network/signum-classic-wallet.git \
    && cp -r signum-classic-wallet/src/* /signum/html/ui/classic/ \
    && rm -rf signum-classic-wallet)

# Clean up
RUN rm -rf /signum/signum-node.exe 2>/dev/null || true \
  && rm -rf /signum/signum-node.zip 2>/dev/null || true \
  && rm -rf /signum/*.sh 2>/dev/null || true

RUN mkdir -p /requirements/sbin \
  && mkdir -p /requirements/etc \
  && mkdir -p /signum/db

# Create a custom JRE (Java 21)
RUN ${JAVA_HOME}/bin/jlink \
  --module-path ${JAVA_HOME}/jmods \
  --add-modules $(cat /signum-node/build/reports/jdeps/print-module-deps-main.txt) \
  --strip-debug \
  --no-man-pages \
  --no-header-files \
  --compress=2 \
  --output /requirements/jre

RUN ldd /requirements/jre/bin/java | awk 'NF == 4 { system("cp --parents " $3 " /requirements") }'

RUN cp /sbin/nologin /requirements/sbin/nologin \
  && echo "signum:x:989:989:Signum-Node User:/conf:/sbin/nologin" > /requirements/etc/passwd

# ---------------------------------------------------------------------------
# Final image (scratch)
# ---------------------------------------------------------------------------
FROM scratch
LABEL maintainer="GittRekt"

COPY --from=builder /requirements /
COPY --from=builder --chown=989:989 /signum /

VOLUME ["/conf", "/db"]
EXPOSE 8125/tcp 8123/tcp
USER 989:989
ENTRYPOINT [ "/jre/bin/java", "-XX:MaxRAMPercentage=90.0", "-jar", "/signum-node.jar", "--headless", "-c", "/conf/" ]
