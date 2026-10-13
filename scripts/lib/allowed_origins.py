#!/usr/bin/env python3
"""Build ALLOWED_ORIGINS, the regex auth and graphql match request origins
against (graphql also matches the chaos subscriber's Host header with it).

Always allowed:
  * localhost, the Docker and minikube host aliases, any *.svc.cluster.local
  * the private ranges a browser or an in-cluster pod connects from:
    10/8, 172.x (kind bridges), 192.168/16, and 100.64/10 (carrier-grade NAT,
    which some corporate VNets and Tailscale use)
Extra hosts (a load balancer's IP or DNS name, this VM's address) are added
literally. A host may be given as "1.2.3.4", "name.example.com" or a full URL
such as "http://1.2.3.4:2001"; scheme, port and path are dropped.

Usage: allowed_origins.py [HOST ...]   (each argument may hold a comma list)
Prints the regex. The regex syntax stays within Go RE2.
"""
import re
import sys

BASE_HOSTS = (
    r"localhost",
    r"host\.docker\.internal",
    r"host\.minikube\.internal",
    r"[a-z0-9.-]+\.svc\.cluster\.local",
)
PRIVATE_RANGES = (
    r"172\.[0-9]+\.[0-9]+\.[0-9]+",
    r"10\.[0-9]+\.[0-9]+\.[0-9]+",
    r"192\.168\.[0-9]+\.[0-9]+",
    r"100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]+\.[0-9]+",
)


def host_of(value):
    """The bare host of "1.2.3.4", "name" or "http://name:port/path"."""
    host = re.sub(r"^[a-z][a-z0-9+.-]*://", "", value.strip(), flags=re.I)
    host = host.split("/", 1)[0]
    return re.sub(r":[0-9]+$", "", host).lower()


def build(extra_hosts=()):
    hosts = []
    for value in extra_hosts:
        for token in re.split(r"[,\s]+", value or ""):
            host = host_of(token)
            if host and host not in hosts:
                hosts.append(host)
    alternatives = [f"({'|'.join(BASE_HOSTS)})", *PRIVATE_RANGES, *(re.escape(h) for h in hosts)]
    return r"^(http://|https://|)(" + "|".join(alternatives) + r")(:[0-9]+|)$"


if __name__ == "__main__":
    print(build(sys.argv[1:]))
