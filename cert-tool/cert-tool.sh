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
# ARO_API_IP
# ARO_API_URL
# ARO_INGRESS_IP
# ARO_INGRESS_URL
# ARO_USERNAME
# ARO_PASSWORD
#
# KEY_PEM   - acme_certificate.cluster_cert.private_key_pem
# CERT_PEM  - acme_certificate.cluster_cert.certificate_pem

# v0.1 Yerzhan Beisembayev ybeisemb@redhat.com Yerzhan.Beisembayev@dh.com

# track the state of the process to be able to report cluster state if error occur
STATE=0

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
    printf '%s\n' "$1"
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

    cd "${orig_cwd:-/}"  || cd

    if [[ $# -ne 0 ]]; then
        if [[ ${2} -ne 0 ]]; then
            printf 'ERROR: '
        fi
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

    if [[ ${STATE} -ne 0 ]]; then
        echo "WARNING: Operation failed to complete successfully - Cluster can be in a degraded state"
    fi

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
        ARO_API_IP       - ARO API IP Address
        ARO_API_URL      - ARO API URL
        ARO_INGRESS_IP   - ARO Ingress IP Address
        ARO_INGRESS_URL  - ARO Ingress Name (Optional - ARO_API_URL can be used to construct it)
        ARO_USERNAME     - ARO Cluster Admin User Name
        ARO_PASSWORD     - ARO Cluster Admin User Password

        CERT_PEM         - Certificate content in PEM format
        KEY_PEM          - Key content in PEM format

        OCP_VERSION      - OCP cli version to use (Optional - 4.7 is default)
        FORCE            - Overwrite certs if already present (optional)
EOF
}

function script_init() {
    # Useful paths
    readonly orig_cwd="$PWD"
    readonly script_path="${BASH_SOURCE[1]}"
    readonly script_dir="$(dirname "$script_path")"
    readonly script_name="$(basename "$script_path")"
    readonly script_params="$*"

    cd "$HOME" || cd

    # Secret name - to be used to determine if certificates already loaded
    OCP_SECRET="tf-certs"
    if [[ ${FORCE} =~ ^1|yes|true$ ]]; then
        FORCE=true
    else
        FORCE=false
    fi

    #Local file names
    readonly caroot_filename=${HOME}/caroot.pem
    readonly cert_filename=${HOME}/cert.pem
    readonly key_filename=${HOME}/key.pem

    # Load arguments from environment variables
    if [[ -z ${ARO_API_IP} ]]; then
        script_usage
        script_exit "ARO_API_IP is not provided" 1
    fi
    if [[ -z ${ARO_API_URL} ]]; then
        script_usage
        script_exit "ARO_API_URL is not provided" 1
    fi
    if [[ -z ${ARO_INGRESS_IP} ]]; then
        script_usage
        script_exit "ARO_INGRESS_IP is not provided" 1
    fi
    if [[ -z ${ARO_INGRESS_URL} ]]; then
        script_output "ARO_INGRESS_URL is not provided - will try to create one from ARO_API_URL: ${ARO_API_URL}"
        ARO_INGRESS_URL="apps.${ARO_API_URL#*.}"
        script_output "ARO_INGRESS_URL= ${ARO_INGRESS_URL}"
    fi
    if [[ -z ${ARO_USERNAME} ]]; then
        script_usage
        script_exit "ARO_USERNAME is not provided" 1
    fi
    if [[ -z ${ARO_PASSWORD} ]]; then
        script_usage
        script_exit "ARO_PASSWORD is not provided" 1
    fi
    if [[ -z ${KEY_PEM} ]]; then
        script_usage
        script_exit "KEY_PEM is not provided" 1
    fi
    if [[ -z ${CERT_PEM} ]]; then
        script_usage
        script_exit "CERT_PEM is not provided" 1
    fi

    # Download and extract OCP oc cli tool
    local oc_version="${OCP_VERSION:-4.7}"
    local oc_url="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable-${oc_version}/openshift-client-linux.tar.gz"

    curl -s -L "${oc_url}" --output openshift-client-linux.tar.gz
    tar xzvf openshift-client-linux.tar.gz

    # Download and extract Azure az tool
    rpm --import https://packages.microsoft.com/keys/microsoft.asc
    cat << EOF > /etc/yum.repos.d/azure-cli.repo
[azure-cli]
name=Azure CLI
baseurl=https://packages.microsoft.com/yumrepos/azure-cli
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
yum install -y python3 azure-cli which openssl

    # Set tools vars
    if [[ -x "/usr/bin/oc" ]]; then
        oc_cmd="/usr/bin/oc"
    elif [[ -x "/usr/local/bin/oc" ]]; then
        oc_cmd="/usr/local/bin/oc"
    elif [[ -x "./oc" ]]; then
        oc_cmd="./oc"
    else
        oc_cmd=$(which oc)
    fi

    if [[ -x "/usr/bin/az" ]]; then
        az_cmd="/usr/bin/az"
    elif [[ -x "/usr/local/bin/az" ]]; then
        az_cmd="/usr/local/bin/az"
    elif [[ -x "./az" ]]; then
        az_cmd="./az"
    else
        az_cmd=$(which az)
    fi

    if [[ -x "/usr/bin/openssl" ]]; then
        openssl_cmd="/usr/bin/openssl"
    elif [[ -x "/usr/local/bin/openssl" ]]; then
        openssl_cmd="/usr/local/bin/openssl"
    elif [[ -x "./openssl" ]]; then
        openssl_cmd="./openssl"
    else
        openssl_cmd=$(which openssl)
    fi

    # host name overrides - TBD
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
                script_usage
                script_exit "Command line parameters will be ignored - all data should be passed via environment variables" 2
                ;;
        esac
    done
}


# DESC: OCP Login
# ARGS: $1 - Cluster API endpoint
# $2 - Login username
# $3 - Login password
# OUTS: None if successful, Error text otherwise
function ocp_login() {

    ${oc_cmd} login --insecure-skip-tls-verify --server="${1}" --username="${2}" --password="${3}"

}


# DESC: Azure Login
# ARGS: $1 - Client ID
# $2 - Client Secret
# $3 - Tenant ID
# OUTS: None if successful, Error text otherwise
function az_login() {

    ${az_cmd} login --allow-no-subscriptions --service-principal --username="${1}" --password="${2}" --tenant="${3}"

}

# DESC: Patch Root CA in proxy/cluster
# ARGS: $1 - config map name
# $2 - CA certificate file name
# OUTS: None if successful, Error text otherwise
function patch_root_ca() {
    local c_output=""
    local replace="${FORCE:-false}"

    # Check if already present
    c_output=$(${oc_cmd} get proxy/cluster -o jsonpath='{.spec.trustedCA.name}')
    if [[ -z ${c_output} || ${c_output} != "${1}" ]]; then
        replace=true
    fi

    # Replace
    if [[ ${replace} != true ]]; then
        script_output "Root CA already present in proxy/cluster - skipping. Use FORCE=true environment variable to override"
    else
        ${oc_cmd} create configmap "${1}" --from-file=ca-bundle.crt="${2}" -n openshift-config
        ${oc_cmd} patch proxy/cluster --type=merge --patch='{"spec":{"trustedCA":{"name":"'"${1}"'"}}}'
    fi
}


# DESC: Patch ingress controller certificate
# ARGS: $1 - secret name
# $2 - certificate file name
# $3 - private key file name
# OUTS: None if successful, Error text otherwise
function patch_ingress_cert() {
    local c_output=""
    local replace="${FORCE:-false}"

    # Check if already present
    c_output=$(${oc_cmd} get ingresscontroller.operator default -n openshift-ingress-operator -o jsonpath='{.spec.defaultCertificate.name}')
    if [[ -z ${c_output} || ${c_output} != "${1}" ]]; then
        replace=true
    fi

    if [[ ${replace} != true ]]; then
        script_output "Certificate already present in ingress controller - skipping. Use FORCE=true environment variable to override"
    else
        ${oc_cmd} create secret tls "${1}" --cert="${2}" --key="${3}" -n openshift-ingress
        ${oc_cmd} patch ingresscontroller.operator default --type=merge --patch='{"spec":{"defaultCertificate":{"name":"'"${1}"'"}}}' -n openshift-ingress-operator
    fi
}


# DESC: Patch API server certificate
# ARGS: $1 - secret name
# $2 - certificate file name
# $3 - private key file name
# $4 - Api FQDN
# OUTS: None if successful, Error text otherwise
function patch_api_cert() {
    local c_output=""
    local replace="${FORCE:-false}"

    # Check if already present
    c_output=$(${oc_cmd} get apiserver cluster -o jsonpath='{.spec.servingCerts.namedCertificates[?(@.names[0]=="'"${4}"'")].servingCertificate.name}')
    if [[ -z ${c_output} || ${c_output} != "${1}" ]]; then
        replace=true
    fi

    if [[ ${replace} != true ]]; then
        script_output "Certificate already present in API Server - skipping. Use FORCE=true environment variable to override"
    else
        ${oc_cmd} create secret tls "${1}" --cert="${2}" --key="${3}" -n openshift-config
        ${oc_cmd} patch apiserver cluster --type=merge --patch='{"spec":{"servingCerts": {"namedCertificates":[{"names": ["'"${4}"'"],"servingCertificate": {"name": "'"${1}"'"}}]}}}'
    fi
}


# DESC: Load certificate and key
# ARGS: none
# OUTS: None if successful, Error text otherwise
function load_certs() {

    # Load key and cert from environment variables - fix new lines in process
    echo "${KEY_PEM}" | sed 's/\\n/\n/g' > "${key_filename}"

    echo "${CERT_PEM}" | sed 's/\\n/\n/g' > "${cert_filename}"

    # Validate that certificate matches the key
    c_cert_mod=$(${openssl_cmd} x509 -modulus -noout -in "${cert_filename}" | ${openssl_cmd} md5)
    c_key_mod=$(${openssl_cmd} rsa -modulus -noout -in "${key_filename}" | ${openssl_cmd} md5)

    if [[ -z ${c_cert_mod} ]]; then
        script_exit "Failed to calculate certificate modulus" 2
    fi

    if [[ -z ${c_key_mod} ]]; then
        script_exit "Failed to calculate key modulus" 2
    fi

    if [[ ${c_key_mod} != "${c_cert_mod}" ]]; then
        script_exit "Certificate and Key does not match" 2
    fi
}


# DESC: Main control flow
# ARGS: $@ (optional): Arguments provided to the script
# OUTS: None
function main() {
    trap script_trap_err ERR
    trap script_trap_exit EXIT

    parse_params "$@"
    script_init "$@"

    # Load certificate and key
    script_output "Attempting to load certificate and a key"
    load_certs

    # Log in to ARO Cluster
    script_output "Attempting to log in to OCP Cluster"
    ocp_login "${ARO_API_URL}:6443" "${ARO_USERNAME}" "${ARO_PASSWORD}"

#    script_output "Attempting to log  in to Azure"
#    # Log in to Azure
#    az_login "${AZ_CLIENT_ID}" "${AZ_CLIENT_SECRET}" "${AZ_TENANT_ID}"

    # Patch Root CA cert
#    script_output "Attempting to patch Root CA"
#    patch_root_ca "${OCP_SECRET}" "${caroot_filename}"

    STATE=1
    # Patch Ingress cert
    script_output "Attempting to replace iingress certificate"
    patch_ingress_cert "${OCP_SECRET}" "${cert_filename}" "${key_filename}"

    STATE=2
    # Patch API cert
    script_output "Attempting to replace API server certificate"
    patch_api_cert "${OCP_SECRET}" "${cert_filename}" "${key_filename}" "${ARO_API_URL}"

    STATE=3
    # Long sleep for debugging - remove when going prod
    sleep 10000

    script_exit "Command completed successfully" 0
}



# Invoke main with args if not sourced
if ! (return 0 2> /dev/null); then
    main "$@"
fi
