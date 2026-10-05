# Guides

## Kubeconfig credentials in KeePassXC

A kubeconfig usually holds its credentials in plain text: a bearer `token`,
or a client certificate with its private key in `client-key-data`. Whatever
can read `~/.kube/config` (a backup, a sync tool, a screen share, a
compromised tool) can use your clusters. kubectl can instead run a
*credential plugin* each time it needs credentials. With the plugin below,
the kubeconfig keeps only the cluster addresses and a command, and the
secrets live in KeePassXC:

- The kubeconfig holds no secrets, so copies and backups of it give nobody
  access.
- kubectl gets each secret from KeePassXC when it runs. With **Confirm when
  passwords are retrieved by clients** on (the default), you approve every
  use; a locked database asks to be unlocked first.
- The secret goes from KeePassXC to kubectl through pipes and is never
  written to disk.

This doesn't protect against malware that runs as you while you approve its
requests; see [Security model](README.md#security-model). You need
kpxc-secret-service enabled, `secret-tool` (package `libsecret`), and a
KeePassXC database that exposes a group.

### 1. Install the plugin

Save this as `~/.local/bin/kpxc-kube-credential` and make it executable
(`chmod 755 ~/.local/bin/kpxc-kube-credential`):

```python
#!/usr/bin/python3 -sP
"""kubectl credential plugin: fetch a kubeconfig user's secret from KeePassXC.

usage: kpxc-kube-credential USER             bearer token stored as `kubeconfig USER`
       kpxc-kube-credential USER CERT_FILE   client key stored as `kubeconfig USER`,
                                             its certificate in CERT_FILE
"""
import json
import subprocess
import sys


def main(user, cert_file=None):
    lookup = subprocess.run(["kpxc-secret", "lookup", "kubeconfig", user],
                            stdout=subprocess.PIPE, check=False)
    if lookup.returncode != 0 or not lookup.stdout:
        sys.exit(f"kpxc-kube-credential: KeePassXC returned no secret for `kubeconfig {user}` "
                 "(not stored, database locked, or access denied)")
    secret = lookup.stdout.decode()
    if cert_file is None:
        status = {"token": secret.strip()}
    else:
        with open(cert_file) as f:
            status = {"clientCertificateData": f.read(), "clientKeyData": secret}
    json.dump({"apiVersion": "client.authentication.k8s.io/v1",
               "kind": "ExecCredential", "status": status}, sys.stdout)


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    main(*sys.argv[1:])
```

Each secret is a KeePassXC entry with the attribute `kubeconfig` set to the
kubeconfig user's name; the secret is the entry's password.

### 2. Move a token

Pick the user from `kubectl config get-users`:

```sh
user=prod-admin
kubectl config view --raw -o jsonpath="{.users[?(@.name==\"$user\")].user.token}" |
    kpxc-secret store --label="kubeconfig $user" kubeconfig "$user"
kpxc-secret lookup kubeconfig "$user" >/dev/null &&
    kubectl config unset "users.$user.token"
kubectl config set-credentials "$user" \
    --exec-api-version=client.authentication.k8s.io/v1 \
    --exec-command="$HOME/.local/bin/kpxc-kube-credential" --exec-arg="$user" \
    --exec-interactive-mode=Never
kubectl get --raw /version
```

The `lookup` line makes sure KeePassXC has the token before it leaves the
kubeconfig. The last command should make KeePassXC ask whether
`secret-tool` may read `kubeconfig prod-admin`. kubectl may write the
command's path relative to the kubeconfig's directory, which works too.

For a token that isn't in a kubeconfig yet, run
`kpxc-secret store --label="kubeconfig $user" kubeconfig "$user"` and paste
it at the prompt: it isn't echoed and stays out of your shell history. Or
pipe it in, e.g. `kubectl create token SERVICE_ACCOUNT --duration=8h | kpxc-secret store …`.
Storing again with the same attributes replaces the secret, which is how you
rotate it.

### 3. Move a client certificate's key

Only the private key is secret. It goes to KeePassXC, the certificate to a
file:

```sh
user=prod-admin
kubectl config view --raw -o jsonpath="{.users[?(@.name==\"$user\")].user.client-key-data}" |
    base64 -d | kpxc-secret store --label="kubeconfig $user" kubeconfig "$user"
kubectl config view --raw -o jsonpath="{.users[?(@.name==\"$user\")].user.client-certificate-data}" |
    base64 -d >"$HOME/.kube/$user.crt"
kpxc-secret lookup kubeconfig "$user" >/dev/null &&
    kubectl config unset "users.$user.client-key-data" &&
    kubectl config unset "users.$user.client-certificate-data"
kubectl config set-credentials "$user" \
    --exec-api-version=client.authentication.k8s.io/v1 \
    --exec-command="$HOME/.local/bin/kpxc-kube-credential" \
    --exec-arg="$user" --exec-arg="$HOME/.kube/$user.crt" \
    --exec-interactive-mode=Never
kubectl get --raw /version
```

If the kubeconfig points at key and certificate files (`client-key:`,
`client-certificate:`) instead, store the key with
`kpxc-secret store … <KEY_FILE`, unset `users.$user.client-key` and
`users.$user.client-certificate`, and delete the key file.

`kubectl config unset` can't address user names that contain dots; edit
those users in the file directly.

### 4. Clean up

```sh
kubectl config view --raw | grep -E 'token|client-key|password'   # prints nothing
```

Also look at the other files in `$KUBECONFIG` and `~/.kube`, old copies and
backups, and your shell history. Then **rotate the credentials** you moved:
they were on disk in plain text, so copies may exist that you can't find.
Issue new ones and store only those in KeePassXC.

### Day to day

- **Prompts:** every `kubectl` command asks KeePassXC once. "Remember" only
  lasts while the requesting process runs, and `secret-tool` exits after
  each lookup, so approving one command never approves the next.
  Long-running tools built on client-go, like k9s, usually ask only once
  per start, since they keep the credential in memory.
- **Locking:** when the screen locks, KeePassXC locks its databases (see the
  README), and the next `kubectl` asks you to unlock first.
- **Elsewhere:** over SSH, the prompt appears on your desktop. Scripts and
  CI have nobody to answer it; give them their own credentials.
- **What clients see:** any Secret Service client can list entry titles and
  attributes without asking. Only the secret itself needs your approval, so
  keep secrets out of names. KeePassXC exposes one group per database: keep
  machine credentials like these in it, and your other passwords outside.
- **By hand in KeePassXC:** put the secret in the password field and add the
  additional attribute `kubeconfig` with the user's name. Leave it
  unprotected; KeePassXC doesn't expose protected attributes.
- **Don't** pass secrets on the command line (`kubectl --token=…`) or in
  `--exec-env`: other processes can read arguments and environments.

Cloud providers' plugins (`aws eks get-token`, `gke-gcloud-auth-plugin`,
`kubelogin`) and OIDC logins already keep long-lived secrets out of the
kubeconfig and manage their own; this guide is for static tokens and client
certificates.
