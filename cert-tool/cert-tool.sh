#!/usr/bin/env bash

# Script to implement a workaround for a ARO certificate issue
# ARO provisioning process does not create CA certificate for API and Ingress end points when custom domain name is used
# If private demployment option is used - terraform agents can't access ARO cluster directly to deply CA certs instead of self-signed one's
#
# Script executes all steps required to replace certificates in ARO cluster including the following:
# - Deploy OpenShift oc cli tool
# - Deploy Azure az tool
# - Add api and oauth names to /etc/hosts file pointing to private IP addresses of the ARO cluster
# - Retrieve CA root and api/ingress certificates from the Keyvault
# - Login to the ARO cluster using credentials provided
# - Run required oc patch commands to add CA root certificate as well as replace API and Ingress certificates
#
# Script is indended to be run in Azure container instance deployed in the same subnet as ARO cluster
# Docker hub CentOS image is used
#
# The following parameters should be provided to the script via environment variables:
#
# ARO_API_ADDRESS
# ARO_API_HOSTNAME
# ARO_APPS_ADDRESS
# ARO_APPS_HOSTNAME
# ARO_USERNAME
# ARO_PASSWORD
#
# AZ_* - TBD: Azure connectivity parameters
# AZ_* - TBD: Keyvault parameters

# v0.1 Yerzhan Beisembayev ybeisemb@redhat.com Yerzhan.Beisembayev@dh.com



# Enable xtrace if the DEBUG environment variable is set
if [[ ${DEBUG-} =~ ^1|yes|true$ ]]; then
    set -o xtrace       # Trace the execution of the script (debug)
fi

# Enable errtrace or the error trap handler will not work as expected
set -o errtrace         # Ensure the error trap handler is inherited



# DESC: Script output (currently just echo to stdout)
# ARGS: $1 - Text for output
# OUTS: None
script_output () {
    echo "$1"
}


# DESC: Exit script with the given message
# ARGS: $1 (required): Message to print on exit
#       $2 (optional): Exit code (defaults to 0)
# OUTS: None
# NOTE: The convention used in this script for exit codes is:
#       0: Normal exit
#       1: Abnormal exit due to external error
#       2: Abnormal exit due to script error
function script_exit() {
    # Clear exit trap to prevent possible recursion
    trap - EXIT

    #Clean up logic
    #Clean up records in /etc/hosts - just in case this script is used anywhere else from Azure container instance

    cd "${orig_cwd:-/}"

    if [[ $# -ne 0 ]]; then
        printf '%s\n' "$1"
        exit "${2:-0}"
    fi

    script_exit 'No exit reason provided' 2
}


# DESC: Handler for unexpected exit
# ARGS: None
# OUTS: None
function script_trap_exit() {
    # Clear exit trap to prevent possible recursion
    trap - EXIT

    script_exit 'Unexpected exit occured!' 2
}


# DESC: Handler for unexpected errors
# ARGS: None
# OUTS: None
function script_trap_err() {
    # Clear exit trap to prevent possible recursion
    trap - ERR

    # Determine the exit code
    local exit_code=1
    if [[ ${1-} =~ ^[0-9]+$ ]]; then
        exit_code="$1"
    fi

    script_exit 'Error caught by the trap!' "$exit_code"
}


# DESC: Usage help
# ARGS: None
# OUTS: None
script_usage () {
    cat << EOF
Usage:
    -h|--help		Displays this help
    *               All parameters should be passed via environment variables
        ARO_API_ADDRESS
        ARO_API_HOSTNAME
        ARO_APPS_ADDRESS
        ARO_APPS_HOSTNAME
        ARO_USERNAME
        ARO_PASSWORD

        AZ_* - TBD: Azure connectivity parameters
        AZ_* - TBD: Keyvault parameters

        OCP_VERSION - OCP cli version to use (4.7 is default)
EOF
}

function script_init() {
    # Useful paths
    readonly orig_cwd="$PWD"
    readonly script_path="${BASH_SOURCE[1]}"
    readonly script_dir="$(dirname "$script_path")"
    readonly script_name="$(basename "$script_path")"
    readonly script_params="$*"

    cd $HOME

    # Load arguments from environment variables
    if [[ -z ${ARO_API_ADDRESS} ]]; then
        script_usage
        script_exit "ARO_API_ADDRESS is not provided" 1
    fi
    if [[ -z ${ARO_API_HOSTNAME} ]]; then
        script_usage
        script_exit "ARO_API_HOSTNAME is not provided" 1
    fi
    if [[ -z ${ARO_APPS_ADDRESS} ]]; then
        script_usage
        script_exit "ARO_APPS_ADDRESS is not provided" 1
    fi
    if [[ -z ${ARO_APPS_HOSTNAME} ]]; then
        script_usage
        script_exit "ARO_APPS_HOSTNAME is not provided" 1
    fi
    if [[ -z ${ARO_USERNAME} ]]; then
        script_usage
        script_exit "ARO_USERNAME is not provided" 1
    fi
    if [[ -z ${ARO_PASSWORD} ]]; then
        script_usage
        script_exit "ARO_PASSWORD is not provided" 1
    fi

    # Download and extract OCP oc cli tool
    local oc_version="${OCP_VERSION:-4.7}"
    local oc_url="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable-${oc_version}/openshift-client-linux.tar.gz"

    curl -s -L "${oc_url}" --output openshift-client-linux.tar.gz

    # Download and extract Azure az tool
    yum install -y python3 >/dev/null 2>&1
    curl -s -L "https://aka.ms/InstallAzureCli" | bash

    sleep 10000

    # Set tools vars
    oc_cmd=$(which oc 2>&1)
    if [[ $? -ne 0 ]]; then
        if [[ -x "/usr/bin/oc" ]]; then
            oc_cmd="/usr/bin/oc"
        elif [[ -x "/usr/local/bin/oc" ]]; then
            oc_cmd="/usr/local/bin/oc"
        elif [[ -x "./oc" ]]; then
            oc_cmd="./oc"
        else
            script_exit "OCP command line utility (oc) is not found. Install it before continuing" 1
        fi
    fi

    az_cmd=$(which az 2>&1)
    if [[ $? -ne 0 ]]; then
        if [[ -x "/usr/bin/az" ]]; then
            az_cmd="/usr/bin/az"
        elif [[ -x "/usr/local/bin/az" ]]; then
            az_cmd="/usr/local/bin/az"
        elif [[ -x "./az" ]]; then
            az_cmd="./az"
        else
            script_exit "Azure command line utility (az) is not found. Install it before continuing" 1
        fi
    fi
}


# DESC: Parameter parser
# ARGS: $@ (optional): Arguments provided to the script
# OUTS: Variables indicating command-line parameters and options
function parse_params() {
    local param
    while [[ $# -gt 0 ]]; do
        param="$1"
        shift
        case $param in
            -h | --help)
                script_usage
                script_exit ""
                ;;
            *)
                script_exit "Invalid parameter was provided: $param" 1
                ;;
        esac
    done
}


# DESC: OCP Login
# ARGS: $1 - Cluster API endpoint
# $2 - Login token or username
# $3 - Should not be provided if second parameter is token, otherwise - password
# OUTS: None if successful, Error text otherwise
# EXIT: 0 - success, 1 - error
function ocp_login() {
    local c_output=""
    local c_result=0

    if [[ -z $3 ]]; then
        c_output=$(${oc_cmd} login --token=$2 --server=$1 2>&1)
    else
        c_output=$(${oc_cmd} login --username=$2 --password=$3 --server=$1 2>&1)
    fi
    c_result=$?
    if [[ ${c_result} -ne 0 ]]; then
        echo "Attempt to login to OCP Cluster failed: ${c_output}"
    fi
    exit ${c_result}
}


# DESC: Main control flow
# ARGS: $@ (optional): Arguments provided to the script
# OUTS: None
function main() {
    trap script_trap_err ERR
    trap script_trap_exit EXIT

    script_init "$@"
    parse_params "$@"

    # Log in to ARO Cluster

    # Log in to Azure

    # Retrieve certificates from the Keyvault

    # Patch Root CA cert

    # Patch API cert

    # Patch Ingress cert

    sleep 10000

    script_exit "Command completed successfully" 0
}



# Invoke main with args if not sourced
if ! (return 0 2> /dev/null); then
    main "$@"
fi
