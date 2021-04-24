#!/bin/bash
# shellcheck disable=SC1083   #1083 - false positive with TF template directives (if etc)

readonly EC2_INSTANCE_DYNAMIC_DATA_URL="http://169.254.169.254/latest/dynamic"
readonly EC2_INSTANCE_METADATA_URL="http://169.254.169.254/latest/meta-data"
readonly MAX_RETRIES=30
readonly SCRIPT_NAME="$(basename "$0")"
readonly SLEEP_BETWEEN_RETRIES_SEC=10
readonly VAULT_CONFIG_FILE="vault.hcl"
readonly VAULT_PATH="/etc/vault.d"
readonly VAULT_USER="vault"
readonly VAULT_VERSION=${vault_version}
readonly VAULT_BINARY=${vault_binary}

readonly VAULT_AUTO_JOIN_TAG_KEY=%{ if cluster_tag_key != null }${cluster_tag_key}%{endif}
readonly VAULT_AUTO_JOIN_TAG_VALUE=%{ if cluster_tag_value != null }${cluster_tag_value}%{endif}
readonly VAULT_INIT=true
readonly VAULT_LB=%{ if vault_load_balancer != null }${vault_load_balancer}%{endif}
readonly SETUP_BUCKET=${bucket}

function log {
  local -r level="$1"
  local -r message="$2"
  local -r timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  >&2 echo -e "$${timestamp} [$${level}] [$SCRIPT_NAME] $${message}"
}

function log_info {
  local -r message="$1"
  log "INFO" "$message"
}

function log_warn {
  local -r message="$1"
  log "WARN" "$message"
}

function log_error {
  local -r message="$1"
  log "ERROR" "$message"
}

function strip_prefix {
  local -r str="$1"
  local -r prefix="$2"
  echo "$${str#$prefix}"
}

function assert_not_empty {
  local -r arg_name="$1"
  local -r arg_value="$2"

  if [[ -z "$arg_value" ]]; then
    log_error "The value for '$arg_name' cannot be empty"
    print_usage
    exit 1
  fi
}

function assert_either_or {
  local -r arg1_name="$1"
  local -r arg1_value="$2"
  local -r arg2_name="$3"
  local -r arg2_value="$4"

  if [[ -z "$arg1_value" && -z "$arg2_value" ]]; then
    log_error "Either the value for '$arg1_name' or '$arg2_name' must be passed, both cannot be empty"
    print_usage
    exit 1
  fi
}

# A retry function that attempts to run a command a number of times and returns the output
function retry {
  local -r cmd="$1"
  local -r description="$2"
  local -r max_tries="$3"

  for i in $(seq 1 $max_tries); do
    log_info "$description"

    # The boolean operations with the exit status are there to temporarily circumvent the "set -e" at the
    # beginning of this script which exits the script immediatelly for error status while not losing the exit status code
    output=$(eval "$cmd") && exit_status=0 || exit_status=$?
    log_info "$output"
    if [[ $exit_status -eq 0 ]]; then
      echo "$output"
      return
    fi
    log_warn "$description failed. Will sleep for 10 seconds and try again."
    sleep 10
  done;

  log_error "$description failed after $max_tries attempts."
  exit $exit_status
}

function has_yum {
  [ -n "$(command -v yum)" ]
}

function has_apt_get {
  [ -n "$(command -v apt-get)" ]
}

function install_dependencies {
  log_info "Installing dependencies"
  if has_apt_get; then
    sudo apt-get update -y
    sudo apt-get install -y awscli curl unzip jq
    curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
    sudo apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
    sudo apt-get update
  elif has_yum; then
    sudo yum update -y
    sudo yum install -y aws curl unzip jq yum-utils
    sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
  else
    log_error "Could not find apt-get or yum. Cannot install dependencies on this OS."
    exit 1
  fi
}


function user_exists {
  local -r username="$1"
  id "$username" >/dev/null 2>&1
}

function create_user {
  local -r username="$1"

  if user_exists "$username"; then
    echo "User $username already exists. Will not create again."
  else
    log_info "Creating user named $username"
    sudo useradd "$username"
  fi
}

function install {
  # This could be updated to optionally work with YUM/DNF
  local -r product="$1"
  local -r version="$2"
  if has_apt_get; then
      apt-get install $product=$version
  elif has_yum; then
    sudo yum -y install vault
  fi
}

function lookup_path_in_instance_metadata {
  local -r path="$1"
  curl --silent --show-error --location "$EC2_INSTANCE_METADATA_URL/$path/"
}

function lookup_path_in_instance_dynamic_data {
  local -r path="$1"
  curl --silent --show-error --location "$EC2_INSTANCE_DYNAMIC_DATA_URL/$path/"
}

function get_instance_ip_address {
  lookup_path_in_instance_metadata "local-ipv4"
}

function get_instance_id {
  lookup_path_in_instance_metadata "instance-id"
}

function get_instance_region {
  lookup_path_in_instance_dynamic_data "instance-identity/document" | jq -r ".region"
}

function get_instance_tags {
  local -r instance_id="$1"
  local -r instance_region="$2"
  local tags=""
  local count_tags=""

  log_info "Looking up tags for Instance $instance_id in $instance_region"
  for (( i=1; i<="$MAX_RETRIES"; i++ )); do
    tags=$(aws ec2 describe-tags \
      --region "$instance_region" \
      --filters "Name=resource-type,Values=instance" "Name=resource-id,Values=$${instance_id}")
    count_tags=$(echo $tags | jq -r ".Tags? | length")
    if [[ "$count_tags" -gt 0 ]]; then
      log_info "This Instance $instance_id in $instance_region has Tags."
      echo "$tags"
      return
    else
      log_warn "This Instance $instance_id in $instance_region does not have any Tags."
      log_warn "Will sleep for $SLEEP_BETWEEN_RETRIES_SEC seconds and try again."
      sleep "$SLEEP_BETWEEN_RETRIES_SEC"
    fi
  done

  log_error "Could not find Instance Tags for $instance_id in $instance_region after $MAX_RETRIES retries."
  exit 1
}

# Get the value for a specific tag from the tags JSON returned by the AWS describe-tags:
# https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-tags.html
function get_tag_value {
  local -r tag_key="$1"
  local tags
  tags=$(get_instance_tags "$(get_instance_id)" "$(get_instance_region)")
  echo "$tags" | jq -r ".Tags[] | select(.Key == \"$tag_key\") | .Value" | tr -d '\n'
}

function assert_is_installed {
  local -r name="$1"

  if [[ ! $(command -v $${name}) ]]; then
    log_error "The binary '$name' is required by this script but is not installed or in the system's PATH."
    exit 1
  fi
}

function generate_vault_config {
  local -r config_dir="$1"
  local -r user="$2"
  local -r cluster_tag_key="$3"
  local -r cluster_tag_value="$4"

  local -r region=$(get_instance_region)
  local -r config_path="$config_dir/$VAULT_CONFIG_FILE"
  local instance_id=""
  local instance_ip_address=""

  instance_id=$(get_instance_id)
  instance_ip_address=$(get_instance_ip_address)
  node_name="$(hostname)"

  instance_region=$(get_instance_region)

  log_info "Creating default Vault configuration"
  local default_config_json=$(cat <<EOF
ui = true
cluster_addr = "http://$${instance_ip_address}:8201"
api_addr = "http://$${instance_ip_address}:8200"
listener "tcp" {
  address                  = "[::]:8200"
  tls_disable              = "true"
  tls_disable_client_certs = "true"
}
storage "raft" {
  path = "/opt/vault/data"
  node_id = "$${node_name}"
  retry_join {
     auto_join = "provider=aws addr_type=private_v4 region=$region tag_key=$${cluster_tag_key} tag_value=$${cluster_tag_value}"
     auto_join_scheme = "http"
  }
}
%{if seal_config != null }
seal "${seal_config.type}" {
  %{ for attr_key,attr_value in seal_config.attributes ~}
    ${attr_key} = "${attr_value}"
  %{ endfor ~}
}
%{endif}
EOF
)
  # test
  log_info "Installing Vault config file in $config_path"
  echo "$default_config_json" > "$config_path"
  chown "$user:$user" "$config_path"
}

function vault_autounseal_init () {
    local vault_host=$1
    local init_out=$2
    echo "Init $vault_host with autounseal"
    curl -s -X PUT -H "X-Vault-Request: true" -o $init_out \
        -d '{
            "recovery_shares": 1,
            "recovery_threshold": 1
        }' "http://$${vault_host}:8200/v1/sys/init" || \
        echo "Init failed for $vault_host"
}

function vault_wait_for_leader_election () {
    local vault_host=$1
    for n in {1..60}; do
        if [ -n "$(curl -sf http://$${vault_host}:8200/v1/sys/leader|jq -r '.leader_address')" ]; then
            echo "Leader elected for $vault_host"
            break
        fi
        echo "Waiting for leader election to complete on $vault_host"
        sleep 5
    done
}

function main {
  log_info "Starting vault install"
  install_dependencies
  assert_is_installed "systemctl"
  assert_is_installed "aws"
  assert_is_installed "curl"
  assert_is_installed "jq"

  local node_name="$(hostname)"
  # Update bash prompt and motd
  echo "PS1='$${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@'$node_name'\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '" >> /home/ubuntu/.bashrc
  rm -f /etc/update-motd.d/*
  echo "You are logged into $node_name" > /etc/motd

  install "$VAULT_BINARY" "$VAULT_VERSION"
  generate_vault_config "$VAULT_PATH" \
    "$VAULT_USER" \
    "$VAULT_AUTO_JOIN_TAG_KEY" "$VAULT_AUTO_JOIN_TAG_VALUE"

  systemctl enable vault
  systemctl start vault

  %{if skip_init == true }
    log_info "Skipping vault setup"
  %{else}
    for n in {1..60}; do
      vault_status=$(curl -s http://localhost:8200/v1/sys/health)
      if [ -n "$(echo "$vault_status" | jq -r '.initialized')" ]; then
        echo "Vault Status:"
        echo "$vault_status" | jq "."
        break
      fi
      echo "Waiting for Vault listener to start on localhost:8200. Retry $n out of 60"
      sleep 5
    done

    # Only need to init one instance, others use auto_join
    if [[ "$VAULT_INIT" == "true" ]]; then
      vault_autounseal_init "localhost" "$VAULT_PATH/init_out.json"
      aws s3 cp "$VAULT_PATH/init_out.json" "s3://$SETUP_BUCKET/$VAULT_AUTO_JOIN_TAG_VALUE/init.json"
    else
      # Wait until lead election is complete, then fetch init output
      # This ensures leader's latest init output is retrieved from S3
      vault_wait_for_leader_election "localhost"
      aws s3 cp "s3://$SETUP_BUCKET/$VAULT_AUTO_JOIN_TAG_VALUE/init.json" "/home/ubuntu/init_out.json"

    fi
  %{ endif ~}

  %{if additional_setup != null ~}
    ${additional_setup}
  %{ endif ~}

}

main $@
