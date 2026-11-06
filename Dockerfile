# Job image for the Kodizm virtual CI, run by GitHub Actions as a `container:`.
#
# Same interpreter and extension set as the self-hosted runner image so a
# pipeline behaves identically on both, minus everything that exists only for
# the actions runner itself (the runner tarball, its user, sudo) and for the
# other repositories that share that image (Flutter). The PostgreSQL server
# binaries stay, for suites that run against a real database.
#
# Actions starts a container job as the image's default user and needs root
# there to mount its workspace, so there is deliberately no USER directive.
# The scripts under /opt/kci drop to the unprivileged `ci` account (uid 2000)
# with setpriv before they touch anything that came from a pull request.
FROM php:8.5-cli

# git, unzip and zip are what composer install and actions/checkout need;
# gnupg and ca-certificates feed the nodesource repository below; util-linux
# brings setpriv and procps brings pgrep and pkill, both used by the sandbox
# scripts. gcc and libc6-dev are cgo's toolchain, which `go test -race`
# needs. No sudo: nothing in a job may regain root.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gcc \
        git \
        gnupg \
        jq \
        libc6-dev \
        procps \
        unzip \
        util-linux \
        zip \
    && rm -rf /var/lib/apt/lists/*

# The extension set the kodizm test suite exercises, copied from the runner
# image. pgsql is here despite tests running on SQLite because config and
# migrations reference the driver; exif is a hard requirement of a locked
# dependency, so composer install refuses the lock without it.
ADD --chmod=0755 https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions /usr/local/bin/
RUN install-php-extensions \
        bcmath \
        exif \
        gd \
        intl \
        pcntl \
        pcov \
        pdo_pgsql \
        pdo_sqlite \
        redis \
        sockets \
        sqlite3 \
        zip \
    && rm /usr/local/bin/install-php-extensions

# Pinned by digest: the `2` tag moves, and a silent composer major would
# change install behaviour under a pipeline nobody touched.
COPY --from=composer:2@sha256:3d1eb9437516b0ba88c46a0bb05826451a1ab178d29adacb5ded26dad0899ae4 /usr/bin/composer /usr/local/bin/composer

RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Same minor as packages/kodizm-gateway/go.mod; bump the version and the
# checksum together. The checksum is the linux-amd64 one from go.dev/dl.
ARG GO_VERSION=1.25.6
ARG GO_SHA256=f022b6aad78e362bcba9b0b94d09ad58c5a70c6ba3b7582905fababf5fe0181a
RUN curl -fsSLo /tmp/go.tar.gz "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" \
    && echo "${GO_SHA256}  /tmp/go.tar.gz" | sha256sum -c - \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm /tmp/go.tar.gz

# Server binaries only: a job runs initdb and pg_ctl as `ci` against a data
# directory of its own. The distribution's cluster is switched off before the
# server package is configured, so no cluster exists and no service starts at
# build time. The base (trixie) ships major 17; the binaries live outside PATH.
ARG PG_MAJOR=17
RUN apt-get update && apt-get install -y --no-install-recommends postgresql-common \
    && echo 'create_main_cluster = false' >> /etc/postgresql-common/createcluster.conf \
    && apt-get install -y --no-install-recommends "postgresql-${PG_MAJOR}" \
    && rm -rf /var/lib/apt/lists/*

# A fresh HOME is created per run by kci-sandbox; the account exists so setpriv
# has a stable uid to drop to.
RUN useradd -u 2000 -m -s /bin/bash ci

# Explicit glob, not the whole directory: scripts/test holds the harness tests
# and must not ship. COPY writes root-owned files, so a job running as `ci`
# cannot rewrite the code that sandboxes it.
COPY --chmod=0755 scripts/kci-* /opt/kci/

ENV PATH=/opt/kci:/usr/local/go/bin:/usr/lib/postgresql/${PG_MAJOR}/bin:${PATH}
