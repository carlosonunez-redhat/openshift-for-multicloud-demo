#!/usr/bin/env bash
DATA_VOLUME_NAME=ansible-data-vol
CONTAINER_BIN="${CONTAINER_BIN:-podman}"
COMPOSE_FILE="${COMPOSE_FILE:-compose.yaml}"
COMPOSE_BIN="${COMPOSE_BIN:-podman-compose}"
CONFIG_YAML_PATH="$(dirname "$0")/config.yaml"

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

prepare_cluster_secrets() {
  _cluster_pgp_key_fp() {
    gpg --show-keys --with-colons <(sops decrypt --extract \
      '["common"]["gitops"]["repo"]["secrets"]["cluster_gpg_key"]' \
      config.yaml) | grep -m 1 fpr | rev | cut -f2 -d ':' | rev
  }

  _cluster_pull_secret() {
    sops decrypt -extract '["common"]["ocp_pull_secret"]' "$CONFIG_YAML_PATH"
  }

  _write_file_if_pgp_fp_differs_from_cluster_pgp_fp() {
    _file_pgp_fp_matches_cluster_pgp_key_fp() {
      local fp yq_query
      fp="$1"
      yq_query="$2"
      test -f "$fp" && test "$(yq -r "$yq_query" "$fp")" == "$(_cluster_pgp_key_fp)"
    }

    local file yq_query encrypt thing
    file="$1"
    yq_query="$2"
    text="$3"
    encrypt="${4:-false}"

    _file_pgp_fp_matches_cluster_pgp_key_fp "$file" "$yq_query" && return 0
    test "${encrypt,,}" == 'false' && thing='file' || thing=secret
    >&2 echo "INFO: Writing cluster $thing: '$file' (encrypt: $encrypt)"
    test "${encrypt,,}" == false && echo "$text" > "$file" && return 0
    echo "$text" | sops encrypt --filename-override "$file" --output "$file"
  }

  _encrypt_file_if_pgp_fp_differs_from_cluster_pgp_fp() {
    _write_file_if_pgp_fp_differs_from_cluster_pgp_fp "$1" "$2" "$3" 'true'
  }

  _write_pull_secrets_for_cluster_components_if_pgp_fp_changed() {
    for component in "$@"
    do
      metadata="name: ocp-pull-secret"
      test -f "$(dirname "$0")/cluster/base/${component}/namespace.yaml" &&
        metadata="$metadata,namespace: $(yq -r .metadata.name \
          "$(dirname "$0")/cluster/base/${component}/namespace.yaml")"
      _encrypt_file_if_pgp_fp_differs_from_cluster_pgp_fp \
        "$(dirname "$0")/cluster/base/${component}/pull_secret.yaml" \
        '.sops.pgp[0].fp' \
        "$(cat <<-EOF
apiVersion: v1
kind: Secret
metadata:
$(tr ',' '\n' <<< "$metadata" | sed -E 's/^/  /')
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: $(_cluster_pull_secret | base64 -w 0)
EOF
)"
    done
  }

  _write_cluster_sops_config_if_pgp_fp_changed() {
    _write_file_if_pgp_fp_differs_from_cluster_pgp_fp \
      "$(dirname "$0")/cluster/.sops.yaml" \
      '.creation_rules[0].pgp' \
      "$(cat <<-EOF
---
creation_rules:
- path_regex: '.*.yaml'
  encrypted_regex: '^(data|stringData)$'
  pgp: $(_cluster_pgp_key_fp)
EOF
)"
  }

  _write_cluster_sops_config_if_pgp_fp_changed
  _write_pull_secrets_for_cluster_components_if_pgp_fp_changed 'acm'
}

show_help_if_requested() {
  grep -Eq '[-]{1,2}help' <<< "$@" || return 0
  usage
  exit 0
}

set -e
show_help_if_requested "$@"
prepare_cluster_secrets
preflight
create_data_volume
upload_config_into_data_volume
deploy
