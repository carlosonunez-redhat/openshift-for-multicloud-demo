## OpenShift Multicloud Demo

This README will walk you through demonstrating how OpenShift, ACM and
Portworx simplifies multi-cloud disaster recovery by failing over a simple
application between two clusters in separate cloud providers.

Contact anyone in the [MAINTAINERS](./MAINTAINERS) file if you have questions
or need help!

### 🛫 Deploy the Environment

#### Clone this repository!

```sh
git clone git@gitlab.consulting.redhat.com/cnunez/openshift-multicloud-demo
./demo
```

#### Create a config file

[config.yaml](./config.yaml) configures everything about the clusters, storage
and application used for this demo.

This repo uses [sops](https://github.com/getsops/sops) to encrypt sensitive
values in this file, like kubeconfigs.

##### Non-maintainers

1. Open `config.yaml` in an editor.
2. Remove the `sops` line towards the bottom of the file and anything underneath
   it.
3. Make the following changes:
    - Set `kubeconfigs.aws` to the kubeconfig for the OCP cluster in AWS.
    - Set `kubeconfigs.gcp` to the kubeconfig for the OCP cluster in GCP.

##### Maintainers and contributors

1. Request access to the "na-tsi-fsi-multi-cloud-working-group-secrets" Rover
   group in the #na-ts-fsi-multi-cloud-working-group Slack channel.
2. [Log into BitWarden](https://vault.bitwarden.com) and search for the
   "OpenShift Multicloud Demo GPG Key" secret in the "Red Hat, Inc." vault. Copy
   the data in the "GPG Private Key" field.
3. In a terminal, type `echo `, paste in the data you copied, then add ` |
   base64 -d | gpg --import` afterwards.

   You'll be asked to enter a passphrase. Copy the password in the Bitwarden
   secret and paste it in here.

   Once done, you should see something that looks like the below:

   ```
   gpg: key 7C1D2B09863AA317: public key "na-ts-fsi-multi-cloud-working-group@slack-channel.redhat.com" imported
    gpg: key 7C1D2B09863AA317: secret key imported
    gpg: Total number processed: 1
    gpg:               imported: 1
    gpg:       secret keys read: 1
    gpg:   secret keys imported: 1
   ```
4. Confirm that you can read the config file:

   ```
   sops --decrypt config.yaml
   ```

### 📝 Perform the demo

_Work in progress._

### 🛬 Tear everything down!

_Work in progress._
