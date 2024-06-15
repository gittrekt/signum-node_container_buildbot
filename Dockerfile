# Number of layers don't matter in bulder
# Currently only supports amd64,arm64/v8, ppc64le, s390x
ARG NODE_VERSION=16.20.2
FROM node:${NODE_VERSION}-alpine as builder

# Add the latest alpine repositories
RUN echo "http://dl-3.alpinelinux.org/alpine/latest-stable/main" > /etc/apk/repositories \
  && echo "http://dl-3.alpinelinux.org/alpine/latest-stable/community" >> /etc/apk/repositories \
  && apk update && apk upgrade --available --no-cache

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
    gcompat \
    openjdk11-jdk \
  && rm -rf /var/cache/apk/*

COPY signum-node /signum-node
COPY build.gradle /signum-node/build.gradle
WORKDIR /signum-node

# Run gradle tasks
RUN chmod +x /signum-node/gradlew \
  && /signum-node/gradlew clean 

RUN /signum-node/gradlew dist jdeps \ 
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

RUN mkdir -p /requirements/sbin \
  && mkdir -p /requirements/etc \
  && mkdir -p /signum/db

ENV JAVA_HOME="/usr/lib/jvm/java-11-openjdk"

# Create a custom JRE 
RUN ${JAVA_HOME}/bin/jlink \
  --module-path ${JAVA_HOME}/jmods:/signum/signum-node.jar \
  --add-modules $(cat /signum-node/build/reports/jdeps/print-module-deps-main.txt) \
  --strip-debug \
  --no-man-pages \
  --no-header-files \
  --compress=2 \
  --output /requirements/jre

RUN ldd /requirements/jre/bin/java | awk 'NF == 4 { system("cp --parents " $3 " /requirements") }'

RUN cp /sbin/nologin /requirements/sbin/nologin \
  && echo "signum:x:989:989:Signum-Node User:/conf:/sbin/nologin" > /requirements/etc/passwd

# final image
FROM scratch
LABEL maintainer="GittRekt"

COPY --from=builder /requirements /
COPY --from=builder --chown=989:989 /signum /

VOLUME ["/conf", "/db"]
EXPOSE 8125/tcp 8123/tcp
USER 989:989
ENTRYPOINT [ "/jre/bin/java", "-XX:MaxRAMPercentage=90.0", "-jar", "/signum-node.jar", "--headless", "-c", "/conf/" ]