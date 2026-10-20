# Siege Engine dedicated server image (Debian slim + headless Godot). Build from the repository root:
#   docker build -f deploy/Dockerfile -t siege-server .
# Holds the game CODE only. Game data (your imported packs) is mounted at /app/gamedata at run time and is never
# part of the image. Works for linux/amd64 and linux/arm64 (Oracle Ampere, Hetzner CAX, Raspberry Pi 4/5).
# Guide: docs/SERVER_DEPLOY.md.
FROM debian:12-slim AS godot
ARG GODOT_VERSION=4.6.3
ARG GODOT_RELEASE_URL=https://github.com/godotengine/godot/releases/download
# Optional pins (SHA-512 of the zip, per architecture); empty = check against the release's SHA512-SUMS.txt.
ARG GODOT_SHA512_AMD64=""
ARG GODOT_SHA512_ARM64=""
ARG TARGETARCH
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl unzip \
	&& rm -rf /var/lib/apt/lists/*
RUN set -eux; \
	case "${TARGETARCH:-amd64}" in \
		amd64) arch=x86_64; pin="$GODOT_SHA512_AMD64" ;; \
		arm64) arch=arm64;  pin="$GODOT_SHA512_ARM64" ;; \
		*) echo "unsupported architecture ${TARGETARCH}"; exit 1 ;; \
	esac; \
	zip="Godot_v${GODOT_VERSION}-stable_linux.${arch}.zip"; \
	base="${GODOT_RELEASE_URL}/${GODOT_VERSION}-stable"; \
	curl -fsSL -o "/tmp/${zip}" "${base}/${zip}"; \
	if [ -z "$pin" ]; then \
		curl -fsSL -o /tmp/SHA512-SUMS.txt "${base}/SHA512-SUMS.txt"; \
		pin="$(grep " ${zip}\$" /tmp/SHA512-SUMS.txt | cut -d' ' -f1)"; \
	fi; \
	[ -n "$pin" ] || { echo "no checksum for ${zip}"; exit 1; }; \
	echo "${pin}  /tmp/${zip}" | sha512sum -c -; \
	unzip -q "/tmp/${zip}" -d /tmp/godot; \
	mv "/tmp/godot/Godot_v${GODOT_VERSION}-stable_linux.${arch}" /godot

FROM debian:12-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libfontconfig1 libx11-6 libxcursor1 \
		libxi6 libxinerama1 libxrandr2 libgl1 libasound2 \
	&& rm -rf /var/lib/apt/lists/* \
	&& useradd --create-home --uid 10001 siege
COPY --from=godot /godot /usr/local/bin/godot
WORKDIR /app
COPY game/ /app/game/
# gamedata/ sits next to game/: the engine finds ../gamedata by itself (Assets._find_data_root).
RUN mkdir -p /app/gamedata /config && chown -R siege:siege /app /config
USER siege
# Builds the script class cache and imports the project's own resources (no game data in here).
RUN godot --headless --audio-driver Dummy --path /app/game --import || true
VOLUME ["/app/gamedata"]
# 47700 game (udp: ENet, the default; tcp: WebSocket behind a proxy), 47702 match list (HTTP).
EXPOSE 47700/udp 47700/tcp 47702
HEALTHCHECK --interval=30s --timeout=3s --start-period=60s CMD ["bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/47702 && printf 'GET /health HTTP/1.0\\r\\n\\r\\n' >&3 && grep -q ok <&3"]
ENTRYPOINT ["godot", "--headless", "--audio-driver", "Dummy", "--path", "/app/game", "res://server/dedicated_server.tscn", "--"]
CMD ["--server", "--config=/config/server.json"]
