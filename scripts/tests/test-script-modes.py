#!/usr/bin/env python3
"""Exercise build/publish/install modes with fake external commands; no Docker or cluster needed."""
import json
import os
from pathlib import Path
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
  if os.getenv('AUDIT_EXISTING_RELEASE'):print('sha256:local')
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

        def run(name, args, expected=0, builds=None, pushes=None, deploy=False, extra=None, cwd=ROOT):
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
            assert not any(c[:2] in [['docker', 'rmi'], ['docker', 'prune']] or c[:3] == ['docker', 'image', 'prune'] for c in commands), (name, commands)
            if not deploy:
                assert not any(c[0] in ['kubectl', 'kind', 'minikube', 'helm'] for c in commands), (name, commands)
            if pushes == 0:
                assert not any(c[:2] == ['docker', 'login'] for c in commands), (name, commands)
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
        flash_revision = source_revision('agents/flash-agent')
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
        calls=run('committed-only uses the exported Dockerfile',shell(builder,'--committed-only',*flash),builds=1,pushes=0)
        built=next(c for c in calls if c[:2]==['docker','build'])
        assert '/.tmp/build-src/' in built[built.index('-f')+1]
        calls = run('local tag', shell(builder, '--tag','local-test', *flash), builds=1, pushes=0)
        assert any(c[:2] == ['docker','tag'] and c[-1].endswith(':local-test') for c in calls)
        run('explicit push', shell(builder, '--push', *flash), builds=1, pushes=2)
        run('different content cannot replace a release tag', shell(builder, '--push', *flash), expected=1, builds=1, extra={'ACE_IMAGE_TAG':'fixture-release','AUDIT_EXISTING_RELEASE':'different'})
        run('identical release can be republished', shell(builder, '--push', *flash), builds=1, pushes=2, extra={'ACE_IMAGE_TAG':'fixture-release','AUDIT_EXISTING_RELEASE':'same','AUDIT_REMOTE_REVISION':flash_revision})
        run('unlabelled release cannot be replaced', shell(builder, '--push', *flash), expected=1, builds=1, extra={'ACE_IMAGE_TAG':'fixture-release','AUDIT_EXISTING_RELEASE':'same','AUDIT_REMOTE_REVISION':''})
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
        inventory=work/'images.txt';inventory.write_text('mirror|infra|mongo:5\n')
        run('mirror default caches without publication',shell('scripts/mirror-images.sh','--images',str(inventory)),builds=0,pushes=0)
        run('mirror explicit push',shell('scripts/mirror-images.sh','--push','--images',str(inventory)),builds=0,pushes=1)
        run('mirror dry run',shell('scripts/mirror-images.sh','--dry-run','--images',str(inventory)),builds=0,pushes=0)
        run('LiteLLM default only caches image',shell('agentcert-stack/litellm-setup/build-litellm.sh'),builds=0,pushes=0)
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
        setup_source=(ROOT/'scripts/setup.sh').read_text()
        start=setup_source.index('declare -a ALL_BUILD_IMAGES=()')
        end=setup_source.index('if [[ "$SETUP_MODE" == "restart" ]]',start)
        inventory_setup=setup_source[start:end]
        result=subprocess.run(['bash','-c','source "$1/scripts/lib/registry.sh"; REPO_ROOT="$1"; _SUBSCRIBER_IMAGE_TAG=agentcert/litmusportal-subscriber:3.0.0; '+inventory_setup+'\nprintf "%s\\n" "${ALL_BUILD_IMAGES[@]}"','_',str(ROOT)],capture_output=True,text=True,check=True)
        entries=result.stdout.splitlines()
        assert len(entries)==14 and any('ace-hub-bundle' in entry for entry in entries) and any('itbench-experiment' in entry for entry in entries)
        passed+=1; print('PASS deployment build inventory contains all 14 images',flush=True)
        for agent in ['flash-agent','ciso-agent','sre-agent','sre-agent-crewai','sre-agent-comprehensive']:
            run(agent+' harness default is Docker only', ['bash',str(ROOT/'agents/harness'/agent/'setup.sh')], builds=1,pushes=0)
            run(agent+' harness help', ['bash',str(ROOT/'agents/harness'/agent/'setup.sh'),'--help'], builds=0,pushes=0)
        run('adapter requires explicit installation', ['bash',str(ROOT/'agents/harness/a2a-mcp-agent/setup.sh')], builds=0,pushes=0)
        for script in [builder,'scripts/setup.sh','scripts/mirror-images.sh','scripts/prepare-images.sh',
                       'scripts/start-local-services.sh','scripts/apply_cluster_prereqs.sh',
                       'scripts/azure_build/run.sh','scripts/azure_build/start-agentcert-v2.sh',
                       'app-charts/install-app/build-and-deploy-app-chart.sh',
                       'scripts/azure_build/build-and-deploy-app-chart.sh',
                       'agentcert-stack/litellm-setup/build-litellm.sh']:
            run(script+' help', ['bash',str(ROOT/script),'--help'],builds=0,pushes=0)
        for directory in ['agents/flash-agent','agent-sidecar','certifier','app-charts/install-app','agent-charts/install-agent']:
            calls=run(directory+' make build', ['make','-C',str(ROOT/directory),'build'],builds=1,pushes=0)
            if directory=='agents/flash-agent':assert 'agentcert/agentcert-flash-agent:latest' in calls[0]
            calls=run(directory+' parallel build-push', ['make','-C',str(ROOT/directory),'-j8','build-push'],builds=1,pushes=1)
            assert next(i for i,c in enumerate(calls) if c[:2]==['docker','build']) < next(i for i,c in enumerate(calls) if c[:2]==['docker','push'])
            run(directory+' build failure blocks make push', ['make','-C',str(ROOT/directory),'-j8','build-push'],expected=1,builds=1,pushes=0,extra={'AUDIT_FAIL_BUILD':'1'})
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
