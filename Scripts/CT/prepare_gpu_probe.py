#!/usr/bin/env python3
"""Prepare a separate two-fixture GPU diagnostic. Never replaces a shipping asset bundle."""
import argparse,hashlib,json,pathlib,re,shutil
p=argparse.ArgumentParser();p.add_argument('sdk',type=pathlib.Path);p.add_argument('artifacts',type=pathlib.Path);p.add_argument('output',type=pathlib.Path);p.add_argument('--build-number',type=int,default=1);a=p.parse_args()
assert not a.output.exists()
assert not (a.sdk/'Integrations/CTNative/Sources/LibroxCTNative/CTGenerator.swift').exists(), 'Legacy two-fixture tool: use its frozen SDK snapshot, or build the general GPU v2 Example directly.'
reports=json.loads((a.artifacts/'enumerated-gpu-full-pipeline/parity.json').read_text())
assert len({r['id'] for r in reports})==2
for r in reports:
 w=r['tensors']['waveform'];assert w['snrDB']>60 and w['maxAbsoluteError']<0.01
a.output.mkdir()
assets=a.output/'CTGPUFixtureAssets'
shutil.copytree(a.artifacts/'CTCoreMLV2Assets',assets)
generator=assets/'coreml/vector_estimator.mlpackage'
shutil.rmtree(generator)
shutil.copytree(a.artifacts/'coreml-enumerated-fp32/vector_estimator.mlpackage',generator)
package=a.output/'Integrations/CTNative';package.mkdir(parents=True)
shutil.copy2(a.sdk/'Integrations/CTNative/Package.swift',package/'Package.swift')
for name in ['Sources','Tests']:shutil.copytree(a.sdk/'Integrations/CTNative'/name,package/name)
manifestPath=package/'Sources/LibroxCTNative/Resources/CTCoreMLManifest.json'
manifest=json.loads(manifestPath.read_text());manifest['identity']='librox-plus-ct-f1-gpu-fixtures-v2'
manifest['files']=[f for f in manifest['files'] if not f['path'].startswith('coreml/vector_estimator.mlpackage/')]
for path in sorted(generator.rglob('*')):
 if path.is_file():manifest['files'].append({'path':str(path.relative_to(assets)),'bytes':path.stat().st_size,'sha256':hashlib.sha256(path.read_bytes()).hexdigest()})
manifestPath.write_text(json.dumps(manifest,indent=2)+'\n')
(assets/'fixture-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
code=package/'Sources/LibroxCTNative/CTAssets.swift';code.write_text(code.read_text().replace('librox-plus-ct-f1-coremlfp32-v2',manifest['identity']))
code=package/'Sources/LibroxCTNative/CTEngine.swift';code.write_text(code.read_text().replace('ct-fp32-full-','ct-fp32-gpu-fixtures-'))
example=a.output/'Examples/CTDeviceProbe';example.mkdir(parents=True)
shutil.copytree(a.sdk/'Examples/CTDeviceProbe/Sources',example/'Sources')
code=example/'Sources/App.swift'
code.write_text(code.read_text().replace('CTCoreMLV2Assets','CTGPUFixtureAssets').replace('CT Core ML 2','CT GPU Fixtures').replace('?? "coreMLCPU"','?? "coreMLGPUHeavy"').replace('?? .coreMLCPU','?? .coreMLGPUHeavy'))
project=(a.sdk/'Examples/CTDeviceProbe/project.yml').read_text().replace(str(a.artifacts/'CTCoreMLV2Assets'),str(assets)).replace('com.section9labs.LibroxCTCoreMLV2Test','com.section9labs.LibroxCTGPUFixtureTest').replace('CT Core ML 2','CT GPU Test')
project=re.sub(r'CURRENT_PROJECT_VERSION: \d+',f'CURRENT_PROJECT_VERSION: {a.build_number}',project)
(example/'project.yml').write_text(project)
receipt={'scope':'Two fixed English/Spanish fixtures only, not arbitrary passages or a shipping bundle. One generator weight copy in this selected bundle.','sourceSDK':str(a.sdk),'sourceReports':str(a.artifacts/'enumerated-gpu-full-pipeline/parity.json'),'files':[]}
for root in [package,example]:
 for path in sorted(root.rglob('*')):
  if path.is_file():receipt['files'].append({'path':str(path.relative_to(a.output)),'sha256':hashlib.sha256(path.read_bytes()).hexdigest()})
(a.output/'snapshot.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(a.output)
