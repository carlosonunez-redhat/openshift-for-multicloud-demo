#!/usr/bin/env bash
DATA_VOLUME_NAME=ansible-data-vol
CONTAINER_BIN="${CONTAINER_BIN:-podman}"
COMPOSE_FILE="${COMPOSE_FILE:-compose.yaml}"
COMPOSE_BIN="${COMPOSE_BIN:-podman-compose}"

usage() {
  cat <<-EOF
[ENV_VARS] $(basename "$0") [options]
Deploys the demo.

ENVIRONMENT VARIABLES

  REBUILD       Rebuilds data volumes.
EOF
}

_container() {
  "$CONTAINER_BIN" "$@"
}

_confirm_prereqs_or_fail() {
  for kvp in "sops;Decrypts config.yaml" \
    "podman;Runs ansible and other stuff" \
    "podman-compose;Runs deployment tasks"
  do
    bin=$(cut -f1 -d ';' <<< "$kvp")
    desc=$(cut -f2 -d ';' <<< "$kvp")
    >/dev/null which "$bin" && continue
    >&2 echo "ERROR: '$bin' missing ($desc)"
    return 1
  done
}

create_data_volume() {
  test -n "$REBUILD" && _container volume rm "$DATA_VOLUME_NAME" >/dev/null
  _container volume ls | grep -q "$DATA_VOLUME_NAME" && return 0
  _container volume create "$DATA_VOLUME_NAME" >/dev/null
}

upload_config_into_data_volume() {
  sops --decrypt "$PWD/config.yaml" |
    _container run --rm \
      -v "$DATA_VOLUME_NAME:/data" \
      -i \
      bash:5 \
      -c 'cat - > /data/config.yaml'
}

deploy() {
  "$COMPOSE_BIN" run --rm deploy |
    grep --color=always -Ev '(^[a-z0-9]{64}$|openshift-for-multicloud)'
}

preflight() {
  _confirm_prereqs_or_fail
}

show_help_if_requested() {
  grep -Eq '[-]{1,2}help' <<< "$@" || return 0
  usage
  exit 0
}

set -e
show_help_if_requested "$@"
preflight
create_data_volume
upload_config_into_data_volume
deploy
