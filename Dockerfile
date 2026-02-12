FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    sane-utils \
    sane-airscan \
    imagemagick \
    curl \
    img2pdf \
    bc \
    xmlstarlet \
    lftp \
    openssh-client \
    smbclient \
    && rm -rf /var/lib/apt/lists/*

COPY airscan.conf /etc/sane.d/airscan.conf
COPY adfwatch.sh /usr/local/bin/adfwatch.sh
RUN chmod +x /usr/local/bin/adfwatch.sh

RUN mkdir -p /scans /tmp/adfwatch

VOLUME /scans

ENTRYPOINT ["/usr/local/bin/adfwatch.sh"]
