#!/usr/bin/env python3
"""Run and collect the isolated probe, then stop it to restore normal idle behavior."""
import argparse,json,pathlib,re,signal,subprocess,time
p=argparse.ArgumentParser()
p.add_argument('device');p.add_argument('bundle');p.add_argument('output',type=pathlib.Path)
p.add_argument('--backend',default='coreMLCPU')
p.add_argument('--unlock-timeout',type=float,default=60)
p.add_argument('--phases',default='parity,benchmark,passages')
a=p.parse_args()
a.output.mkdir(parents=True,exist_ok=False)
def device(*args,**kwargs):
 return subprocess.run(['xcrun','devicectl','device',*args,'--device',a.device],check=True,**kwargs)
deadline=time.monotonic()+a.unlock_timeout
print('Waiting for an unlocked device.',flush=True)
while True:
 status=device('info','lockState','--json-output','-',capture_output=True,text=True)
 state=json.loads(status.stdout)['result']
 if not state['passcodeRequired']:break
 if time.monotonic()>=deadline:raise RuntimeError('Device remained locked; no app was launched.')
 time.sleep(2)
(a.output/'initial-lock-state.json').write_text(json.dumps(state,indent=2)+'\n')
for phase,argument,marker in [('parity','--run-fixtures','CT_VALIDATION_COMPLETE'),('benchmark','--run-benchmark','CT_BENCHMARK_COMPLETE'),('passages','--run-passages','CT_PASSAGES_COMPLETE')]:
 if phase not in a.phases.split(','):continue
 log=a.output/(phase+'-console.log')
 with log.open('w') as stream:
  process=subprocess.Popen(['xcrun','devicectl','device','process','launch','--device',a.device,'--terminate-existing','--console','--environment-variables',json.dumps({'CT_BACKEND':a.backend}),a.bundle,argument],stdout=stream,stderr=subprocess.STDOUT)
  try:
   deadline=time.monotonic()+180
   while True:
    text=log.read_text()
    found=re.search(marker+r' ((?:parity|benchmark|passages)-[A-F0-9-]+)',text)
    if found:break
    if process.poll() is not None or 'CT_VALIDATION_FAILED' in text or 'ERROR:' in text:
     raise RuntimeError(phase+' failed: '+text[-3000:])
    if time.monotonic()>=deadline:raise RuntimeError(phase+' completion timed out')
    time.sleep(0.5)
   device('copy','from','--domain-type','appDataContainer','--domain-identifier',a.bundle,'--source','Documents/'+found.group(1),'--destination',str(a.output/phase),'--timeout','60',capture_output=True,text=True)
   print(phase+' collected: '+str(a.output/phase),flush=True)
  finally:
   # devicectl forwards catchable signals to this test app only.
   if process.poll() is None:process.send_signal(signal.SIGTERM)
   try:process.wait(timeout=10)
   except subprocess.TimeoutExpired:
    process.kill();process.wait(timeout=5)
print('Probe stopped after collection.',flush=True)
