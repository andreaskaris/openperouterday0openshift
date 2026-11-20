#!/bin/bash
# generate_machineconfigs.sh - Compile MachineConfig manifests from
# butane sources (openperouter-master/worker, dns, registry).
#
# Usage: generate_machineconfigs.sh <output_dir>
#
#   output_dir  Directory where the MachineConfig YAML files are written
#
# Requires: butane

set -euo pipefail

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRASDIR="$(cd "${SCRIPTDIR}/../extras" && pwd)"

output_dir="$1"
mkdir -p "${output_dir}"

if ! command -v butane &>/dev/null; then
    echo "ERROR: butane is required but not found. Install with: sudo dnf install butane"
    exit 1
fi

echo "==> Generating MachineConfig manifests into ${output_dir}..."
mkdir -p "${output_dir}"
# Remove manifests left by a previous run.
rm -f "${output_dir}"/*.yaml

# Compile every butane file.
for bu in "${SCRIPTDIR}"/*.bu; do
    name="$(basename "${bu}" .bu)"
    echo "  ${name}.bu"
    butane --strict --files-dir="${EXTRASDIR}" "${bu}" -o "${output_dir}/${name}.yaml"
done

echo "  set-cluster-mtu.yaml"
cp "${EXTRASDIR}/config/set-cluster-mtu.yaml" "${output_dir}/set-cluster-mtu.yaml"

if [[ -v SSH_PUB_KEY ]]; then
  for role in master worker; do
    echo "  ${role}-ssh.yaml"
    cat <<EOF > "${output_dir}/${role}-ssh.yaml"
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: ${role}
  name: 99-${role}-ssh
spec:
  config:
    ignition:
      version: 3.1.0
    passwd:
      users:
      - name: core
        sshAuthorizedKeys:
        - ${SSH_PUB_KEY}
EOF
  done
fi

echo "==> MachineConfig manifests generated."
