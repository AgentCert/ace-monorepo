#!/usr/bin/env python3
"""Exercise build/publish/install modes with fake external commands; no Docker or cluster needed."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
MOCK = '''#!/usr/bin/env python3
import json, os, pathlib, sys, time
name=pathlib.Path(sys.argv[0]).name
args=sys.argv[1:]
with open(os.environ['AUDIT_COMMAND_LOG'],'a') as out:
 out.write(json.dumps([name,*args])+'\\n')
if name=='docker':
 if args and args[0]=='build':
  if args[-1]=='-':sys.stdin.buffer.read()
  if os.getenv('AUDIT_FAIL_BUILD')=='1':sys.exit(7)
  positions=[]; skip=False
  for arg in args[1:]:
   if skip:skip=False;continue
   if arg in ['-f','--file','-t','--tag','--label','--build-arg','--network','--target','--platform','--progress']:skip=True
   elif not arg.startswith('-') or arg=='-':positions.append(arg)
  assert len(positions)==1, ('Docker build needs exactly one context',positions)
  if '-f' in args:
   assert pathlib.Path(args[args.index('-f')+1]).is_file()
  if args[-1]!='-':assert pathlib.Path(args[-1]).is_dir()
 elif args[:2]==['image','inspect']:
  # AUDIT_LOCAL_IMAGES: comma-separated references already in the local cache.
  if os.getenv('AUDIT_EXISTING_RELEASE') or set(args[2:]) & set(os.getenv('AUDIT_LOCAL_IMAGES','').split(',')):print('sha256:local')
  else:sys.exit(1)
 elif args[:3]==['buildx','imagetools','inspect']:
  if not os.getenv('AUDIT_EXISTING_RELEASE'):sys.exit(1)
  fmt=args[args.index('--format')+1] if '--format' in args else ''
  # The release-tag guard reads the revision LABEL (store-independent), not a
  # digest: `docker image inspect .Id` is the config digest on the overlay2
  # image store and the manifest digest only under containerd.
  if '.Image' in fmt:
   rev=os.environ.get('AUDIT_REMOTE_REVISION','') if os.environ['AUDIT_EXISTING_RELEASE']=='same' else 'a-different-revision'
   print(json.dumps({'config':{'Labels':{'org.opencontainers.image.revision':rev}}}))
  elif fmt:print(json.dumps({'digest':'sha256:local' if os.environ['AUDIT_EXISTING_RELEASE']=='same' else 'sha256:different'}))
 elif args and args[0]=='login':
  sys.stdin.read()
  if os.getenv('AUDIT_FAIL_LOGIN')=='1':sys.exit(8)
 elif args and args[0]=='push':
  if '--help' in args:print('--platform')
  elif os.getenv('AUDIT_FAIL_PUSH')=='1':sys.exit(9)
elif name=='kubectl' and 'get' in args:sys.exit(1)
elif name=='tsc':
 config=pathlib.Path(args[args.index('-p')+1])
 pathlib.Path(os.environ['AUDIT_TSC_CONFIG']).write_text(config.read_text())
 sys.exit(int(os.getenv('AUDIT_TSC_EXIT','0')))
'''
passed = 0

def main():
    global passed
    with tempfile.TemporaryDirectory(prefix='ace-script-modes-') as work:
        work = Path(work)
        bin_dir = work / 'bin'; bin_dir.mkdir()
        for name in ['docker', 'kind', 'kubectl', 'minikube', 'helm', 'eslint', 'tsc']:
            path = bin_dir / name; path.write_text(MOCK); path.chmod(0o755)
        log = work / 'commands.jsonl'
        env_file = work / 'config with spaces.env'
        config = ('IMAGE_REGISTRY=\nIMAGE_MIRROR_NAMESPACE=agentcert\nACE_IMAGE_TAG=\n'
                  'ACE_BUILD_NETWORK=host\nACE_INSTANCE_NAME=script-audit\n'
                  'REGISTRY_USERNAME=fixture\nREGISTRY_PASSWORD=fixture\n')
        env_file.write_text(config)
        environment = {k: v for k, v in os.environ.items() if not k.startswith(
            ('IMAGE_', 'ACE_', 'REGISTRY_', 'DOCKERHUB_', 'JFROG_', 'KIND_'))}
        environment.update(PATH=str(bin_dir) + os.pathsep + os.environ['PATH'],
                           AUDIT_COMMAND_LOG=str(log), AUDIT_TSC_CONFIG=str(work / 'tsconfig.json'))

        def run(name, args, expected=0, builds=None, pushes=None, deploy=False, extra=None, cwd=ROOT, logins=None, removes=None):
            global passed
            log.write_text(''); env_file.write_text(config)
            result = subprocess.run(args, cwd=cwd, env={**environment, **(extra or {})},
                                    capture_output=True, text=True, timeout=45)
            assert (result.returncode == 0) == (expected == 0), (name, result.returncode, result.stdout[-2500:], result.stderr[-2500:])
            commands = [json.loads(line) for line in log.read_text().splitlines()]
            build_calls = [c for c in commands if c[:2] == ['docker', 'build']]
            push_calls = [c for c in commands if c[:2] == ['docker', 'push'] and '--help' not in c]
            if builds is not None: assert len(build_calls) == builds, (name, build_calls)
            if pushes is not None: assert len(push_calls) == pushes, (name, push_calls)
            rmi_calls = [c for c in commands if c[:2] == ['docker', 'rmi']]
            assert len(rmi_calls) == (removes or 0), (name, rmi_calls)
            assert not any(c[:2] == ['docker', 'prune'] or c[:3] == ['docker', 'image', 'prune'] for c in commands), (name, commands)
            if not deploy:
                assert not any(c[0] in ['kubectl', 'kind', 'minikube', 'helm'] for c in commands), (name, commands)
            login_calls = [c for c in commands if c[:2] == ['docker', 'login']]
            if logins is not None:
                assert len(login_calls) == logins, (name, login_calls)
                if logins and build_calls: assert commands.index(login_calls[0]) < commands.index(build_calls[0]), (name, commands)
            elif pushes == 0:
                assert not login_calls, (name, commands)
            if build_calls:
                for c in build_calls:
                    if '--network' in c:
                        network = 'default' if any('missing.env' in str(arg) for arg in args) else 'host'
                        assert c[c.index('--network')+1] == network, (name, c)
            if not deploy: assert env_file.read_text() == config, name
            passed += 1; print('PASS', name, flush=True)
            return commands

        def shell(script, *args): return ['bash', str(ROOT / script), '--env-file', str(env_file), *args]
        builder = 'scripts/build-and-push.sh'
        flash = '--only', '^agentcert/agentcert-flash-agent:'

        def source_revision(ctx):
            """Mirror registry.sh source_revision() so the release-tag guard can be exercised."""
            d = ROOT / ctx
            sha = subprocess.run(['git', '-C', str(d), 'rev-parse', '--short=12', 'HEAD'],
                                 capture_output=True, text=True)
            sha = sha.stdout.strip() if sha.returncode == 0 and sha.stdout.strip() else 'unknown'
            dirty = subprocess.run(['git', '-C', str(d), 'status', '--porcelain', '--', '.'],
                                   capture_output=True, text=True).stdout.splitlines()
            return sha + '-dirty' if dirty else sha

        # Build-row count comes from the inventory, so adding or removing an
        # image does not silently turn these into assertions about a stale number.
        all_images = sum(1 for line in (ROOT / 'deploy/images.txt').read_text().splitlines()
                         if line.startswith('build|') and 'optional' not in line)
        flash_commit = source_revision('agents/flash-agent').removesuffix('-dirty')
        run(f'default builds all {all_images} locally', shell(builder), builds=all_images, pushes=0)
        run(f'setup default builds all {all_images} locally', shell('scripts/setup.sh'), builds=all_images, pushes=0)
        run(f'prepare default builds all {all_images} locally', shell('scripts/prepare-images.sh'), builds=all_images, pushes=0)
        run('prepare hub only builds one image', shell('scripts/prepare-images.sh', '--hub-only'), builds=1, pushes=0)
        run('supporting services default builds certifier only', shell('scripts/start-local-services.sh'), builds=1, pushes=0)
        run('legacy launch default builds locally', shell('scripts/azure_build/run.sh'), builds=all_images, pushes=0)
        run('legacy v2 default builds locally', shell('scripts/azure_build/start-agentcert-v2.sh'), builds=all_images, pushes=0)
        for legacy in ['scripts/azure_build/run.sh','scripts/azure_build/start-agentcert-v2.sh']:
            run(legacy+' rejects local push',shell(legacy,'--local','--push'),expected=1,builds=0,pushes=0)
            run(legacy+' rejects local deploy',shell(legacy,'--local','--deploy'),expected=1,builds=0,pushes=0)
        for script in ['agents/flash-agent/build-flash-agent.sh', 'agent-sidecar/build-agent-sidecar.sh',
                       'app-charts/install-app/build-install-app.sh', 'agent-charts/install-agent/build-install-agent.sh',
                       'app-charts/install-app/build-and-deploy-app-chart.sh', 'scripts/azure_build/build-and-deploy-app-chart.sh']:
            run(script + ' default', shell(script), builds=1, pushes=0)
            run(script + ' build failure', shell(script), expected=1, builds=1, pushes=0, extra={'AUDIT_FAIL_BUILD':'1'})
        for flag in ['--only', '--env-file', '--tag']:
            run('missing '+flag, ['bash', str(ROOT / builder), flag], expected=1, builds=0, pushes=0)
        for args in [('--only','['), ('--only','does-not-exist'), ('--tag','bad/tag'), ('--unknown',),
                     ('--local','--push'), ('--push','--local'), ('--kind-load','--push')]:
            run('reject '+str(args), shell(builder, *args), expected=1, builds=0, pushes=0)
        run('explicit local mode', shell(builder, '--local', *flash), builds=1, pushes=0)
        # --committed-only only exports a context when that context is dirty (a
        # clean checkout already *is* its committed content), so the scratch
        # file below is what makes this assertion deterministic rather than
        # dependent on whatever the developer happens to have uncommitted.
        scratch = ROOT / 'agents/flash-agent/.ace-script-modes-scratch'
        scratch.write_text('transient fixture\n')
        try:
            calls = run('committed-only uses the exported Dockerfile',
                        shell(builder, '--committed-only', *flash), builds=1, pushes=0)
            built = next(c for c in calls if c[:2] == ['docker', 'build'])
            assert '/.tmp/build-src/' in built[built.index('-f')+1], built
            # The export must come from HEAD, so the scratch file must not be in it.
            exported = Path(built[built.index('-f')+1]).parent
            assert not (exported / scratch.name).exists(), 'export leaked uncommitted content'
        finally:
            scratch.unlink(missing_ok=True)
        calls = run('local tag', shell(builder, '--tag','local-test', *flash), builds=1, pushes=0)
        assert any(c[:2] == ['docker','tag'] and c[-1].endswith(':local-test') for c in calls)
        run('explicit push', shell(builder, '--push', *flash), builds=1, pushes=2)
        # Release-tag guard: refusals happen before anything is built.
        release = {'ACE_IMAGE_TAG':'fixture-release','AUDIT_EXISTING_RELEASE':'same'}
        run('different content cannot replace a release tag', shell(builder, '--push', *flash), expected=1, builds=0, pushes=0, logins=1, extra={**release,'AUDIT_EXISTING_RELEASE':'different'})
        # --committed-only builds the clean commit whatever the working tree
        # holds, so this does not depend on the developer's uncommitted files.
        run('identical clean release can be republished', shell(builder, '--push', '--committed-only', *flash), builds=1, pushes=2, extra={**release,'AUDIT_REMOTE_REVISION':flash_commit})
        run('unlabelled release cannot be replaced', shell(builder, '--push', *flash), expected=1, builds=0, pushes=0, logins=1, extra={**release,'AUDIT_REMOTE_REVISION':''})
        scratch = ROOT / 'agents/flash-agent/.ace-script-modes-scratch'
        scratch.write_text('transient fixture\n')
        try:
            # Same "<sha>-dirty" label, but uncommitted changes are recorded
            # nowhere, so equal labels do not prove equal content.
            run('dirty revision cannot replace a release tag', shell(builder, '--push', *flash), expected=1, builds=0, pushes=0, logins=1, extra={**release,'AUDIT_REMOTE_REVISION':flash_commit+'-dirty'})
        finally:
            scratch.unlink(missing_ok=True)
        no_git = work / 'no-git'; no_git.mkdir()
        (no_git / 'git').write_text('#!/bin/sh\nexit 128\n'); (no_git / 'git').chmod(0o755)
        run('unknown revision cannot replace a release tag', shell(builder, '--push', *flash), expected=1, builds=0, pushes=0, logins=1,
            extra={**release,'AUDIT_REMOTE_REVISION':'unknown','PATH':str(no_git)+os.pathsep+environment['PATH']})
        private = {'IMAGE_REGISTRY': 'registry.example/docker-local', 'REGISTRY_USERNAME': 'fixture', 'REGISTRY_PASSWORD': 'fixture'}
        run('local build logs in to a private registry for base images', shell(builder, *flash), builds=1, pushes=0, logins=1, extra=private)
        run('local build continues when that login fails', shell(builder, *flash), builds=1, pushes=0, logins=1, extra={**private,'AUDIT_FAIL_LOGIN':'1'})
        run('push login failure', shell(builder, '--push', *flash), expected=1, builds=0, extra={'AUDIT_FAIL_LOGIN':'1'})
        run('push build failure prevents publication', shell(builder, '--push', *flash), expected=1, builds=1, extra={'AUDIT_FAIL_BUILD':'1'})
        run('push failure reported', shell(builder, '--push', *flash), expected=1, builds=1, extra={'AUDIT_FAIL_PUSH':'1'})
        run('explicit kind load', shell(builder, '--kind-load', *flash), builds=1, pushes=0, deploy=True)
        run('local without an env file', ['bash', str(ROOT/builder),'--env-file',str(work/'missing.env'),*flash], builds=1, pushes=0)
        run('push without an env file fails', ['bash',str(ROOT/builder),'--push','--env-file',str(work/'missing.env'),*flash], expected=1, builds=0, pushes=0)
        for script in ['scripts/mirror-images.sh','app-charts/install-app/build-and-deploy-app-chart.sh']:
            run(script+' rejects conflicting modes',shell(script,'--local','--push'),expected=1,builds=0,pushes=0)
        for script in ['scripts/prepare-images.sh','scripts/start-local-services.sh','agentcert-stack/litellm-setup/build-litellm.sh']:
            run(script+' rejects local deploy',shell(script,'--local','--deploy'),expected=1,builds=0,pushes=0)
        for args in [('--pull-certifier',), ('--only-certifier','--pull-certifier')]:
            run('pull-certifier without --deploy is refused '+str(args),shell('scripts/start-local-services.sh',*args),expected=2,builds=0,pushes=0)
        inventory=work/'images.txt';inventory.write_text('mirror|infra|mongo:5\n')
        calls=run('mirror default caches without publication',shell('scripts/mirror-images.sh','--images',str(inventory)),builds=0,pushes=0)
        # The frozen-copy name (agentcert/mongo:5) must not be pointed at today's upstream image.
        assert any(c[:2]==['docker','pull'] and c[-1]=='mongo:5' for c in calls) and not any(c[:2]==['docker','tag'] for c in calls), calls
        calls=run('mirror explicit push removes the copies it pulled',shell('scripts/mirror-images.sh','--push','--images',str(inventory)),builds=0,pushes=1,removes=2)
        assert sorted(c[2] for c in calls if c[:2]==['docker','rmi'])==['agentcert/mongo:5','mongo:5'], calls
        calls=run('mirror push keeps images cached before the run',shell('scripts/mirror-images.sh','--push','--images',str(inventory)),builds=0,pushes=1,removes=1,extra={'AUDIT_LOCAL_IMAGES':'mongo:5'})
        assert [c[2] for c in calls if c[:2]==['docker','rmi']]==['agentcert/mongo:5'], calls
        run('mirror dry run',shell('scripts/mirror-images.sh','--dry-run','--images',str(inventory)),builds=0,pushes=0)
        run('LiteLLM default only caches image',shell('agentcert-stack/litellm-setup/build-litellm.sh'),builds=0,pushes=0)
        run('LiteLLM private registry logs in before pulling',['bash',str(ROOT/'agentcert-stack/litellm-setup/build-litellm.sh'),'--env-file',str(env_file)],builds=0,pushes=0,logins=1,extra={'IMAGE_REGISTRY':'registry.example/docker-local'})
        run('cluster prerequisites default does not deploy',shell('scripts/apply_cluster_prereqs.sh'),builds=0,pushes=0)
        run('chart explicit push',shell('app-charts/install-app/build-and-deploy-app-chart.sh','--push'),builds=1,pushes=2)
        run('chart explicit deployment',shell('app-charts/install-app/build-and-deploy-app-chart.sh','--deploy'),builds=1,pushes=0,deploy=True)
        chart_source=work/'chart source'; (chart_source/'install-app').mkdir(parents=True)
        (chart_source/'install-app/Dockerfile').write_text('FROM scratch\n')
        (chart_source/'charts/sock-shop').mkdir(parents=True)
        chart_values=chart_source/'charts/sock-shop/values.yaml'
        original_values='tracing:\n  zipkinHost: original\n  disableSleuth: false\n'
        chart_values.write_text(original_values)
        for fail in [False,True]:
            calls=run('chart local-mode isolation '+str(fail),shell('app-charts/install-app/build-and-deploy-app-chart.sh','--local-mode','--source-dir',str(chart_source/'install-app')),expected=1 if fail else 0,builds=1,pushes=0,extra={'AUDIT_FAIL_BUILD':'1'} if fail else None)
            assert chart_values.read_text()==original_values
            context=next(c[-1] for c in calls if c[:2]==['docker','build'])
            assert not Path(context).exists(), 'Temporary build context was not removed'
        manifest=work/'pod.yaml'
        manifest.write_text('apiVersion: v1\nkind: Pod\nmetadata:\n  name: fixture\nspec:\n  containers:\n  - name: main\n    image: mongo:5\n')
        run('manifest helper renders without deployment',shell('scripts/kubectl-apply-images.sh','-f',str(manifest)),builds=0,pushes=0)
        run('manifest deployment requires explicit flag',shell('scripts/kubectl-apply-images.sh','--deploy','-f',str(manifest)),builds=0,pushes=0,deploy=True)
        # ── setup.sh pieces, run exactly as written in setup.sh (no wizard, no cluster) ──
        setup_source=(ROOT/'scripts/setup.sh').read_text()
        def setup_part(begin, end):
            i = setup_source.index(begin)
            return setup_source[i:setup_source.index(end, i) + len(end)]
        def setup_fn(name): return setup_part(name + '() {', '\n}\n')
        setup_env = work / 'setup.env'
        prelude = ('set -euo pipefail; source "$1/scripts/lib/registry.sh"; ENV_FILE="$2"; '
                   'BOLD=; CYAN=; GREEN=; YELLOW=; RED=; DIM=; NC=\n'
                   'cur() { grep -m1 "^$1=" "${ENV_FILE}" 2>/dev/null | cut -d= -f2- || true; }\n'
                   'set_env() { printf "%s=%s\\n" "$1" "$2" >> "${ENV_FILE}"; }\n'
                   'ok() { echo "ok: $*"; }; warn() { echo "warn: $*"; }; ask() { echo fixture; }\n'
                   'detect_k3s_gw() { :; }; detect_kind_gw() { :; }\n'
                   + setup_fn('abort_setup') + setup_fn('publish_choice_note') + setup_fn('refuse_publish_without_push'))
        def setup_snippet(name, body, env_text, stdin='', expected=0, **variables):
            global passed
            setup_env.write_text(env_text)
            assigns = ''.join(f'{k}={v!r}\n' for k, v in variables.items())
            result = subprocess.run(['bash', '-c', prelude + assigns + body, '_', str(ROOT), str(setup_env)],
                                    input=stdin, capture_output=True, text=True, timeout=30)
            assert result.returncode == expected, (name, result.returncode, result.stdout[-2000:], result.stderr[-2000:])
            passed += 1; print('PASS', name, flush=True)
            return result

        # Build inventory: every build row except the hub bundle (prepare-images.sh
        # builds HUB_BUNDLE_IMAGE) and, unless its source is local, the ITBench runner.
        build_rows = [l.split('|') for l in (ROOT/'deploy/images.txt').read_text().splitlines()
                      if l.startswith('build|') and 'optional' not in l]
        def setup_label(image):
            label = image.removeprefix('agentcert/').rsplit(':', 1)[0]; return label.removeprefix('agentcert-')
        inventory_setup = setup_part('declare -a ALL_BUILD_IMAGES=()', 'unset _build_num')
        for source, itbench_built in [('', True), ('local', True), ('registry', False)]:
            result = setup_snippet('setup build inventory, ITBench source ' + (source or 'unset'),
                                   'REPO_ROOT="$1"; _SUBSCRIBER_IMAGE_TAG=agentcert/litmusportal-subscriber:3.0.0\n'
                                   + inventory_setup + '\nprintf "%s\\n" "${ALL_BUILD_IMAGES[@]}"\n',
                                   f'ITBENCH_EXPERIMENT_IMAGE_SOURCE={source}\n' if source else '')
            entries = [e.split('|') for e in result.stdout.splitlines()]
            want = [r for r in build_rows if r[4] != 'hub-bundle'
                    and (itbench_built or setup_label(r[2]) != 'itbench-experiment')]
            assert [e[2].rsplit(':', 1)[0] for e in entries] == [r[2].rsplit(':', 1)[0] for r in want], (entries, want)
            assert [e[0] for e in entries] == [str(n) for n in range(1, len(want) + 1)], entries

        # --restart with a saved "push" policy: without --push it must deploy
        # the published images (no exit, no publish, .env untouched).
        restart = (setup_part('if [[ "$SETUP_MODE" == "restart" ]]; then', '    unset _restart_choice\nfi\n')
                   + setup_part('PUBLISH_SELECTED=0\n', '\nfi\n')
                   + 'echo "DO_BUILD=${DO_BUILD} PUBLISH_SELECTED=${PUBLISH_SELECTED}"\n')
        saved = 'CLUSTER_MODE=auto\nPLATFORM_IMAGE_SOURCE=push\nREGISTRY_USERNAME=fixture\nREGISTRY_PASSWORD=fixture\n'
        array = 'ALL_BUILD_IMAGES=("1|graphql|agentcert/agentcert-graphql:latest|%s|server/Dockerfile|direct")\n' % (ROOT/'AgentCert/chaoscenter/graphql')
        result = setup_snippet('restart with saved push policy and no --push deploys without publishing',
                               array + restart, saved, PUSH_IMAGES='0', SETUP_MODE='restart', BUILD_MODE='prompt', REPO_ROOT=str(work))
        assert 'DO_BUILD=0 PUBLISH_SELECTED=0' in result.stdout and 'add --push to publish' in result.stdout, result.stdout
        assert setup_env.read_text() == saved, setup_env.read_text()
        result = setup_snippet('restart with saved push policy and --push publishes through build-and-push',
                               array + restart, saved, PUSH_IMAGES='1', SETUP_MODE='restart', BUILD_MODE='prompt', REPO_ROOT=str(work))
        assert 'DO_BUILD=0 PUBLISH_SELECTED=1' in result.stdout, result.stdout

        # Choosing "p" without --push stops at the prompt: nothing saved, no credentials asked.
        guided = setup_part('# --- Build: push to the image registry or build locally (optional)', 'fi # EXPRESS_MODE -eq 0 (build section)\n')
        prompt_vars = dict(EXPRESS_MODE='0', BUILD_MODE='prompt', CLUSTER_MODE='auto', _PUSH_TARGET_LABEL='Docker Hub')
        start_env = 'CLUSTER_MODE=auto\n'
        result = setup_snippet('guided p without --push stops before saving the policy', array + guided, start_env,
                               stdin='p\n', expected=2, PUSH_IMAGES='0', **prompt_vars)
        assert '(requires --push)' in result.stdout and './scripts/setup.sh --deploy --push' in result.stderr, result
        assert setup_env.read_text() == start_env
        setup_snippet('guided l saves the local policy', array + guided, start_env, stdin='l\n\n', PUSH_IMAGES='0', **prompt_vars)
        assert 'PLATFORM_IMAGE_SOURCE=local' in setup_env.read_text()
        setup_snippet('guided p with --push saves the push policy', array + guided, start_env, stdin='p\n\n', PUSH_IMAGES='1', **prompt_vars)
        assert 'PLATFORM_IMAGE_SOURCE=push' in setup_env.read_text()
        express = setup_part('    # Build\n    DO_BUILD=0; DO_LOCAL_BUILD=0', '    unset _pis\n')
        setup_snippet('express p without --push stops before saving the policy', array + 'declare -a SELECTED_BUILD_IMAGES=()\n' + express,
                      start_env, stdin='p\n', expected=2, PUSH_IMAGES='0', CLUSTER_MODE='auto', _PUSH_TARGET_LABEL='Docker Hub')
        assert setup_env.read_text() == start_env
        setup_snippet('cloud p without --push stops before the release-tag question',
                      array + setup_fn('ask_cloud_build_choice') + 'ask_cloud_build_choice\n', start_env,
                      stdin='p\n', expected=2, PUSH_IMAGES='0', _PUSH_TARGET_LABEL='registry.example')
        assert setup_env.read_text() == start_env
        # The refusal reaps the express-mode background KinD pre-warm first.
        result = setup_snippet('publish refusal reaps the background KinD job',
                               'sleep 2 & _KIND_PREWARM_PID=$!; echo "pid=${_KIND_PREWARM_PID}"; refuse_publish_without_push\n',
                               '', expected=2, PUSH_IMAGES='0')
        pid = result.stdout.split('pid=')[1].split()[0]
        assert not Path('/proc', pid).exists(), 'background KinD job was orphaned'

        # The harness scripts read <repo>/.env with no override, so pin what the
        # assertions depend on through the environment, which wins over .env.
        public = {'IMAGE_REGISTRY': '', 'ACE_BUILD_NETWORK': 'host'}
        harness_private = {**private, 'ACE_BUILD_NETWORK': 'host'}
        for agent in ['flash-agent','ciso-agent','sre-agent','sre-agent-crewai','sre-agent-comprehensive','sre-agent-qwen']:
            run(agent+' harness default is Docker only', ['bash',str(ROOT/'agents/harness'/agent/'setup.sh')], builds=1,pushes=0,extra=public)
            run(agent+' harness private registry logs in to pull', ['bash',str(ROOT/'agents/harness'/agent/'setup.sh')], builds=1,pushes=0,logins=1,extra=harness_private)
            run(agent+' harness help', ['bash',str(ROOT/'agents/harness'/agent/'setup.sh'),'--help'], builds=0,pushes=0)
            run(agent+' harness accepts --install', ['bash',str(ROOT/'agents/harness'/agent/'setup.sh'),'--install','--help'], builds=0,pushes=0)
        # The A2A adapter has no image: its default (what scripts/ace-bench.py
        # runs, no arguments) creates the venv agent-harness.yaml activates.
        # Run from a copy with a python3 stub, so the checkout and network are untouched.
        adapter = work / 'a2a'; adapter.mkdir()
        (adapter / 'setup.sh').write_text((ROOT/'agents/harness/a2a-mcp-agent/setup.sh').read_text())
        stub = work / 'python-stub'; stub.mkdir()
        (stub / 'python3').write_text('#!/bin/bash\necho "python3 $*" >> "$AUDIT_A2A_LOG"\n'
            'if [[ "$1 $2" == "-m venv" ]]; then mkdir -p "$3/bin"; : > "$3/bin/activate"\n'
            '  printf \'#!/bin/bash\\necho "pip $*" >> "$AUDIT_A2A_LOG"\\n\' > "$3/bin/pip"; chmod +x "$3/bin/pip"; fi\n')
        (stub / 'python3').chmod(0o755)
        a2a_log = work / 'a2a.log'
        for args, venv in [([], True), (['--install'], True), (['--help'], False)]:
            a2a_log.write_text('')
            shutil.rmtree(adapter / '.venv', ignore_errors=True)
            result = subprocess.run(['bash', str(adapter / 'setup.sh'), *args], capture_output=True, text=True, timeout=30,
                                    env={**environment, 'PATH': str(stub) + os.pathsep + environment['PATH'], 'AUDIT_A2A_LOG': str(a2a_log)})
            assert result.returncode == 0, (args, result.stdout, result.stderr)
            assert (adapter / '.venv/bin/activate').exists() == venv, args
            if venv: assert f'python3 -m venv {adapter}/.venv' in a2a_log.read_text() and 'httpx' in a2a_log.read_text(), a2a_log.read_text()
            passed += 1; print('PASS a2a adapter setup.sh', args or '(no arguments)', 'venv' if venv else 'help only', flush=True)
        for script in [builder,'scripts/setup.sh','scripts/mirror-images.sh','scripts/prepare-images.sh',
                       'scripts/start-local-services.sh','scripts/apply_cluster_prereqs.sh',
                       'scripts/azure_build/run.sh','scripts/azure_build/start-agentcert-v2.sh',
                       'app-charts/install-app/build-and-deploy-app-chart.sh',
                       'scripts/azure_build/build-and-deploy-app-chart.sh',
                       'agentcert-stack/litellm-setup/build-litellm.sh']:
            run(script+' help', ['bash',str(ROOT/script),'--help'],builds=0,pushes=0)
        private_env = work / 'private.env'
        private_env.write_text(config.replace('IMAGE_REGISTRY=\n','IMAGE_REGISTRY=registry.example/docker-local\n'))
        for directory in ['agents/flash-agent','agent-sidecar','certifier','app-charts/install-app','agent-charts/install-agent']:
            # ACE_ENV_FILE keeps make off the developer's real .env (its
            # ACE_BUILD_NETWORK, registry and credentials).
            makefile = str(ROOT/directory/'Makefile'); env_arg = 'ACE_ENV_FILE='+str(env_file)
            calls=run(directory+' make build', ['make','-C',str(ROOT/directory),'build',env_arg],builds=1,pushes=0)
            if directory=='agents/flash-agent':assert 'agentcert/agentcert-flash-agent:latest' in next(c for c in calls if c[:2]==['docker','build'])
            calls=run(directory+' parallel build-push', ['make','-C',str(ROOT/directory),'-j8','build-push',env_arg],builds=1,pushes=1)
            assert next(i for i,c in enumerate(calls) if c[:2]==['docker','build']) < next(i for i,c in enumerate(calls) if c[:2]==['docker','push'])
            run(directory+' build failure blocks make push', ['make','-C',str(ROOT/directory),'-j8','build-push',env_arg],expected=1,builds=1,pushes=0,extra={'AUDIT_FAIL_BUILD':'1'})
            # Same commands when the Makefile is named from elsewhere (repo root).
            calls_f=run(directory+' make -f from the repo root', ['make','-f',makefile,'-j8','build-push',env_arg],builds=1,pushes=1)
            built=next(c for c in calls_f if c[:2]==['docker','build'])
            ctx=Path(built[-1]); assert ctx in (ROOT/directory, (ROOT/directory).parent), built
            assert Path(built[built.index('-f')+1]) == ROOT/directory/'Dockerfile', built
            run(directory+' private registry build logs in', ['make','-C',str(ROOT/directory),'build','ACE_ENV_FILE='+str(private_env)],builds=1,pushes=0,logins=1)
            # `make push` publishes IMAGE_TAG; ACE_IMAGE_TAG (a release tag) never leaks in.
            calls=run(directory+' make push publishes IMAGE_TAG, not ACE_IMAGE_TAG', ['make','-C',str(ROOT/directory),'push',env_arg],builds=0,pushes=1,extra={'ACE_IMAGE_TAG':'fixture-release'})
            pushed=next(c for c in calls if c[:2]==['docker','push'])[-1]
            assert pushed.endswith(':latest') and 'fixture-release' not in pushed, pushed
        for directory in ['app-charts/install-app','agent-charts/install-agent']:
            kube=work/'kube config';kube.write_text('fixture')
            values=work/'chart values.yaml';values.write_text('replicas: 1\n')
            calls=run(directory+' install mounts and context', ['make','-C',str(ROOT/directory),'install','FOLDER=fixture','KUBECONFIG='+str(kube),'VALUES='+str(values),'KUBE_CONTEXT=test-context','DRY_RUN=false'],builds=0,pushes=0,deploy=True)
            assert any('/values.yaml:ro' in arg for arg in calls[0]) and '-context' in calls[0] and '-dry-run' not in calls[0]
        web=ROOT/'AgentCert/chaoscenter/web'
        run('eslint preserves spaced filenames', ['bash',str(web/'scripts/eslint/eslint-staged.sh'),'src/a b.ts','src/quoted".tsx'],builds=0,pushes=0,cwd=web)
        calls=[json.loads(line) for line in log.read_text().splitlines()]
        assert calls[0][-2:]==['src/a b.ts','src/quoted".tsx']
        run('typecheck failure and cleanup', ['bash',str(web/'scripts/typecheck/typecheck-staged.sh'),'src/a b.ts','src/quoted".tsx'],expected=1,builds=0,pushes=0,cwd=web,extra={'AUDIT_TSC_EXIT':'5'})
        assert json.loads((work/'tsconfig.json').read_text())['include'][-2:]==['src/a b.ts','src/quoted".tsx']
        assert not list(web.glob('tsconfig.??????.json'))
    print(f'\nResult: {passed} script-mode checks passed')

if __name__ == '__main__':
    main()
