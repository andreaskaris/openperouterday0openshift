Preparation:
==============================

> Note: We run everything as `root`. Additional steps are needed if you are using a local user.

i. Install CentOS 9 (or RHEL 9) on your server. CentOS 10 / RHEL 10 are not compatible with dev-scripts. Select
`Virtualization Host` under `Software Selection` during the installation process. Register the system during or after
installation. The partition holding `/opt` will need a lot of disk space (minimum for the dev-scripts is 80 GB, plus
additional space for the appliance image, etc.), so aim for 500 GB to 1 TB. Update the system after installation.

```
yum update -y
reboot
```

Save the secret obtained from https://cloud.redhat.com/openshift/install/pull-secret to `/opt/pull_secret.json`.

iv. Install tools and prerequisites:

```
yum install -y butane coreos-installer tmux podman pip go ansible-core
```

Deploy:
==============================

Start a `tmux`. Inside the `tmux` session, run the following steps or run `redeploy.sh` (see below).

Build the appliance according to https://github.com/openshift-kni/openperouterday0openshift/blob/main/README.md:

```
pushd srv6fullconfig/
SSH_PUB_KEY="$(cat ~/.ssh/id_rsa.pub)" appliance/generate_appliance.sh /opt/pull_secret.json
SSH_PUB_KEY="$(cat ~/.ssh/id_rsa.pub)" configimage/generate_config_image.sh /opt/pull_secret.json
popd
```

> Note: See `Full cleanup` for cleanup instructions.

Deploy the virtual environment:

```
./site/vmlab/lab-up.sh ./srv6fullconfig/appliance/appliance.iso ./srv6fullconfig/configimage/configimage/agentconfig.noarch.iso
```

Monitoring / verification:
==============================

The installer is configured to use the VRF for bootstrap-complete and install-complete, so you should be able to follow the install
status without issues.

In case you need to trigger the `wait-for` command manually, you can run:

```
ip vrf exec red ./srv6fullconfig/appliance/cache/4.22.3-x86_64/openshift-install agent wait-for install-complete --dir ./ocp/sno-lab/configimage --log-level=debug
```

Verify the OpenShift cluster status with:

```
export KUBECONFIG=$(pwd)/srv6fullconfig/configimage/configimage/auth/kubeconfig
ip vrf exec red oc get nodes
ip vrf exec red oc get clusterversion
ip vrf exec red oc get co
```

You can verify the overlay status from the `FRR` pod:

```
for cmd in "show isis neighbor" "show bgp summary" "show bgp ipv4 vpn" "show segment-routing srv6 locator"; do podman exec -it externalfrr vtysh -c "$cmd"; done
``` 

And on the nodes themselves:

```
ssh core@192.168.150.20 # for master-0
sudo -i
for cmd in "show isis neighbor" "show bgp summary" "show bgp ipv4 vpn" "show segment-routing srv6 locator"; do podman exec -it frr vtysh -c "$cmd"; done
```

Full cleanup:
==============================

To do a full cleanup (contrary to a partial cleanup that still leaves the registry and virtual machines, etc.), run:

```
./site/vmlab/lab-down.sh
```

Remove entries from `/etc/hosts`:

```
vim /etc/hosts
```

In order to clean the appliance image for a full rebuild (e.g. if you change images and need the change
to be reflected in the mirror):

```
rm -rf ./srv6fullconfig/appliance/cache
```
