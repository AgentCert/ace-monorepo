commit ec594d93f96e747a051f046edf29c62906bb5049
Author: Ravi Khapra <anonymouscia786@gmail.com>
Date:   Mon Jun 29 12:52:47 2026 +0000

    fix: AKS proxy setup - CA certs, JFrog registry, apply-faults script
    
    - Add apply-faults.sh script to replace image registries in chaos-charts
    - Update graphql.yaml: mount ca-certs ConfigMap, add SSL_CERT_FILE for TLS
    - Update setup.sh: add apply_ca_certs_configmap() for corporate proxy certs
    - Update .env.example: add IMAGE_REGISTRY and CORPORATE_CA_CERT_DIR
    - Update docs for AKS internal LB, CORS fix, and proxy notes
    - Add managing-services.md with restart/health-check reference

diff --git a/docs/setup/managing-services.md b/docs/setup/managing-services.md
index 52d1149..c84a2ce 100644
--- a/docs/setup/managing-services.md
+++ b/docs/setup/managing-services.md
@@ -181,6 +181,64 @@ kubectl delete namespace ace
 
 ---
 
+## Helm Path — Apply `.env` Changes Without Running `setup.sh`
+
+If you deployed via Helm and only want to update env values (e.g. for `graphql`,
+`auth`, `web`) **without** running `setup.sh` again (which overwrites `.env` with
+`k8s_env_patch`), use this workflow:
+
+```bash
+cd /home/ravi.khapra/Desktop/GitClones/ace-monorepo
+
+# 1) Regenerate values-env.yaml directly from your current .env
+python3 -c "
+import re, os
+env_path = 'agentcert-stack/.env'
+out_path = 'deploy/helm/ace/values-env.yaml'
+litellm_cfg = 'agentcert-stack/litellm-setup/litellm_config.yaml'
+keys_order, seen = [], {}
+for ln in open(env_path).read().splitlines():
+    m = re.match(r'^([A-Za-z0-9_.]+)=(.*)', ln)
+    if not m: continue
+    k, v = m.group(1), m.group(2)
+    if k not in seen: keys_order.append(k)
+    seen[k] = v
+lines = ['env:']
+for k in keys_order:
+    v = seen[k].replace(\"'\", \"''\")
+    lines.append(f\"  {k}: '{v}'\")
+if os.path.isfile(litellm_cfg):
+    cfg = open(litellm_cfg).read()
+    lines += ['', 'litellm:', '  config: |']
+    lines += ['    ' + l for l in cfg.splitlines()]
+open(out_path, 'w').write('\n'.join(lines) + '\n')
+print('✓ values-env.yaml regenerated from .env')
+"
+
+# 2) Helm upgrade (updates the ace-env Secret)
+helm upgrade --install ace deploy/helm/ace \
+  --namespace ace \
+  -f deploy/helm/ace/values-env.yaml \
+  --timeout 10m
+
+# 3) Restart only the affected services
+kubectl rollout restart deployment/graphql deployment/auth deployment/web -n ace
+
+# 4) Wait for rollout to finish
+kubectl rollout status -n ace deployment/graphql deployment/auth deployment/web
+```
+
+<div class="callout callout-info">
+<span class="callout-title">ℹ Why not just re-run setup.sh?</span>
+<code>setup.sh helm</code> calls <code>k8s_env_patch</code> which overwrites
+service URLs in <code>.env</code> with internal K8s DNS names. If you've manually
+edited <code>.env</code> values (e.g. API keys, credentials), the patch step may
+clobber your changes. The workflow above skips all patching and reads <code>.env</code>
+as-is.
+</div>
+
+---
+
 ## Helm Path — Upgrade & Rollback
 
 If you deployed via Helm (`h` choice in setup.sh), use these commands instead
