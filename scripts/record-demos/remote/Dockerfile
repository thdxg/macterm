# An ephemeral "remote host" for the remote-project demo: sshd, a login shell,
# vim, and zmx — which Macterm's remote panes attach to on the host itself.
# zmx publishes macOS binaries only, so build it here.
FROM debian:12 AS zmx
ARG ZIG_VERSION=0.16.0
ARG ZMX_REF=build-2026-09-06
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl git ca-certificates xz-utils \
    && rm -rf /var/lib/apt/lists/*
# `uname -m` already reports the names zig uses in its tarballs
RUN ARCH="$(uname -m)" \
    && curl -fsSL -o /tmp/zig.tar.xz \
       "https://ziglang.org/download/${ZIG_VERSION}/zig-${ARCH}-linux-${ZIG_VERSION}.tar.xz" \
    && tar -C /usr/local -xf /tmp/zig.tar.xz \
    && mv "/usr/local/zig-${ARCH}-linux-${ZIG_VERSION}" /usr/local/zig \
    && ln -s /usr/local/zig/zig /usr/local/bin/zig \
    && rm -f /tmp/zig.tar.xz
RUN git clone --depth 1 --branch "${ZMX_REF}" https://github.com/thdxg/zmx /src
WORKDIR /src
RUN zig build -Doptimize=ReleaseFast

FROM debian:12
RUN apt-get update && apt-get install -y --no-install-recommends \
      openssh-server vim git less ncurses-term procps ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd
COPY --from=zmx /src/zig-out/bin/zmx /usr/local/bin/zmx

RUN useradd -m -s /bin/bash demo \
    && mkdir -p /home/demo/.ssh \
    && chmod 700 /home/demo/.ssh
COPY authorized_keys /home/demo/.ssh/authorized_keys
RUN chown -R demo:demo /home/demo/.ssh && chmod 600 /home/demo/.ssh/authorized_keys

COPY workspace /workspace
RUN chown -R demo:demo /workspace

# proof-of-identity for the recorder: the container's hostname is whatever the
# demo wants it to read as, so the safety check cannot rely on that
RUN echo macterm-demo-container > /etc/macterm-demo

RUN printf '%s\n' \
      'PermitRootLogin no' \
      'PasswordAuthentication no' \
      'AcceptEnv COLORTERM' \
      'PrintMotd no' \
      > /etc/ssh/sshd_config.d/demo.conf

EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
