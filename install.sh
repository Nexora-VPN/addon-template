#!/bin/sh
# Installs, updates or removes this Nexora addon on a Linux host — by hand, or
# by the panel over SSH (the same way it installs a node). Run it as root.
#
#   sh install.sh --method docker --opt port=8090 --panel-url https://panel.example --claim-code ABC123
#   sh install.sh --method script --version v0.1.0
#   sh install.sh --uninstall [--purge]
#
# --method script   the binary under a systemd unit (no Docker needed)
# --method docker   the compose stack in deploy/compose.yml
# --version TAG     a release tag (default: the latest release)
# --binary-file F   install this archive instead of downloading one (script)
# --opt KEY=VALUE   an answer to one of the manifest's install options; repeat
# --panel-url URL   the panel's address, passed as NEXORA_PANEL_URL
# --claim-code C    the one-time code the panel registers the addon with
# --uninstall       stop and remove the addon; --purge also deletes its data
#
# Running it again updates in place: the answers already given are kept
# unless --opt changes them, and the data directory is never touched.
set -eu

SLUG="template"
REPO="Nexora-VPN/addon-template"
BIN="addon-template"
DIR="/opt/nexora-addons/${SLUG}"
UNIT="nexora-addon-${SLUG}"

METHOD=""
VERSION=""
BINARY_FILE=""
PANEL_URL=""
CLAIM_CODE=""
UNINSTALL=0
PURGE=0
OPTS=""

die() { echo "install: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case "$1" in
	--method) METHOD="$2"; shift 2 ;;
	--version) VERSION="$2"; shift 2 ;;
	--binary-file) BINARY_FILE="$2"; shift 2 ;;
	--opt)
		case "$2" in *=*) ;; *) die "--opt takes KEY=VALUE" ;; esac
		OPTS="${OPTS}$2
"
		shift 2 ;;
	--panel-url) PANEL_URL="$2"; shift 2 ;;
	--claim-code) CLAIM_CODE="$2"; shift 2 ;;
	--uninstall) UNINSTALL=1; shift ;;
	--purge) PURGE=1; shift ;;
	*) die "unknown argument $1" ;;
	esac
done

[ "$(id -u)" = 0 ] || die "run as root"

if [ "$UNINSTALL" = 1 ]; then
	if [ -f "/etc/systemd/system/${UNIT}.service" ]; then
		systemctl disable --now "$UNIT" 2>/dev/null || true
		rm -f "/etc/systemd/system/${UNIT}.service"
		systemctl daemon-reload
	fi
	if [ -f "${DIR}/compose.yml" ] && command -v docker >/dev/null 2>&1; then
		docker compose -f "${DIR}/compose.yml" --env-file "${DIR}/.env" down || true
	fi
	if [ "$PURGE" = 1 ]; then
		rm -rf "$DIR"
	else
		rm -rf "${DIR}/bin" "${DIR}/compose.yml"
	fi
	echo "removed ${SLUG}"
	exit 0
fi

# An update keeps the method the addon was installed with.
if [ -z "$METHOD" ] && [ -f "${DIR}/.method" ]; then
	METHOD="$(cat "${DIR}/.method")"
fi
case "$METHOD" in
script | docker) ;;
*) die "--method script or --method docker" ;;
esac

if [ -z "$VERSION" ]; then
	VERSION="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)"
	[ -n "$VERSION" ] || die "could not read the latest release of ${REPO}"
fi

mkdir -p "${DIR}/data"
chmod 700 "${DIR}"
echo "$METHOD" >"${DIR}/.method"

# envquote VALUE: the value as both readers of the .env take it literally —
# systemd's EnvironmentFile and docker compose's env_file. Single quotes are
# literal to both; a value holding one goes in double quotes, with \ and "
# escaped, and for compose, which expands $ inside them, $ doubled.
envquote() {
	case "$1" in
	*\'*) ;;
	*)
		printf "'%s'" "$1"
		return
		;;
	esac
	v="$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
	[ "$METHOD" != docker ] || v="$(printf '%s' "$v" | sed 's/\$/$$/g')"
	printf '"%s"' "$v"
}

# setenv KEY VALUE: replace or add one line of the .env file.
setenv() {
	touch "${DIR}/.env"
	chmod 600 "${DIR}/.env"
	grep -v "^$1=" "${DIR}/.env" >"${DIR}/.env.tmp" || true
	printf '%s=%s\n' "$1" "$(envquote "$2")" >>"${DIR}/.env.tmp"
	mv "${DIR}/.env.tmp" "${DIR}/.env"
	chmod 600 "${DIR}/.env" # the mv carries the temporary file's mode, not the 600 above
}

printf '%s' "$OPTS" | while IFS= read -r kv; do
	[ -n "$kv" ] || continue
	key="$(printf '%s' "${kv%%=*}" | tr 'a-z' 'A-Z')"
	setenv "NEXORA_OPT_${key}" "${kv#*=}"
done
[ -z "$PANEL_URL" ] || setenv NEXORA_PANEL_URL "$PANEL_URL"
[ -z "$CLAIM_CODE" ] || setenv NEXORA_CLAIM_CODE "$CLAIM_CODE"
setenv NEXORA_ADDON_VERSION "${VERSION#v}"

case "$METHOD" in
script)
	case "$(uname -m)" in
	x86_64 | amd64) ARCH=amd64 ;;
	aarch64 | arm64) ARCH=arm64 ;;
	*) die "no build of ${SLUG} for $(uname -m)" ;;
	esac
	setenv NEXORA_DATA_DIR "${DIR}/data"
	tmp="$(mktemp -d)"
	trap 'rm -rf "$tmp"' EXIT
	if [ -n "$BINARY_FILE" ]; then
		cp "$BINARY_FILE" "${tmp}/addon.tar.gz"
	else
		curl -fsSL -o "${tmp}/addon.tar.gz" \
			"https://github.com/${REPO}/releases/download/${VERSION}/${BIN}-linux-${ARCH}.tar.gz"
	fi
	tar -xzf "${tmp}/addon.tar.gz" -C "$tmp"
	mkdir -p "${DIR}/bin"
	install -m 755 "${tmp}/${BIN}" "${DIR}/bin/${BIN}"
	cat >"/etc/systemd/system/${UNIT}.service" <<UNIT
[Unit]
Description=Nexora addon ${SLUG}
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=${DIR}/.env
WorkingDirectory=${DIR}
ExecStart=${DIR}/bin/${BIN}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
	systemctl daemon-reload
	systemctl enable "$UNIT" >/dev/null 2>&1
	systemctl restart "$UNIT"
	;;
docker)
	command -v docker >/dev/null 2>&1 || die "docker is not installed; use --method script"
	chown 10001 "${DIR}/data" # the image runs as uid 10001
	curl -fsSL -o "${DIR}/compose.yml" "https://raw.githubusercontent.com/${REPO}/${VERSION}/deploy/compose.yml"
	docker compose -f "${DIR}/compose.yml" --env-file "${DIR}/.env" pull
	docker compose -f "${DIR}/compose.yml" --env-file "${DIR}/.env" up -d
	;;
esac

echo "installed ${SLUG} ${VERSION} (${METHOD}) in ${DIR}"
