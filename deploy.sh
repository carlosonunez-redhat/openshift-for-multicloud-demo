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

_ssh_private_key() {
  sops decrypt --extract '["common"]["gitops"]["repo"]["secrets"]["ssh_key"]' config.yaml; echo
}

_ssh_public_key() {
  local tmp
  trap 'rc=$?; test -f "$tmp" && rm "$tmp"; trap - RETURN; return $rc' RETURN
  trap 'rc=$?; test -f "$tmp" && rm "$tmp"; exit $rc' INT HUP EXIT
  tmp=$(mktemp /tmp/tmp_XXXXXXXXXXX)
  _ssh_private_key > "$tmp"
  chmod 600 "$tmp"
  ssh-keygen -yf "$tmp"
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
    local component namespace metadata
    for kvp in "$@"
    do
      component="$(cut -f1 -d ';' <<< "$kvp")"
      namespace="$(cut -f2 -d ';' <<< "$kvp")"
      if test -z "$namespace" && test -f "$(dirname "$0")/infra/${component}/namespace.yaml"
      then namespace=$(yq -r .metadata.name \
          "$(dirname "$0")/infra/${component}/namespace.yaml")
      elif test -z "$namespace"
      then namespace=default
      fi
      metadata="name: ocp-pull-secret,namespace: $namespace"
      _encrypt_file_if_pgp_fp_differs_from_cluster_pgp_fp \
        "$(dirname "$0")/infra/secrets/$(basename "$component").yaml" \
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
      "$(dirname "$0")/infra/secrets/.sops.yaml" \
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

  _update_secrets_kustomization_yaml() {
    kustomization_fp="$(dirname "$0")/infra/secrets/kustomization.yaml"
    current=$(find "$(dirname "$kustomization_fp")" -maxdepth 1 -type f -name '*.yaml' -exec basename {} \; |
      grep -Ev '(\.sops|kustomization).yaml' |
      sort -u)
    last=$(yq -r '.resources[]' "$kustomization_fp" | sort)
    test "$current" == "$last" && return 0
    current_json=$(printf "[%s]" \
      "$(echo "$current" |
          sed -E 's/(.*)/"\1"/g' |
          tr '\n' ',' |
          sed -E 's/,$//')")
    yq -ir ".resources = $current_json" "$kustomization_fp"
  }

  _write_cloud_secret_if_pgp_fp_changed() {
    local creds yaml
    creds=$(sops decrypt --extract '["environments"]' "$CONFIG_YAML_PATH" |
      yq -o=j -I=0 -r '.[] | select(.name == "'"$1"'") | .cloud_config.credentials')
    if test -z "$creds"
    then
      >&2 echo "ERROR: Couldn't find cloud config credentials for $1"
      return 1
    fi
    yaml="$(cat <<-EOF
apiVersion: v1
kind: Secret
metadata:
  name: cloud-creds
  namespace: openshift-multicluster-engine
data: {}
EOF
)"
    yaml=$(yq -r ".data = ($creds | map_values(@base64))" <<< "$yaml")
    if test "$#" -gt 1
    then
      for replacement in "${@:2}"
      do yaml=$(sed "s/$replacement/g" <<< "$yaml")
      done
    fi
    secret_dir="$(dirname "$0")/infra/secrets/cloud_credentials/$1"
    test -d "$secret_dir" || mkdir -p "$secret_dir"
    cat >"$secret_dir/kustomization.yaml" <<-EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- credential.yaml
EOF
    _encrypt_file_if_pgp_fp_differs_from_cluster_pgp_fp \
      "$secret_dir/credential.yaml" \
      '.sops.pgp[0].fp' \
      "$yaml"
  }

  _write_ssh_key_secret() {
    secret_dir="$(dirname "$0")/infra/secrets"
    _encrypt_file_if_pgp_fp_differs_from_cluster_pgp_fp \
      "$secret_dir/ssh_key.yaml" \
      '.sops.pgp[0].fp' \
      "$(cat <<-EOF
apiVersion: v1
kind: Secret
metadata:
  name: cluster-ssh-key
  namespace: openshift-multicluster-engine
type: Opaque
data:
  ssh-privatekey: $(_ssh_private_key | base64 -w 0)
  ssh-publickey: $(_ssh_public_key | base64 -w 0)
EOF
)"
  }

  _write_installconfig_cloud_secrets() {
    _update_if_different() {
      _quote_if_json_string() {
        # replace newlines with literal newlines to avoid JSON parse errors while diffing,
        # but only if the string passed in is not an array or object.
        # https://superuser.com/a/1658619
        grep -E '^({|\[)' <<< "$1" || { echo "\"$1\"" |
          sed 's/$/\\n/g' |
          tr -d '\n' |
          sed -E 's/\\n$//'; }
      }
      local file key value new_yaml current_yaml diff
      file="$1"
      key="$2"
      value="$3"
      current_yaml=$(sops decrypt --extract '["data"]["install-config.yaml"]' "$f" | base64 -d | yq .)
      current=$(yq -r "$key" <<< "$current_yaml")
      # need to use jq here to properly test equality of JSON objects, as the current value
      # might be formatted differently.
      diff=$(diff \
        <(_quote_if_json_string "$current" | jq -r .) \
        <(_quote_if_json_string "$value" | jq -r .))
      test -z "$diff" && return 0
      >&2 echo "INFO: Updating key '$key' in  installconfig '$f' (diff: $diff)"
      new_yaml=$(yq -o=j -I=0 -r "$key |= $(_quote_if_json_string "$value")" <<< "$current_yaml" |
        base64 -w 0)
      test -z "$new_yaml" && return 1
      sops set "$f" '["data"]["install-config.yaml"]' "\"$new_yaml\""
    }
    local secret_dir f domain region yaml
    secret_dir="$(dirname "$0")/infra/secrets"
    for cloud in "$@"
    do
      f="${secret_dir}/installconfigs/${cloud}/installconfig.yaml"
      template_f="${secret_dir}/templates/installconfigs/${cloud}.yaml"
      if ! test -e "$f"
      then
        yaml=$(cat <<-YAML
apiVersion: v1
kind: Secret
metadata:
  name: installconfig
  namespace: openshift-multicluster-engine
data:
  install-config.yaml: $(base64 -w 0 < "$template_f")
YAML
)
        echo "$yaml" | sops --config "${secret_dir}/.sops.yaml" encrypt --filename-override "$f" --output "$f"
      elif test "$(sops filestatus "$f" | yq -r '.encrypted')" == "false"
      then sops --config "${secret_dir}/.sops.yaml" encrypt --in-place "$f"
      fi
      domain=$(sops decrypt "$CONFIG_YAML_PATH" |
        yq -r '.environments[] | select(.name == "'"$cloud"'") | .cloud_config.networking.domain')
      region=$(sops decrypt "$CONFIG_YAML_PATH" |
        yq -r '.environments[] | select(.name == "'"$cloud"'") | .cloud_config.networking.region')
      _update_if_different "$f" '.baseDomain' "$domain"
      _update_if_different "$f" ".platform.$cloud.region" "$region"
      _update_if_different "$f" '.pullSecret' "$(_cluster_pull_secret)"
      _update_if_different "$f" '.sshKey' "$(_ssh_private_key)"
    done
  }

  _write_cluster_sops_config_if_pgp_fp_changed
  _write_pull_secrets_for_cluster_components_if_pgp_fp_changed \
    'operators/acm;hive'
  _write_cloud_secret_if_pgp_fp_changed 'aws'
  _write_cloud_secret_if_pgp_fp_changed 'gcp' 'service_account.json:/osServiceAccount.json:'
  _write_ssh_key_secret
  _write_installconfig_cloud_secrets 'aws' 'gcp'
  _update_secrets_kustomization_yaml
}

update_managedcluster_kustomizations() {
  local patches domain cluster_name region cluster_ocp_version
  for cloud in "$@"
  do
    f="infra/cluster/$cloud/managedclusters.yaml"
    patches=$(yq -r '.spec.patches[] | select(.target.name == "cluster") | .patch' "$f" |
      yq -o=j -I=0 .)
    test -z "$patches" && return 1
    domain=$(sops decrypt "$CONFIG_YAML_PATH" |
      yq -r '.environments[] | select(.name == "'"$cloud"'") | .cloud_config.networking.domain')
    cluster_name=$(sops decrypt "$CONFIG_YAML_PATH" |
      yq -r '.environments[] | select(.name == "'"$cloud"'") | .cluster_config.cluster_name')
    region=$(sops decrypt "$CONFIG_YAML_PATH" |
      yq -r '.environments[] | select(.name == "'"$cloud"'") | .cloud_config.networking.region')
    cluster_ocp_version=$(sops decrypt "$CONFIG_YAML_PATH" |
      yq -r '.environments[] | select(.name == "'"$cloud"'") | .cluster_config.openshift_image_set')
    for kvp in "baseDomain;$domain" "clusterName;$cluster_name" \
      "region;$region" "imageSetRef;$cluster_ocp_version"
    do
      k="$(cut -f1 -d ';' <<< "$kvp")"
      v="$(cut -f2 -d ';' <<< "$kvp")"
      patches=$(jq "(.[] | select(.path | contains(\"$k\"))).value = \"$v\"" <<< "$patches")
    done
    yq -i \
      "(.spec.patches[] | select(.target.name == \"cluster\")).patch = \"$(yq -p=j -o=y <<< "$patches")\"" \
      "$f"
  done
}

show_help_if_requested() {
  grep -Eq '[-]{1,2}help' <<< "$@" || return 0
  usage
  exit 0
}

set -e
show_help_if_requested "$@"
preflight
prepare_cluster_secrets
update_managedcluster_kustomizations 'aws' 'gcp'
create_data_volume
upload_config_into_data_volume
deploy
