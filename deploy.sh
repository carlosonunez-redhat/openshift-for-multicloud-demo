#!/usr/bin/env bash
DATA_VOLUME_NAME=ansible-data-vol
CONTAINER_BIN="${CONTAINER_BIN:-podman}"
COMPOSE_FILE="${COMPOSE_FILE:-compose.yaml}"
COMPOSE_BIN="${COMPOSE_BIN:-podman-compose}"
CONFIG_YAML_PATH="$(dirname "$0")/config.yaml"
REGENERATE_SECRETS=false

usage() {
  cat <<-EOF
[ENV_VARS] $(basename "$0") [options]
Deploys the demo.

OPTIONS

  --regenerate-secrets     Recreate existing secrets entirely.
  --secrets-only           Only refresh the secrets in the cluster config directory.
  --kustomizations-only    Refresh secrets and managed cluster kustomizations.

ENVIRONMENT VARIABLES

  REBUILD       Rebuilds data volumes.

NOTES

- You can also use this script to refresh the encrypted secrets and/or managed cluster
  kustomizations that Flux will synchronize with your ACM hubs.

  To do that, add the '--secrets-only' or '--kustomizations-only' flags to the end of your
  './deploy.sh' command.
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
  test -n "$REBUILD" && _container volume rm "$DATA_VOLUME_NAME" -f >/dev/null
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
  cmd="$COMPOSE_BIN run --rm"
  test -n "$REBUILD" && cmd="$cmd --build"
  $cmd deploy |
    grep --color=always -Ev '(^[a-z0-9]{64}$|openshift-for-multicloud)'
}

preflight() {
  _confirm_prereqs_or_fail
}

generate_cluster_secrets() {
  _cluster_pgp_key_fp() {
    gpg --show-keys --with-colons <(sops decrypt --extract \
      '["common"]["gitops"]["repo"]["secrets"]["cluster_gpg_key"]' \
      config.yaml) | grep -m 1 fpr | rev | cut -f2 -d ':' | rev
  }

  _cluster_pull_secret() {
    sops decrypt --extract '["common"]["ocp_pull_secret"]' "$CONFIG_YAML_PATH"
  }

  _write_file_if_pgp_fp_differs_from_cluster_pgp_fp() {
    _file_pgp_fp_matches_cluster_pgp_key_fp() {
      local fp yq_query
      fp="$1"
      yq_query="$2"
      test -f "$fp" && test "$(yq -r "$yq_query" "$fp")" == "$(_cluster_pgp_key_fp)"
    }

    _delete_if_regenerating() {
      test "${REGENERATE_SECRETS,,}" == 'true' || return 0
      test -f "$file" || return 0
      rm "$file"
    }

    local file yq_query encrypt thing
    file="$1"
    yq_query="$2"
    text="$3"
    encrypt="${4:-false}"

    _delete_if_regenerating "$file"

    _file_pgp_fp_matches_cluster_pgp_key_fp "$file" "$yq_query" && return 0
    test "${encrypt,,}" == 'false' && thing='file' || thing=secret
    >&2 echo "INFO: Writing cluster $thing: '$file' (encrypt: $encrypt, regenerate: $REGENERATE_SECRETS)"
    test "${encrypt,,}" == false && echo "$text" > "$file" && return 0
    echo "$text" | sops encrypt --filename-override "$file" --output "$file"
  }

  _encrypt_file_if_pgp_fp_differs_from_cluster_pgp_fp() {
    _write_file_if_pgp_fp_differs_from_cluster_pgp_fp "$1" "$2" "$3" 'true'
  }

  _write_pull_secret_if_pgp_fp_changed() {
    _encrypt_file_if_pgp_fp_differs_from_cluster_pgp_fp \
      "$(dirname "$0")/infra/secrets/pull_secret.yaml" \
      '.sops.pgp[0].fp' \
      "$(cat <<-EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: ocp-pull-secret
  namespace: replace-me
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: $(_cluster_pull_secret | base64 -w 0)
EOF
)"
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
    local yaml
    yaml="$(cat <<-EOF
apiVersion: v1
kind: Secret
metadata:
  name: cloud-creds
  namespace: replace-me
  labels:
    cluster.open-cluster-management.io/type: "$1"
    cluster.open-cluster-management.io/credentials: ""
data: $(sops decrypt --output-type=json --extract '["environments"]' "$CONFIG_YAML_PATH" |
  jq --arg cloud "$1" -r '.[]|select(.name == $cloud)|.cloud_config.credentials|map_values(@base64)')
EOF
)"
    if test "$(yq -r .data <<< "$yaml")" == "null"
    then
      >&2 echo "ERROR: Couldn't find creds in $CONFIG_YAML_PATH for cloud '$1'"
      return 1
    fi
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

  _write_dataprotection_secret_if_pgp_fp_changed() {
    local yaml
    yaml="$(cat <<-EOF
apiVersion: v1
kind: Secret
metadata:
  name: dataprotection-creds
  namespace: open-cluster-management-backup
  labels:
    cluster.open-cluster-management.io/type: "$1"
    cluster.open-cluster-management.io/credentials: ""
data:
  credentials_file: $(sops decrypt --extract \
      '["common"]["dataprotection"]["settings"]["aws"]["credentials_file"]' \
    "$CONFIG_YAML_PATH" | base64 -w 0)
EOF
)"
    if test "$(yq -r .data <<< "$yaml")" == "null"
    then
      >&2 echo "ERROR: Couldn't find creds in $CONFIG_YAML_PATH for cloud '$1'"
      return 1
    fi
    if test "$#" -gt 1
    then
      for replacement in "${@:2}"
      do yaml=$(sed "s/$replacement/g" <<< "$yaml")
      done
    fi
    secret_dir="$(dirname "$0")/infra/secrets/dataprotection/$1"
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
  namespace: replace-me
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

      local file key value new_yaml current_yaml diff value_is_string
      file="$1"
      key="$2"
      value="$3"
      value_is_string="${4:-false}"
      current_yaml=$(sops decrypt --extract '["data"]["install-config.yaml"]' "$f" | base64 -d | yq .)
      current=$(yq -r "$key" <<< "$current_yaml")
      # need to use jq here to properly test equality of JSON objects, as the current value
      # might be formatted differently. (use 'true' to drop the return code, as it's not needed.)
      if grep -Eiq '^true$' <<< "$value_is_string"
      then
        diff=$(diff \
          <(echo "$current" | jq -r 'tostring') \
          <(echo "$value" | jq -r 'tostring')) || true
      else
        diff=$(diff \
          <(_quote_if_json_string "$current" | jq -r .) \
          <(_quote_if_json_string "$value" | jq -r .)) || true
      fi
      test -z "$diff" && return 0
      >&2 echo "INFO: Updating key '$key' in  installconfig '$f' (diff: $diff)"
      if grep -Eiq '^true$' <<< "$value_is_string"
      then
        new_yaml=$(yq -o=j -I=0 -r "$key |= ($value|to_json|tostring)" <<< "$current_yaml" |
          base64 -w 0)
      else
        new_yaml=$(yq -o=j -I=0 -r "$key |= $(_quote_if_json_string "$value")" <<< "$current_yaml" |
          base64 -w 0)
      fi
      test -z "$new_yaml" && return 1
      sops set "$f" '["data"]["install-config.yaml"]' "\"$new_yaml\""
    }

    _update_if_different_as_string() {
      _update_if_different "$1" "$2" "$3" 'true'
    }

    _perform_cloud_specific_updates_aws() {
      return 0
    }

    _perform_cloud_specific_updates_gcp() {
      local project
      project=$(sops decrypt "$CONFIG_YAML_PATH" |
        yq -r '.environments[] | select(.name == "'"$cloud"'") | .cloud_config.credentials."service_account.json" | from_json | .project_id')
      _update_if_different "$1" '.platform.gcp.projectID' "$project"
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
  namespace: replace-me
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
      _update_if_different "$f" '.metadata.name' "managed-cluster-$cloud"
      _update_if_different "$f" ".platform.$cloud.region" "$region"
      _update_if_different "$f" '.pullSecret' 'ocp-pull-secret'
      _update_if_different "$f" '.sshKey' "$(_ssh_public_key)"
      "_perform_cloud_specific_updates_$cloud" "$f"
    done
  }

  _write_cluster_sops_config_if_pgp_fp_changed
  _write_pull_secret_if_pgp_fp_changed
  _write_cloud_secret_if_pgp_fp_changed 'aws'
  _write_cloud_secret_if_pgp_fp_changed 'gcp' 'service_account.json/osServiceAccount.json'
  _write_dataprotection_secret_if_pgp_fp_changed 'aws'
  _write_ssh_key_secret
  _write_installconfig_cloud_secrets 'aws' 'gcp'
  _update_secrets_kustomization_yaml
}

update_clusterdeployment_kustomizations() {
  local patches domain cluster_name region cluster_ocp_version
  for cloud in "$@"
  do
    f="infra/acm_hubs/primary/managedclusters/$cloud/managedcluster.yaml"
    select='.target.kind == "ClusterDeployment" and .target.name == "replace-me"'
    patches=$(yq -r ".spec.patches[] | select($select) | .patch" "$f" | yq -o=j -I=0 .)
    test -z "$patches" && return 1
    domain=$(sops decrypt "$CONFIG_YAML_PATH" |
      yq -r '.environments[] | select(.name == "'"$cloud"'") | .cloud_config.networking.domain')
    cluster_name=$(sops decrypt "$CONFIG_YAML_PATH" |
      yq -r '.environments[] | select(.name == "'"$cloud"'") | .cluster_config.cluster_name')
    region=$(sops decrypt "$CONFIG_YAML_PATH" |
      yq -r '.environments[] | select(.name == "'"$cloud"'") | .cloud_config.networking.region')
    cluster_ocp_version=$(sops decrypt "$CONFIG_YAML_PATH" |
      yq -r '.environments[] | select(.name == "'"$cloud"'") | .cluster_config.openshift_image_set')
    for kvp in "baseDomain;$domain" "clusterName;$cluster_name" "metadata/name;$cluster_name" \
      "region;$region" "imageSetRef;$cluster_ocp_version"
    do
      k="$(cut -f1 -d ';' <<< "$kvp")"
      v="$(cut -f2 -d ';' <<< "$kvp")"
      patches=$(jq "(.[] | select(.path | contains(\"$k\"))).value = \"$v\"" <<< "$patches")
    done
    yq -i \
      "(.spec.patches[] | select($select)).patch = \"$(yq -p=j -o=y <<< "$patches")\"" \
      "$f"
  done
}

update_klusterletaddonconfig_kustomizations() {
  local patches domain cluster_name region cluster_ocp_version
  for cloud in "$@"
    do
    f="infra/acm_hubs/primary/managedclusters/$cloud/managedcluster.yaml"
    select='.target.kind == "ClusterDeployment" and .target.name == "replace-me"'
    patches=$(yq -r ".spec.patches[] | select($select) | .patch" "$f" | yq -o=j -I=0 .)
    test -z "$patches" && return 1
    cluster_name=$(sops decrypt "$CONFIG_YAML_PATH" |
      yq -r '.environments[] | select(.name == "'"$cloud"'") | .cluster_config.cluster_name')
    for kvp in "metadata/name:$cluster_name" "clusterName:$cluster_name"
    do
      k="$(cut -f1 -d ';' <<< "$kvp")"
      v="$(cut -f2 -d ';' <<< "$kvp")"
      patches=$(jq "(.[] | select(.path | contains(\"$k\"))).value = \"$v\"" <<< "$patches")
    done
    yq -i \
      "(.spec.patches[] | select($select)).patch = \"$(yq -p=j -o=y <<< "$patches")\"" \
      "$f"
  done
}

update_managedcluster_kustomizations() {
  local patches domain cluster_name region cluster_ocp_version
  for cloud in "$@"
  do
    f="infra/acm_hubs/primary/managedclusters/$cloud/managedcluster.yaml"
    select='.target.kind == "ManagedCluster" and .target.name == "replace-me"'
    patches=$(yq -r ".spec.patches[] | select($select) | .patch" "$f" | yq -o=j -I=0 .)
    test -z "$patches" && return 1
    cluster_name=$(sops decrypt "$CONFIG_YAML_PATH" |
      yq -r '.environments[] | select(.name == "'"$cloud"'") | .cluster_config.cluster_name')
    for kvp in "metadata/name:$cluster_name"
    do
      k="$(cut -f1 -d ';' <<< "$kvp")"
      v="$(cut -f2 -d ';' <<< "$kvp")"
      patches=$(jq "(.[] | select(.path | contains(\"$k\"))).value = \"$v\"" <<< "$patches")
    done
    yq -i \
      "(.spec.patches[] | select($select)).patch = \"$(yq -p=j -o=y <<< "$patches")\"" \
      "$f"
  done
}

show_help_if_requested() {
  grep -Eq '[-]{1,2}help' <<< "$@" || return 0
  usage
  exit 0
}

refresh_secrets_only() {
  grep -Eq -- '--secrets-only' <<< "$@"
}

refresh_managed_cluster_kustomizations_only() {
  grep -Eq -- '--refresh-kustomizations' <<< "$@"
}

secrets_regeneration_requested() {
  grep -Eq -- '--regenerate-secrets' <<< "$@"
}

set -e
show_help_if_requested "$@"
preflight || exit 1
secrets_regeneration_requested "$@" && REGENERATE_SECRETS=true
generate_cluster_secrets
if refresh_secrets_only "$@"
then
  op=updated
  test "${REGENERATE_SECRETS,,}" == 'true' && op=created
  >&2 echo "INFO: Secrets $op (if needed); stopping."
  exit 0
fi

update_clusterdeployment_kustomizations 'aws' 'gcp'
update_klusterletaddonconfig_kustomizations 'aws' 'gcp'
update_managedcluster_kustomizations 'aws' 'gcp'
if refresh_managed_cluster_kustomizations_only "$@"
then
  >&2 echo "INFO: Managed cluster kustomizations regenerated (if needed); stopping."
  exit 0
fi

create_data_volume
upload_config_into_data_volume
deploy
