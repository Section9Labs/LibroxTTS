#!/usr/bin/env python3
"""Create two isolated qualification apps; never overwrite the host app."""
import argparse,json,os,subprocess
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('revision',choices=['baseline','candidate']);p.add_argument('--package',type=Path,required=True);p.add_argument('--assets',type=Path,required=True);p.add_argument('--work',type=Path,required=True);a=p.parse_args()
root=Path(__file__).resolve().parents[2];out=a.work.resolve()/a.revision;out.mkdir(parents=True,exist_ok=True)
files=[]
for name in ['en','coreml-en','delivery-en']:
 selected=json.loads((root/f'Sources/KokoroCatalog/PocketTTS/{name}.json').read_text())['installedFiles']
 files += [f for f in selected if name != 'delivery-en' or (a.assets/f['path']).exists()]
assert (a.assets/'en/embeddings/caro_davy__calm.safetensors').exists()
for entry in files:
 if entry['path'].endswith('/model.safetensors'):continue
 target=out/'Assets'/entry['path'];target.parent.mkdir(parents=True,exist_ok=True)
 if not target.exists():os.link((a.assets/entry['path']).resolve(),target)
(out/'DeviceProbe.swift').write_text((root/'Scripts/Qualification10/DeviceProbe.swift').read_text())
(out/'project.yml').write_text(f'''name: LibroxQualification
packages:
  LibroxTTS:
    path: {a.package.resolve()}
targets:
  LibroxQualification:
    type: application
    platform: iOS
    deploymentTarget: '18.0'
    sources:
      - path: DeviceProbe.swift
      - path: Assets
        type: folder
        buildPhase: resources
    dependencies:
      - package: LibroxTTS
        product: PocketTTSCoreML
    info:
      path: Info.plist
      properties:
        CFBundleDisplayName: TTS {a.revision}
        UILaunchScreen: {{}}
        UIFileSharingEnabled: true
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.section9labs.libroxttsqualification10.{a.revision}
        DEVELOPMENT_TEAM: 995PCLM9KH
        CODE_SIGN_STYLE: Automatic
        SWIFT_VERSION: '6.0'
        TARGETED_DEVICE_FAMILY: '1,2'
        CURRENT_PROJECT_VERSION: 1
        MARKETING_VERSION: '1.0'
schemes:
  LibroxQualification:
    build:
      targets:
        LibroxQualification: all
    run:
      config: Release
''')
subprocess.run(['xcodegen','generate'],cwd=out,check=True)
