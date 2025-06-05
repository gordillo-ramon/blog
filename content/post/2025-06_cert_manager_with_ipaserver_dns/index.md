---
title: 'Using cert-manager with ipa-server and ACME with DNS challenge'
date: '2025-06-05'
tags: [

    "Kubernetes",
    "Certificates",
]
categories: [
    "security",
]
---
This article shows how to use a private [ipa-server](https://www.freeipa.org/page/Main_Page) to provide certificates to kubernetes applications.

There is a very good post on the subject about [how to configure Identity Manager (ipa-server in RHEL) by Josep Font](https://www.redhat.com/en/blog/managing-automatic-certificate-management-environment-acme-identity-management-idm). A developer subscription for RHEL at no cost can be used, or CentOS Stream can be used for playing with the latest `ipa-server` version.

Another really [good post](https://developers.redhat.com/articles/2024/12/17/automatic-certificate-issuing-idm-and-cert-manager-operator-openshift) about Cert-manager integration is done by another two colleagues, Jose Angel de Bustos and Jorge Tudela. They configure the HTTP-01 challenge using an Ingress Controller to expose the web needed for it. Although it is a very straightforward alternative, I do like to use the DNS-01 challenge best.

> **Note:** For more information about ACME protocol and its challenges, see the original [RFC8555](https://www.rfc-editor.org/rfc/rfc8555#section-8) [Let's Encrypt ACME documentation](https://letsencrypt.org/docs/challenge-types/).

# Installation

First, we need an ipa server installed with dns server and acme configured. It can be done in two simple steps (on top of CentOS or registered RHEL):

- Package installation:
```bash
dnf install ipa-server ipa-server-dns bind-dyndb-ldap
```

- Installing ipa-server:
```bash
ipa-server-install --unattended --realm=<MYDOMAIN.COM> --domain=<mydomain.com> \
      --ds-password=<db_pass> --admin-password=<admin_pass> \
      --setup-dns --forwarder=<upstream_dns_server> --auto-reverse
```

- Configuring ACME:
```bash
ipa-acme-manage enable
```

- Checking if ACME is enabled:
```bash
ipa-acme-manage status
```

# Adding credentials for DNS-01

The IPA server with kerberos comes with [TSIG (Transaction SIGnatures)](https://www.rfc-editor.org/rfc/rfc8945.html) for authenticating DNS updates. However, it is not very usual that programs use Kerberos for those tasks, so we will use another algorithm. In our case, `hmac-sha512` is selected.

> **Tip:** For more background on TSIG and its use in DNS updates, see the [ISC BIND documentation](https://bind9.readthedocs.io/en/latest/chapter7.html#tsig-transaction-signatures).

Fortunately, there is a command that creates the key for us.

```bash
tsig-keygen -a hmac-sha512 update | tee -a /etc/named/ipa-ext.conf
```

The key is stored in an extension config file with name `update`. The update key file will be needed afterwards to test the server. And now we update the named configuration, and check that the new key is reloaded.

```bash
rndc reconfig
rndc tsig-list |grep bind |grep update
```

Should return something like

```bash
view "_bind"; type "static"; key "update";
```

Now, the update policy for the zone has to be updated, but for using ipa command, first a `kinit` command should get the kerberos ticket. 

> **Note:** If you are new to Kerberos, you can find more information in the [MIT Kerberos documentation](https://web.mit.edu/kerberos/krb5-latest/doc/user/user_commands/kinit.html).

```bash
echo <admin_pass> | kinit admin
export DNSZONE_UPDATE_POLICY=$(ipa dnszone-show <mydomain.com> --all | awk '/BIND update policy:/ { $1=""; print substr($0,2) }')
ipa dnszone-mod <mydomain.com> --update-policy="${DNSZONE_UPDATE_POLICY}; grant update subdomain <mydomain.com>.;"
```

Now we can test the acme server to get new certificates

# Client example with acme.sh

[Acme.sh](https://github.com/acmesh-official/acme.sh) is a very popular tool used to get certificates using ACME protocol.

> **More info:** The [acme.sh wiki](https://github.com/acmesh-official/acme.sh/wiki) contains many examples and advanced usage scenarios.

To test it, first the key file should be stored in the client:

```bash
tail -4 /etc/named/ipa-ext.conf > /tmp/update.key
export NSUPDATE_KEY=/tmp/update.key
```

Complete the `NSUPDATE_SERVER` with the ip of ipa server and the `ACME_SERVER` with `https://<ipa-server>:8443/acme/directory`

Then a new account should be created with the :

```bash
acme.sh --register-account --accountkeylength 2048 --force
```

With a result similar than:

```bash
[Mon Jun  2 08:01:17 PM CEST 2025] Registering account: https://<ipa-server>:8443/acme/directory
[Mon Jun  2 08:01:18 PM CEST 2025] Registered
```

And now, a new cert is required:

```bash
acme.sh --issue --dns dns_nsupdate -d <newrecord> --insecure --dnssleep 10 --keylength 2048
```

The insecure flag is only required for quick testing, in a prod environment CA flags should be used. 

Something like the following should be output:

```bash
[Wed Jun  4 09:29:58 PM CEST 2025] Using CA: https://<ipa-server>:8443/acme/directory
[Wed Jun  4 09:29:58 PM CEST 2025] Single domain='<newrecord>'
[Wed Jun  4 09:29:58 PM CEST 2025] Getting webroot for domain='<newrecord>'
[Wed Jun  4 09:29:58 PM CEST 2025] Adding TXT value: 1QH7pi9TiSxWM65DfgEZ4EZ1Ei0Irl4ihxAzyrzU-J0 for domain: _acme-challenge.<newrecord>
[Wed Jun  4 09:29:59 PM CEST 2025] adding _acme-challenge.<newrecord>. 60 in txt "1QH7pi9TiSxWM65DfgEZ4EZ1Ei0Irl4ihxAzyrzU-J0"
[Wed Jun  4 09:29:59 PM CEST 2025] The TXT record has been successfully added.
[Wed Jun  4 09:29:59 PM CEST 2025] Sleeping for 10 seconds to wait for the the TXT records to take effect
[Wed Jun  4 09:30:10 PM CEST 2025] Verifying: <newrecord>
[Wed Jun  4 09:30:10 PM CEST 2025] Processing. The CA is processing your order, please wait. (1/30)
[Wed Jun  4 09:30:13 PM CEST 2025] Success
[Wed Jun  4 09:30:13 PM CEST 2025] Removing DNS records.
[Wed Jun  4 09:30:13 PM CEST 2025] Removing txt: 1QH7pi9TiSxWM65DfgEZ4EZ1Ei0Irl4ihxAzyrzU-J0 for domain: _acme-challenge.<newrecord>
[Wed Jun  4 09:30:13 PM CEST 2025] removing _acme-challenge.<newrecord>. txt
[Wed Jun  4 09:30:13 PM CEST 2025] Successfully removed
[Wed Jun  4 09:30:13 PM CEST 2025] Verification finished, beginning signing.
[Wed Jun  4 09:30:13 PM CEST 2025] Let's finalize the order.
[Wed Jun  4 09:30:13 PM CEST 2025] Le_OrderFinalize='https://<ipa-server>/acme/v1/order/c6KsIdqfVr/finalize'
[Wed Jun  4 09:30:14 PM CEST 2025] Downloading cert.
[Wed Jun  4 09:30:14 PM CEST 2025] Le_LinkCert='https://<ipa-server>/acme/v1/cert/Tr-txFLHPAWkRigeHD_Taw'
[Wed Jun  4 09:30:14 PM CEST 2025] Cert success.
-----BEGIN CERTIFICATE-----
...
-----END CERTIFICATE-----
[Wed Jun  4 09:30:14 PM CEST 2025] Your cert is in: /home/rgordill/.acme.sh/<newrecord>/<newrecord>.cer
[Wed Jun  4 09:30:14 PM CEST 2025] Your cert key is in: /home/rgordill/.acme.sh/<newrecord>/<newrecord>.key
[Wed Jun  4 09:30:14 PM CEST 2025] The intermediate CA cert is in: /home/rgordill/.acme.sh/<newrecord>/ca.cer
[Wed Jun  4 09:30:14 PM CEST 2025] And the full-chain cert is in: /home/rgordill/.acme.sh/<newrecord>/fullchain.cer
```

# Client example with cert manager

[Cert Manager](https://cert-manager.io/) is a very popular operator in Kubernetes to provide certificates to workloads and ingress controllers.

> **Reference:** See the [cert-manager DNS01 documentation](https://cert-manager.io/docs/configuration/acme/dns01/) for more details on DNS challenge configuration.

To enable ACME with DNS01, we only need to configure an issuer (in our case, a cluster issuer) with the same params as we have used in `acme.sh`. The update key will be stored in a secret, but instead of the full file as we did in `acme.sh`, we need just the key value.

```yml
metadata:
  name: tsig-secret
  namespace: cert-manager
type: Opaque
stringData: 
  tsig-secret-key: <secret-key>
```

The other information (algorithm, key name, etc) would be under rfc2136 element:

```yml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: acme-issuer
  namespace: cert-manager
spec:
  acme:
    email: admin@<domain>
    server: https://<ipa-server>:8443/acme/directory
    privateKeySecretRef:
      name: acme-issuer-key
    skipTLSVerify: true
    solvers:
    - dns01:
        rfc2136:
          nameserver: <ipa-server>:53
          tsigKeyName: update
          tsigAlgorithm: HMACSHA512
          tsigSecretSecretRef:
            name: tsig-secret
            key: tsig-secret-key
```

When querying the object status, if everything is correct, something like this should exist.

```yml
...
status:
  acme:
    lastPrivateKeyHash: 1FmC/C2A4SYazMtmVG0MaaizFF4ZPeOGhLxRSAsKv90=
    lastRegisteredEmail: admin@<domain>
    uri: https://<ipa-server>:8443/acme/v1/acct/Tcm2uttrfYXyrNxtDFIFE4HK9C8r6lkvVF60eKt_NTc
  conditions:
  - lastTransitionTime: "2025-06-05T06:14:55Z"
    message: The ACME account was registered with the ACME server
    observedGeneration: 1
    reason: ACMEAccountRegistered
    status: "True"
    type: Ready
```

Then, we can try to get a sample certificate.

```yml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: www01
  namespace: cert-manager
spec:
  secretName: www01
  duration: 2160h # 90d
  renewBefore: 360h # 15d
  subject:
    organizations:
      - Org Name
  commonName: '<newrecord>'
  privateKey:
    algorithm: RSA
    encoding: PKCS1
    size: 2048
    rotationPolicy: Always
  usages:
    - server auth
    - client auth
  dnsNames:
    - <newrecord>
  issuerRef:
    name: acme-issuer
    kind: ClusterIssuer
```

And again, if everything is fine, something like the following would be in status:

> **Troubleshooting:** If the certificate is not issued, check the cert-manager logs and ensure the DNS records are being updated as expected. The [cert-manager troubleshooting guide](https://cert-manager.io/docs/troubleshooting/) can help diagnose common issues.

```yml
...
status:
  conditions:
  - lastTransitionTime: "2025-06-05T06:26:38Z"
    message: Certificate is up to date and has not expired
    observedGeneration: 1
    reason: Ready
    status: "True"
    type: Ready
  notAfter: "2025-09-03T06:26:38Z"
  notBefore: "2025-06-05T06:26:38Z"
  renewalTime: "2025-08-19T06:26:38Z"
  revision: 1
```

And a new secret would be in that namespace

```bash
kubectl get secret -n cert-manager www01 -o yaml
```

```yml
apiVersion: v1
data:
  tls.crt: <redacted>
  tls.key: <redacted>
kind: Secret
metadata:
  annotations:
    cert-manager.io/alt-names: <newrecord>
    cert-manager.io/certificate-name: www01
    cert-manager.io/common-name: <newrecord>
    cert-manager.io/ip-sans: ""
    cert-manager.io/issuer-group: ""
    cert-manager.io/issuer-kind: ClusterIssuer
    cert-manager.io/issuer-name: acme-issuer
    cert-manager.io/uri-sans: ""
  creationTimestamp: "2025-06-05T06:26:38Z"
  labels:
    controller.cert-manager.io/fao: "true"
  name: www01
  namespace: cert-manager
  resourceVersion: "3626"
  uid: ba434928-1167-403d-8ab5-72387ad6ce76
type: kubernetes.io/tls
```