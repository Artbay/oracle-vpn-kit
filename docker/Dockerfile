# 可选方案：把 xray / hysteria / tuic-server 打进一个本地镜像。
# 二进制下载与 sha256 校验复用 scripts/lib.sh（与 systemd 方案完全相同的官方来源），不依赖第三方镜像。
FROM debian:stable-slim AS fetch
ARG XRAY_VERSION=""
ARG HY2_VERSION=""
ARG TUIC_VERSION="1.0.0"
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates unzip python3 openssl \
    && rm -rf /var/lib/apt/lists/*
COPY scripts/lib.sh /kit/scripts/lib.sh
RUN bash -c '. /kit/scripts/lib.sh \
    && mkdir -p /dl/x /dl/h /dl/t \
    && xray_download /dl/x "$XRAY_VERSION" && hy2_download /dl/h "$HY2_VERSION" && tuic_download /dl/t "$TUIC_VERSION"'

FROM debian:stable-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=fetch /dl/x/x/xray /usr/local/bin/xray
COPY --from=fetch /dl/x/x/geoip.dat /dl/x/x/geosite.dat /usr/local/share/xray/
COPY --from=fetch /dl/h/hysteria /usr/local/bin/hysteria
COPY --from=fetch /dl/t/tuic-server /usr/local/bin/tuic-server
RUN chmod 755 /usr/local/bin/xray /usr/local/bin/hysteria /usr/local/bin/tuic-server
ENV XRAY_LOCATION_ASSET=/usr/local/share/xray
