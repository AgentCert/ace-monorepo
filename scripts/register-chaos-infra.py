#!/usr/bin/env python3
# Copyright 2026 AgentCert Authors. SPDX-License-Identifier: Apache-2.0
"""Idempotently register this checkout's chaos infrastructure with ChaosCenter.

setup.sh calls this after the control plane is up so a fresh install ends with a
connected chaos infrastructure instead of the manual "create environment ->
enable chaos -> download YAML -> kubectl apply" UI sequence.

Behaviour:
  * logs in as the admin user (retrying while auth/graphql finish starting),
  * reuses an existing, non-removed infra with --infra-name if one exists and
    re-fetches its manifest (so a wiped litmus namespace can be re-applied),
  * otherwise ensures --env-id exists and registers a new cluster-scoped infra
    with the same defaults the UI's "Enable Chaos" wizard sends,
  * writes the install manifest to --manifest-out and prints one JSON line
    {"infra_id", "project_id", "namespace", "created"} on stdout.

Only the Python standard library is used: this runs before any venv exists.
"""

import argparse
import json
import sys
import time
import urllib.error
import urllib.request


class ApiError(RuntimeError):
    pass


def _post_json(url, payload, token=None, timeout=30):
    # Auth and GraphQL enforce browser-style origin checks. urllib does not
    # add Origin automatically, so local setup requests would get HTTP 403.
    headers = {
        "Content-Type": "application/json",
        "Origin": "http://localhost",
        # Older local GraphQL images still require Referer when constructing
        # the generated install manifest; keep setup compatible with upgrades.
        "Referer": "http://localhost:2001/",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=json.dumps(payload).encode(), headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        raise ApiError(f"HTTP {exc.code} from {url}: {exc.read().decode(errors='replace')[:300]}") from exc
    except (urllib.error.URLError, OSError, ValueError) as exc:
        raise ApiError(f"{url}: {exc}") from exc


def gql(url, token, query, variables):
    body = _post_json(url, {"query": query, "variables": variables}, token=token)
    if not isinstance(body, dict):
        raise ApiError(f"GraphQL returned {type(body).__name__}, expected an object")
    if body.get("errors"):
        errors = body["errors"]
        if not isinstance(errors, list):
            raise ApiError(f"GraphQL errors: {errors}")
        raise ApiError("; ".join(
            e.get("message", str(e)) if isinstance(e, dict) else str(e)
            for e in errors
        ))
    data = body.get("data")
    if not isinstance(data, dict):
        raise ApiError("GraphQL response is missing an object-valued data field")
    return data


def login(auth_url, username, password, deadline):
    last = None
    while time.monotonic() < deadline:
        try:
            body = _post_json(f"{auth_url}/login", {"username": username, "password": password})
            if not isinstance(body, dict):
                last = f"login returned {type(body).__name__}, expected an object"
                raise ApiError(last)
            token, project = body.get("accessToken"), body.get("projectID")
            if token and project:
                return token, project
            last = f"login response missing accessToken/projectID: {str(body)[:200]}"
        except ApiError as exc:
            last = str(exc)
        time.sleep(5)
    raise ApiError(f"could not log in to {auth_url}: {last}")


def find_infra(gql_url, token, project_id, name):
    data = gql(
        gql_url,
        token,
        "query($projectID: ID!) { listInfras(projectID: $projectID, request: {}) {"
        " infras { infraID name isRemoved infraNamespace } } }",
        {"projectID": project_id},
    )
    for infra in data["listInfras"]["infras"] or []:
        if infra["name"] == name and not infra["isRemoved"]:
            return infra
    return None


def ensure_environment(gql_url, token, project_id, env_id):
    try:
        gql(
            gql_url,
            token,
            "query($projectID: ID!, $environmentID: ID!) {"
            " getEnvironment(projectID: $projectID, environmentID: $environmentID) { environmentID } }",
            {"projectID": project_id, "environmentID": env_id},
        )
        return
    except ApiError:
        pass  # not found -> create below
    gql(
        gql_url,
        token,
        "mutation($projectID: ID!, $request: CreateEnvironmentRequest) {"
        " createEnvironment(projectID: $projectID, request: $request) { environmentID } }",
        {
            "projectID": project_id,
            "request": {
                "environmentID": env_id,
                "name": env_id,
                "type": "NON_PROD",
                "description": "Created by scripts/setup.sh",
                "tags": ["ace-setup"],
            },
        },
    )


def wait_confirmed(gql_url, token, project_id, infra_id, deadline):
    """Block until the subscriber has called confirmInfraRegistration and is connected."""
    state = None
    while time.monotonic() < deadline:
        try:
            data = gql(
                gql_url,
                token,
                "query($projectID: ID!, $ids: [ID!]) { listInfras(projectID: $projectID,"
                " request: {infraIDs: $ids}) { infras { infraID isInfraConfirmed isActive } } }",
                {"projectID": project_id, "ids": [infra_id]},
            )
            infras = data["listInfras"]["infras"] or []
            state = infras[0] if infras else None
            if state and state["isInfraConfirmed"] and state["isActive"]:
                return
        except ApiError as exc:
            state = str(exc)
        time.sleep(5)
    raise ApiError(f"infra {infra_id} did not confirm/connect in time (last state: {state})")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--auth-url", required=True, help="auth REST base URL, e.g. http://127.0.0.1:3000")
    ap.add_argument("--gql-url", required=True, help="GraphQL endpoint, e.g. http://127.0.0.1:8081/query")
    ap.add_argument("--username", default="admin")
    ap.add_argument("--password", default="litmus")
    ap.add_argument("--env-id", default="ace-local")
    ap.add_argument("--infra-name", default="ace-local")
    ap.add_argument("--namespace", default="litmus")
    ap.add_argument("--service-account", default="litmus")
    ap.add_argument("--manifest-out", help="where to write the infra install manifest")
    ap.add_argument("--wait-confirmed", metavar="INFRA_ID",
                    help="instead of registering, wait until INFRA_ID's subscriber has confirmed and connected")
    ap.add_argument("--timeout", type=int, default=300, help="seconds to wait for auth/graphql (or confirmation)")
    args = ap.parse_args()
    if not args.wait_confirmed and not args.manifest_out:
        ap.error("--manifest-out is required unless --wait-confirmed is given")

    deadline = time.monotonic() + args.timeout
    try:
        token, project_id = login(args.auth_url, args.username, args.password, deadline)
        if args.wait_confirmed:
            wait_confirmed(args.gql_url, token, project_id, args.wait_confirmed, deadline)
            return 0

        # GraphQL can lag auth by a few seconds on first start.
        last = None
        while True:
            try:
                infra = find_infra(args.gql_url, token, project_id, args.infra_name)
                break
            except ApiError as exc:
                last = exc
                if time.monotonic() >= deadline:
                    raise ApiError(f"graphql not ready: {last}") from exc
                time.sleep(5)

        created = False
        if infra:
            infra_id = infra["infraID"]
            namespace = infra.get("infraNamespace") or args.namespace
            manifest = gql(
                args.gql_url,
                token,
                "query($infraID: ID!, $projectID: ID!) {"
                " getInfraManifest(infraID: $infraID, upgrade: false, projectID: $projectID) }",
                {"infraID": infra_id, "projectID": project_id},
            )["getInfraManifest"]
        else:
            ensure_environment(args.gql_url, token, project_id, args.env_id)
            resp = gql(
                args.gql_url,
                token,
                "mutation($projectID: ID!, $request: RegisterInfraRequest!) {"
                " registerInfra(projectID: $projectID, request: $request) { infraID manifest } }",
                {
                    "projectID": project_id,
                    "request": {
                        "name": args.infra_name,
                        "environmentID": args.env_id,
                        "infrastructureType": "Kubernetes",
                        "description": "Registered automatically by scripts/setup.sh",
                        "platformName": "Kubernetes",
                        "infraNamespace": args.namespace,
                        "serviceAccount": args.service_account,
                        "infraScope": "cluster",
                        "infraNsExists": False,
                        "infraSaExists": False,
                        "skipSsl": False,
                        "tags": ["ace-setup"],
                    },
                },
            )["registerInfra"]
            infra_id, manifest, namespace, created = resp["infraID"], resp["manifest"], args.namespace, True
    except (ApiError, KeyError, TypeError) as exc:
        print(f"register-chaos-infra: {exc}", file=sys.stderr)
        return 1

    if not isinstance(manifest, str) or "kind:" not in manifest:
        print("register-chaos-infra: control plane returned an empty infra manifest", file=sys.stderr)
        return 1
    with open(args.manifest_out, "w") as fh:
        fh.write(manifest)
    print(json.dumps({"infra_id": infra_id, "project_id": project_id, "namespace": namespace, "created": created}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
