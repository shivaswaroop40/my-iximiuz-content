#!/usr/bin/env python3
"""A minimal signer for PodCertificateRequest.

The identity in the certificate is not taken from the request's public key
blob. It comes from the spec fields the API server filled in and vouches for
-- the pod, its service account, and the node it runs on -- which is the whole
reason this API exists instead of a plain CertificateSigningRequest.
"""

import base64
import datetime
import json
import os
import subprocess
import sys
import time

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization

SIGNER_NAME = os.environ.get("SIGNER_NAME", "pki.example.com/workload-identity")
CA_DIR = os.environ.get("CA_DIR", "/etc/pod-identity-signer")
TRUST_DOMAIN = os.environ.get("TRUST_DOMAIN", "cluster.local")
LIFETIME = int(os.environ.get("LIFETIME_SECONDS", "3600"))
POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "3"))

os.environ.setdefault("KUBECONFIG", "/etc/kubernetes/admin.conf")


def log(msg):
    print(msg, flush=True)


def kubectl(*args, check=True):
    return subprocess.run(["kubectl", *args], capture_output=True, text=True,
                          check=check)


def load_ca():
    with open(os.path.join(CA_DIR, "ca.key"), "rb") as f:
        key = serialization.load_pem_private_key(f.read(), password=None)
    with open(os.path.join(CA_DIR, "ca.crt"), "rb") as f:
        cert_pem = f.read()
    return key, x509.load_pem_x509_certificate(cert_pem), cert_pem


def pending_requests():
    r = kubectl("get", "podcertificaterequests", "-A", "-o", "json", check=False)
    if r.returncode != 0:
        return None
    out = []
    for item in json.loads(r.stdout).get("items", []):
        if item["spec"]["signerName"] != SIGNER_NAME:
            continue
        # A request that already carries a condition has been answered, by
        # this signer or by another one watching the same name.
        if item.get("status", {}).get("conditions"):
            continue
        out.append(item)
    return out


def deny(ns, name, reason, message):
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    patch = {"status": {"conditions": [{
        "type": "Denied", "status": "True", "reason": reason,
        "message": message, "lastTransitionTime": stamp,
    }]}}
    kubectl("-n", ns, "patch", "podcertificaterequest", name,
            "--subresource=status", "--type=merge", "-p", json.dumps(patch),
            check=False)
    log("denied {}/{}: {}".format(ns, name, message))
    return False


def issue(item, ca_key, ca_cert, ca_pem):
    meta, spec = item["metadata"], item["spec"]
    ns, name = meta["namespace"], meta["name"]

    csr = x509.load_der_x509_csr(base64.b64decode(spec["stubPKCS10Request"]))
    if not csr.is_signature_valid:
        return deny(ns, name, "BadRequest", "proof of possession did not verify")

    lifetime = min(LIFETIME, spec.get("maxExpirationSeconds") or LIFETIME)
    not_before = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
    not_after = not_before + datetime.timedelta(seconds=lifetime)

    sa = spec["serviceAccountName"]
    spiffe = "spiffe://{}/ns/{}/sa/{}".format(TRUST_DOMAIN, ns, sa)
    cert = (
        x509.CertificateBuilder()
        .subject_name(x509.Name([]))
        .issuer_name(ca_cert.subject)
        .public_key(csr.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(not_before)
        .not_valid_after(not_after)
        .add_extension(x509.BasicConstraints(ca=False, path_length=None),
                       critical=True)
        .add_extension(
            x509.KeyUsage(digital_signature=True, key_encipherment=True,
                          content_commitment=False, data_encipherment=False,
                          key_agreement=False, key_cert_sign=False,
                          crl_sign=False, encipher_only=False,
                          decipher_only=False),
            critical=True,
        )
        .add_extension(
            x509.ExtendedKeyUsage([x509.oid.ExtendedKeyUsageOID.SERVER_AUTH,
                                   x509.oid.ExtendedKeyUsageOID.CLIENT_AUTH]),
            critical=False,
        )
        # The URI SAN is the identity. The DNS names are a convenience: they
        # let ordinary TLS clients, which verify hostnames and know nothing
        # about SPIFFE, reach a workload fronted by a Service of the same
        # name. Both are derived from the service account the API server
        # vouched for, never from anything the request asked for.
        .add_extension(
            x509.SubjectAlternativeName([
                x509.UniformResourceIdentifier(spiffe),
                x509.DNSName("{}.{}.svc.{}".format(sa, ns, TRUST_DOMAIN)),
                x509.DNSName("{}.{}.svc".format(sa, ns)),
            ]),
            critical=True,
        )
        .sign(ca_key, hashes.SHA256())
    )

    chain = cert.public_bytes(serialization.Encoding.PEM).decode() + ca_pem.decode()
    stamp = "%Y-%m-%dT%H:%M:%SZ"
    # The API server rejects a status whose notBefore/notAfter disagree with
    # the leaf, so both come from the certificate that was just signed.
    patch = {"status": {
        "certificateChain": chain,
        "notBefore": not_before.strftime(stamp),
        "notAfter": not_after.strftime(stamp),
        # Rotate at two thirds of the lifetime, so the signer can be down for
        # a while without any pod losing its identity.
        "beginRefreshAt": (not_before + (not_after - not_before) * 2 // 3).strftime(stamp),
        "conditions": [{
            "type": "Issued",
            "status": "True",
            "reason": "Issued",
            "message": "issued {}".format(spiffe),
            "lastTransitionTime": not_before.strftime(stamp),
        }],
    }}
    r = kubectl("-n", ns, "patch", "podcertificaterequest", name,
                "--subresource=status", "--type=merge", "-p", json.dumps(patch),
                check=False)
    if r.returncode != 0:
        log("failed to issue {}/{}: {}".format(ns, name, r.stderr.strip()))
        return False
    log("issued {}/{}: {} until {}".format(ns, name, spiffe,
                                           not_after.strftime(stamp)))
    return True


def main():
    log("pod-identity-signer starting: signer={} ca={}".format(SIGNER_NAME, CA_DIR))
    complained = False
    while True:
        try:
            ca_key, ca_cert, ca_pem = load_ca()
            batch = pending_requests()
            if batch is None:
                if not complained:
                    log("waiting: this cluster does not serve the "
                        "PodCertificateRequest API")
                    complained = True
                time.sleep(10)
                continue
            complained = False
            for item in batch:
                issue(item, ca_key, ca_cert, ca_pem)
        except Exception as err:  # a signer that exits stops signing
            log("error: {}".format(err))
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    sys.exit(main())
